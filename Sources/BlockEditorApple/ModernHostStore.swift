import BlockEditorCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A native draft remains bound to its captured atoms, even if its field is
/// deleted before reopen. Retrying it is an explicit checked author command.
public struct ModernPendingInput: Codable, Equatable, Sendable {
    public let target: ModernTextRange
    public let text: String
    public let selection: Range<Int>
    public let reason: String
    public init(target: ModernTextRange, text: String, selection: Range<Int>, reason: String) {
        self.target = target; self.text = text; self.selection = selection; self.reason = reason
    }
}

public enum ModernHostStoreError: Error, Equatable {
    case invalidCheckpoint, differentOwner, revisionConflict, capacityExceeded
    /// The new revision is visible after rename. Do not report the old revision
    /// as active or retry blindly if synchronizing the directory fails.
    case durabilityUnconfirmed(revision: UUID)
}

/// One immutable pairing of accepted history and all local sidecars. Cut
/// preparations and live provider tasks are deliberately not resumable state.
public struct ModernHostCheckpoint: Codable, Sendable {
    public let version: Int
    public let revision: UUID
    public let documentID: String
    public let actorID: String
    public let epoch: String
    public let accepted: Data
    public let historySelection: Data
    public let providers: Data
    public let recovery: Data?
    public let deferred: Data
    public let pendingInputs: [ModernPendingInput]

    @MainActor public init(session: ModernSession, pendingInputs: [ModernPendingInput] = []) throws {
        guard !session.isComposing || !pendingInputs.isEmpty else { throw ModernSessionError.compositionActive }
        version = 1; revision = UUID(); documentID = session.documentID; actorID = session.actorID; epoch = session.epoch
        accepted = try session.save(); historySelection = try session.exportHistorySelection()
        providers = try session.exportAsyncRequests(); recovery = try session.exportRecovery()
        deferred = try session.exportDeferredChanges(); self.pendingInputs = pendingInputs
        try validate()
    }

    fileprivate func validate() throws {
        guard version == 1 else { throw ModernHostStoreError.invalidCheckpoint }
        guard accepted.count <= 64_000_000, historySelection.count <= 16_000_000,
              providers.count <= 16_000_000, (recovery?.count ?? 0) <= 64_000_000,
              deferred.count <= 64_000_000, pendingInputs.count <= 64,
              try checkpointEncoder().encode(pendingInputs).count <= 16_000_000 else {
            throw ModernHostStoreError.capacityExceeded
        }
        for draft in pendingInputs {
            guard draft.target.start.documentID == documentID, draft.target.end.documentID == documentID,
                  draft.target.start.epoch == epoch, draft.target.end.epoch == epoch,
                  draft.target.start.field == draft.target.end.field,
                  draft.selection.lowerBound >= 0, draft.selection.upperBound <= draft.text.utf16.count,
                  draft.reason.utf16.count <= 1000 else { throw ModernHostStoreError.invalidCheckpoint }
        }
    }

    /// Build a detached candidate before the host replaces its active model.
    /// Deferred packets stay held; provider records stay inert. No draft is
    /// authored and no current native focus is inferred during restoration.
    @MainActor public func restore() throws -> ModernRestoredHost {
        try validate()
        let session = try ModernSession.restore(accepted, actorID: actorID)
        guard session.documentID == documentID, session.epoch == epoch else { throw ModernHostStoreError.invalidCheckpoint }
        try session.restoreHistorySelection(historySelection)
        try session.restoreAsyncRequests(providers)
        if let recovery {
            do { try session.restoreRecovery(recovery) }
            catch ModernSessionError.recoveryRequired(_) { }
            guard try session.exportRecovery() == recovery else { throw ModernHostStoreError.invalidCheckpoint }
        }
        let release = try session.holdRemoteChanges()
        try session.restoreDeferredChanges(deferred)
        guard try session.save() == accepted, try session.exportDeferredChanges() == deferred else {
            throw ModernHostStoreError.invalidCheckpoint
        }
        return ModernRestoredHost(checkpoint: self, session: session, release: release)
    }
}

