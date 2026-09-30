import BlockEditorCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host-owned local storage. Retain the lease for the entire editing session.
public final class LocalDraft {
    private struct Record: Codable {
        let version: Int
        let endpoint: String
        let actorID: String
        let snapshot: Data
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
    public func restore(endpoint: URL) throws -> EditorSession? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.version == 1 else { throw DraftError.unsupportedVersion }
        guard record.endpoint == endpoint.absoluteString else { throw DraftError.differentEndpoint }
        return try EditorSession.restore(record.snapshot, actorID: record.actorID)
    }
    public func save(_ session: EditorSession, endpoint: URL) throws {
        let record = Record(version: 1, endpoint: endpoint.absoluteString, actorID: session.actorID, snapshot: try session.save())
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }
}

public enum DraftError: Error {
    case alreadyOpen, storageUnavailable, unsupportedVersion, differentEndpoint
}
