import BlockEditorCore
import Foundation
import Darwin

/// Immutable revisions keep both the fresh session and the archived originals.
/// Switching one small pointer is the only activation step. Hosts quiesce old
/// writers before calling activate and keep them stopped after success.
public struct ModernActivation: Codable, Equatable, Sendable {
    public let revision: UUID
    public let documentID: String
    public let epoch: String
    public let checkpointFile: String
    public let archiveFile: String
    public let previousRevision: UUID?
    public var liveCheckpointFile: String { "live-\(revision.uuidString).json" }
}
public actor ModernActivationStore {
    private let directory: URL
    private let documentID: String
    public init(directory: URL, documentID: String) { self.directory = directory; self.documentID = documentID }
    private var pointer: URL { directory.appendingPathComponent("active.json") }
    public func active() throws -> ModernActivation? { try locked { try readActive() } }
    public func activate(archive: ModernCutoverArchive, candidate: ModernHostCheckpoint, replacing expected: UUID?, oldWritersStopped: Bool) async throws -> ModernActivation {
        guard oldWritersStopped, candidate.documentID == documentID, archive.documentID == documentID,
              candidate.epoch == archive.epoch else { throw ModernCutoverError.acknowledgmentsRequired }
        let plan = try ProtocolMigration.prepareModernCutover(archive)
        try await MainActor.run {
            let restored = try candidate.restore()
            guard restored.session.baseline == plan.document, restored.session.syncState.received.isEmpty else { throw ModernHostStoreError.invalidCheckpoint }
        }
        let original = try archive.json(), revision = UUID()
        let activation = ModernActivation(revision: revision, documentID: documentID, epoch: candidate.epoch,
            checkpointFile: "session-\(revision.uuidString).json", archiveFile: "archive-\(revision.uuidString).json", previousRevision: expected)
        return try locked {
            let previous = try readActive()
            guard previous?.revision == expected else { throw ModernHostStoreError.revisionConflict }
            if let previous { guard previous.epoch != candidate.epoch else { throw ModernCutoverError.sameEpoch } }
            // Persist originals and read them back before writing the new pair.
            try publish(original, to: directory.appendingPathComponent(activation.archiveFile), revision: revision)
            let checkpoint = try encoder().encode(candidate)
            try publish(checkpoint, to: directory.appendingPathComponent(activation.checkpointFile), revision: revision)
            try publish(checkpoint, to: directory.appendingPathComponent(activation.liveCheckpointFile), revision: revision)
            let saved = try JSONDecoder().decode(ModernHostCheckpoint.self, from: Data(contentsOf: directory.appendingPathComponent(activation.checkpointFile)))
            guard saved.revision == candidate.revision else { throw ModernHostStoreError.invalidCheckpoint }
            if let previous { try publish(encoder().encode(previous), to: revisionURL(previous.revision), revision: previous.revision) }
            try publish(encoder().encode(activation), to: revisionURL(revision), revision: revision)
            try publish(encoder().encode(activation), to: pointer, revision: revision)
            return activation
        }
    }
    public func rollback(replacing expected: UUID, oldWritersStopped: Bool) throws -> ModernActivation {
        guard oldWritersStopped else { throw ModernCutoverError.acknowledgmentsRequired }
        return try locked {
            guard let current = try readActive(), current.revision == expected, let previous = current.previousRevision else { throw ModernHostStoreError.revisionConflict }
            let activation = try JSONDecoder().decode(ModernActivation.self, from: Data(contentsOf: revisionURL(previous)))
            try verify(activation)
            try publish(encoder().encode(activation), to: pointer, revision: activation.revision)
            return activation
        }
    }
    public func loadActive() throws -> ModernHostCheckpoint? {
        try locked {
            guard let active = try readActive() else { return nil }
            try verify(active)
            let latest = try JSONDecoder().decode(ModernHostCheckpoint.self, from: Data(contentsOf: directory.appendingPathComponent(active.liveCheckpointFile)))
            guard latest.documentID == documentID, latest.epoch == active.epoch else { throw ModernHostStoreError.invalidCheckpoint }
            return latest
        }
    }
    /// Keep autosave on the active epoch's paired live checkpoint. The immutable
    /// activation checkpoint and archived originals remain recovery evidence.
    public func activeHostStore(actorID: String) throws -> ModernHostStore? {
        try locked {
            guard let activation = try readActive() else { return nil }
            return ModernHostStore(url: directory.appendingPathComponent(activation.liveCheckpointFile), documentID: documentID, actorID: actorID)
        }
    }
    private func revisionURL(_ revision: UUID) -> URL { directory.appendingPathComponent("activation-\(revision.uuidString).json") }
    private func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder }
    private func readActive() throws -> ModernActivation? {
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let value = try JSONDecoder().decode(ModernActivation.self, from: Data(contentsOf: pointer))
        try verify(value)
        return value
    }
    private func verify(_ value: ModernActivation) throws {
        guard value.documentID == documentID, value.checkpointFile == "session-\(value.revision.uuidString).json",
              value.archiveFile == "archive-\(value.revision.uuidString).json" else { throw ModernHostStoreError.invalidCheckpoint }
        let checkpoint = try JSONDecoder().decode(ModernHostCheckpoint.self, from: Data(contentsOf: directory.appendingPathComponent(value.checkpointFile)))
        guard checkpoint.documentID == documentID, checkpoint.epoch == value.epoch else { throw ModernHostStoreError.invalidCheckpoint }
        let archive = try ModernCutoverArchive(json: Data(contentsOf: directory.appendingPathComponent(value.archiveFile)))
        guard archive.documentID == documentID, archive.epoch == value.epoch else { throw ModernHostStoreError.invalidCheckpoint }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent(".activation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure() }
        defer { _ = close(fd) }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw failure() } }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func publish(_ bytes: Data, to destination: URL, revision: UUID) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw failure() }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw ModernHostStoreError.durabilityUnconfirmed(revision: revision) }
        defer { _ = close(directoryFD) }
        guard fsync(directoryFD) == 0, try Data(contentsOf: destination) == bytes else { throw ModernHostStoreError.durabilityUnconfirmed(revision: revision) }
    }
    private func failure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
