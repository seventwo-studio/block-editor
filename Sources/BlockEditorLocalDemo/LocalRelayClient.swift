import BlockEditorCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional local-demo HTTP adapter. The document engine itself has no transport dependency.
@MainActor public final class LocalRelayClient {
    public let session: EditorSession
    public private(set) var connected = true
    public private(set) var exchanging = false
    public private(set) var peers: [Presence] = []
    public private(set) var lastError: String?
    public private(set) var transportCapacityBytes: Int?
    public var onStatus: (() -> Void)?
    private let endpoint: URL
    private var token: String
    private let transport: URLSession
    private var receipt = SyncState()
    private var generation = 0
    private var revision: UInt64 = 0
    public var pendingChanges: Int { session.changes(since: receipt).changes.count }

    public init(session: EditorSession, endpoint: URL, token: String, transport: URLSession = .shared) {
        self.session = session; self.endpoint = endpoint; self.token = token; self.transport = transport
    }
    public static func open(endpoint: URL, token: String, actorID: String = UUID().uuidString) async throws -> LocalRelayClient {
        var request = URLRequest(url: endpoint)
        request.setValue(token, forHTTPHeaderField: "X-Local-Token")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try LocalRelayClient(session: EditorSession.restore(data, actorID: actorID), endpoint: endpoint, token: token)
    }
    public func setConnected(_ connected: Bool) {
        self.connected = connected; generation += 1
        if !connected { for peer in peers { session.removePresence(actor: peer.actor) }; peers = [] }
        onStatus?()
    }
    public func setToken(_ token: String) { self.token = token }
    public func exchange() async throws {
        guard connected, !exchanging else { return }
        exchanging = true; onStatus?()
        defer { exchanging = false; onStatus?() }
        let started = generation
        revision += 1
        struct Request: Encodable {
            let actorID: String; let batch: ChangeBatch; let state: SyncState; let presence: Presence
        }
        struct Reply: Decodable { let batch: ChangeBatch; let state: SyncState; let presence: [Presence] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue(token, forHTTPHeaderField: "X-Local-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(actorID: session.actorID, batch: session.changes(since: receipt), state: session.syncState, presence: Presence(actor: session.actorID, revision: revision)))
        do {
            let (data, response) = try await transport.data(for: request)
            guard connected, generation == started else { return }
            if let http = response as? HTTPURLResponse, http.statusCode == 413 {
                struct CapacityFailure: Decodable { let error: String; let maxBytes: Int }
                let failure = try JSONDecoder().decode(CapacityFailure.self, from: data)
                guard failure.error == "transportCapacityExceeded", failure.maxBytes > 0 else {
                    throw RelayError.rejected("Invalid relay capacity response")
                }
                transportCapacityBytes = failure.maxBytes
                throw RelayError.transportCapacityExceeded(maxBytes: failure.maxBytes)
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 409 {
                struct RejectedMerge: Decodable { let error: String; let recovery: MergeRecovery }
                let rejected = try JSONDecoder().decode(RejectedMerge.self, from: data)
                guard rejected.error == "mergeRecoveryRequired" else { throw RelayError.rejected(rejected.error) }
                // Import the union without acknowledging it. The engine either retains
                // recovery or recognizes a repair authored while the request was in flight.
                try session.receive(rejected.recovery.batch)
                throw RelayError.rejected("The server has not accepted these edits; retry synchronization.")
            }
            try Self.check(response, data)
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            try session.receive(reply.batch); receipt = reply.state
            transportCapacityBytes = nil
            let nextPeers = reply.presence.filter { $0.actor != session.actorID }
            for peer in peers where !nextPeers.contains(where: { $0.actor == peer.actor }) { session.removePresence(actor: peer.actor) }
            peers = nextPeers
            for peer in peers { session.receivePresence(peer) }
            lastError = nil
        } catch {
            guard connected, generation == started else { return }
            if case EditorError.mergeRecoveryRequired = error {
                lastError = "Some edits conflict. Review the recovery actions."
            } else if case RelayError.transportCapacityExceeded(let limit) = error {
                lastError = "The relay limit is \(limit) bytes. Export the complete local history before changing transport or arranging a cutover."
            } else { lastError = String(describing: error) }
            throw error
        }
    }
    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw RelayError.rejected(String(decoding: data.prefix(2048), as: UTF8.self))
        }
    }
}

public enum RelayError: Error, Equatable {
    case rejected(String)
    case transportCapacityExceeded(maxBytes: Int)
}
