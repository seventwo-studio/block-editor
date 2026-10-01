import BlockEditorCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host-owned local storage. Retain the lease for the entire editing session.
public final class LocalDraft {
    private enum Purpose: String, Codable { case draft, recoveryArchive }
    private struct Record: Codable {
        let version: Int
        let endpoint: String
        let actorID: String
        let snapshot: Data
        let recovery: MergeRecovery?
        let purpose: Purpose?
    }
    private let file: URL
    private var descriptor: Int32
    public init(file: URL) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw DraftError.storageUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw DraftError.alreadyOpen
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
    /// A standalone document has no relay endpoint or transport configuration.
    private static let localIdentity = URL(string: "block-editor-local://document")!
    public func openLocalDocument() throws -> EditorSession {
        if let restored = try restore(endpoint: Self.localIdentity) { return restored }
        let session = try EditorSession(documentID: UUID().uuidString, actorID: UUID().uuidString,
                                        document: Document(blocks: [.paragraph(id: "p", text: "")]))
        try saveLocalDocument(session)
        return session
    }
    public func saveLocalDocument(_ session: EditorSession) throws {
        try save(session, endpoint: Self.localIdentity)
    }
    public func restore(endpoint: URL) throws -> EditorSession? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard [1, 2].contains(record.version), record.version != 1 || (record.recovery == nil && record.purpose == nil) else { throw DraftError.unsupportedVersion }
        guard record.endpoint == endpoint.absoluteString else { throw DraftError.differentEndpoint }
        // An exported archive can be opened alongside the original draft without
        // reusing its writer identity. The original history remains in the archive.
        let actor = record.purpose == .recoveryArchive ? UUID().uuidString : record.actorID
        let session = try EditorSession.restore(record.snapshot, actorID: actor)
        if let recovery = record.recovery {
            do { try session.receive(recovery.batch) }
            catch EditorError.mergeRecoveryRequired { /* Retain unapplied transport state separately. */ }
        }
        return session
    }
    public func save(_ session: EditorSession, endpoint: URL) throws {
        let record = try record(session, endpoint: endpoint)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }
    /// A recovery archive includes accepted history and the separate unacknowledged union.
    public func exportRecovery(_ session: EditorSession, endpoint: URL, to destination: URL) throws {
        guard session.mergeRecovery != nil else { throw DraftError.noRecovery }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DraftError.archiveExists }
        try JSONEncoder().encode(record(session, endpoint: endpoint, purpose: .recoveryArchive)).write(to: destination, options: .atomic)
    }
    private func record(_ session: EditorSession, endpoint: URL, purpose: Purpose = .draft) throws -> Record {
        Record(version: 2, endpoint: endpoint.absoluteString, actorID: session.actorID,
               snapshot: try session.save(), recovery: session.mergeRecovery, purpose: purpose)
    }
}

public enum DraftError: Error {
    case alreadyOpen, storageUnavailable, unsupportedVersion, differentEndpoint, noRecovery, archiveExists
}