@MainActor public final class ModernRestoredHost {
    public let checkpoint: ModernHostCheckpoint
    public let session: ModernSession
    public var pendingInputs: [ModernPendingInput] { checkpoint.pendingInputs }
    private let release: () throws -> Void
    fileprivate init(checkpoint: ModernHostCheckpoint, session: ModernSession, release: @escaping () throws -> Void) {
        self.checkpoint = checkpoint; self.session = session; self.release = release
    }
    /// Call after the host has resolved/restored its drafts and attached inputs.
    /// A retry also drains packets left after a recoverable prior failure.
    public func resumeDeferredChanges() throws {
        try release()
        try session.retryDeferredChanges()
    }
}

private func checkpointEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
}

/// App-owned local storage. Save accepted history, selection/history, provider
/// results, held packets, recovery and native drafts in one synchronized rename.
/// The host supplies an existing directory and the revision it actually loaded.
/// Capture on the session's main actor, then await storage on this separate
/// actor. Reopening returns an immutable pair for explicit main-actor restore.
public actor ModernHostStore {
    public let url: URL
    public let documentID: String
    public let actorID: String
    private static let byteLimit = 384_000_000
    public init(url: URL, documentID: String, actorID: String) {
        self.url = url; self.documentID = documentID; self.actorID = actorID
    }
    public func load() throws -> ModernHostCheckpoint? {
        try locked { try read() }
    }
    @discardableResult public func save(_ checkpoint: ModernHostCheckpoint, replacing revision: UUID?) throws -> ModernHostCheckpoint {
        try checkpoint.validate()
        try checkOwner(checkpoint)
        let bytes = try checkpointEncoder().encode(checkpoint)
        guard bytes.count <= Self.byteLimit else { throw ModernHostStoreError.capacityExceeded }
        return try locked {
            guard try read()?.revision == revision else { throw ModernHostStoreError.revisionConflict }
            try publish(bytes, revision: checkpoint.revision)
            return checkpoint
        }
    }
    private func checkOwner(_ checkpoint: ModernHostCheckpoint) throws {
        guard checkpoint.documentID == documentID, checkpoint.actorID == actorID else { throw ModernHostStoreError.differentOwner }
    }
    private func read() throws -> ModernHostCheckpoint? {
        guard url.isFileURL else { throw ModernHostStoreError.invalidCheckpoint }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw ModernHostStoreError.capacityExceeded }
        let checkpoint = try JSONDecoder().decode(ModernHostCheckpoint.self, from: data)
        // This private format admits only its canonical encoding, rejecting
        // duplicate/ignored outer keys rather than silently dropping sidecars.
        guard try checkpointEncoder().encode(checkpoint) == data else { throw ModernHostStoreError.invalidCheckpoint }
        try checkOwner(checkpoint); try checkpoint.validate()
        return checkpoint
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        #if canImport(Darwin) || canImport(Glibc)
        guard url.isFileURL else { throw ModernHostStoreError.invalidCheckpoint }
        let lock = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        defer { _ = close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw posixError() } }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
        #else
        throw ModernHostStoreError.invalidCheckpoint
        #endif
    }
    private func publish(_ data: Data, revision: UUID) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(revision.uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw ModernHostStoreError.durabilityUnconfirmed(revision: revision) }
        defer { _ = close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ModernHostStoreError.durabilityUnconfirmed(revision: revision) }
        // Check actual storage bytes before reporting persistence success.
        guard let readback = try? Data(contentsOf: url), readback == data else { throw ModernHostStoreError.durabilityUnconfirmed(revision: revision) }
        #else
        throw ModernHostStoreError.invalidCheckpoint
        #endif
    }
    #if canImport(Darwin) || canImport(Glibc)
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    #endif
}
