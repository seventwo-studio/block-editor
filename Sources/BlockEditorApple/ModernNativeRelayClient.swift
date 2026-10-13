import BlockEditorCore
import Foundation

/// Durable acknowledgment belongs to one application-supplied relay identity.
/// Tokens, endpoints and presence are deliberately absent from the checkpoint.
public struct ModernRelayReceipt: Codable, Equatable, Sendable {
    public let key: String
    public let receipt: WritingSyncState
    public init(key: String, receipt: WritingSyncState) { self.key = key; self.receipt = receipt }
    @MainActor func validate(session: ModernSession) throws {
        guard !key.isEmpty, key.utf8.count <= 1024 else { throw ModernHostStoreError.invalidCheckpoint }
        _ = try session.changes(since: receipt)
        var known = Set(session.syncState.received)
        let packets = try JSONSerialization.jsonObject(with: session.exportDeferredChanges()) as? [Any]
        guard let packets else { throw ModernHostStoreError.invalidCheckpoint }
        for packet in packets {
            let batch = try ModernBatch(json: JSONSerialization.data(withJSONObject: packet))
            known.formUnion(batch.changes.map(\.id))
        }
        guard Set(receipt.received).isSubset(of: known) else { throw ModernHostStoreError.invalidCheckpoint }
    }
}

public struct ModernRelayHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public enum ModernNativeRelayError: Error, Equatable, Sendable {
    case invalidEndpoint, differentRelay, clientAlreadyAttached, invalidReply
    case rejected(status: Int), recoveryNeedsRetry, transportCapacityExceeded(maxBytes: Int)
}
public typealias ModernNativeRelayTransport = @MainActor (URLRequest) async throws -> ModernRelayHTTPResponse

private final class NoRelayRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Opt-in native protocol-7 reference transport. Application authorization,
/// polling, storage location and rollout remain with the consumer. Read-only
/// author policy does not prohibit receiving checked peer work.
@MainActor public final class ModernNativeRelayClient {
    public let persistence: ModernPersistenceController
    public let relayKey: String
    public private(set) var connected = true
    public private(set) var exchanging = false
    public private(set) var peers: [Presence] = []
    public private(set) var lastError: String?
    public private(set) var transportCapacityBytes: Int?
    public private(set) var restoredHost: ModernRestoredHost?
    public var onStatus: (() -> Void)?
    private let endpoint: URL
    private let transport: ModernNativeRelayTransport
    private var token: String
    private var generation: UInt64 = 0
    private var presenceRevision: UInt64 = 0
    private var closed = false
    private var requestTask: Task<ModernRelayHTTPResponse, Error>?
    private var model: ModernEditorModel { persistence.model }
    public var receipt: WritingSyncState { model.relayReceipt!.receipt }
    public var pendingChanges: Int {
        let confirmed = Set(receipt.received)
        return model.session.syncState.received.filter { !confirmed.contains($0) }.count
    }

    public init(persistence: ModernPersistenceController, endpoint: URL, relayKey: String, token: String,
                transport: ModernNativeRelayTransport? = nil) throws {
        try Self.validateEndpoint(endpoint)
        let model = persistence.model
        guard model.relayClient == nil else { throw ModernNativeRelayError.clientAlreadyAttached }
        if let saved = model.relayReceipt, saved.key != relayKey { throw ModernNativeRelayError.differentRelay }
        let record = model.relayReceipt ?? ModernRelayReceipt(key: relayKey,
            receipt: WritingSyncState(documentID: model.session.documentID, epoch: model.session.epoch, version: 7))
        try record.validate(session: model.session)
        self.persistence = persistence; self.endpoint = endpoint; self.relayKey = relayKey; self.token = token
        self.transport = transport ?? Self.send
        model.relayReceipt = record; model.relayClient = self
    }
    /// A saved pair opens without credentials or network traffic. A fresh room
    /// requires an authorized GET and durable initial save before it is returned.
    public static func open(store: ModernHostStore, endpoint: URL, relayKey: String, token: String,
                            transport: ModernNativeRelayTransport? = nil) async throws -> ModernNativeRelayClient {
        try validateEndpoint(endpoint)
        if let saved = try await store.load() {
            let restored = try saved.restore()
            let model = ModernEditorModel(session: restored.session, pendingInputs: restored.pendingInputs,
                retainedClipboard: restored.retainedClipboard, relayReceipt: saved.relay)
            let result = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store, loadedRevision: saved.revision),
                endpoint: endpoint, relayKey: relayKey, token: token, transport: transport)
            result.restoredHost = restored
            if token.isEmpty { result.connected = false }
            return result
        }
        guard !token.isEmpty else { throw ModernNativeRelayError.rejected(status: 401) }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 15
        request.setValue(token, forHTTPHeaderField: "X-Local-Token")
        let reply = try await (transport ?? send)(request)
        guard reply.status == 200 else { throw ModernNativeRelayError.rejected(status: reply.status) }
        let session = try ModernSession.restore(reply.data, actorID: store.actorID)
        guard session.documentID == store.documentID else { throw ModernHostStoreError.differentOwner }
        let model = ModernEditorModel(session: session, relayReceipt: ModernRelayReceipt(key: relayKey, receipt: session.syncState))
        let result = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store),
            endpoint: endpoint, relayKey: relayKey, token: token, transport: transport)
        try await result.persistence.save()
        return result
    }
    /// Cache restoration is local and performs no network request. Keep the
    /// restored host alive to explicitly resume any actual retained packets.
    public func setConnected(_ value: Bool) {
        connected = value; generation &+= 1; requestTask?.cancel(); peers = []; onStatus?()
    }
    public func setToken(_ value: String) {
        token = value; generation &+= 1; requestTask?.cancel(); peers = []
        if value.isEmpty { connected = false }; onStatus?()
    }
    public func close() {
        guard !closed else { return }
        closed = true; connected = false; generation &+= 1; requestTask?.cancel(); peers = []
        if model.relayClient === self { model.relayClient = nil }
    }
    public func exchange() async throws {
        guard !closed, connected, !exchanging, model.isActive else { return }
        exchanging = true; lastError = nil; onStatus?()
        let connection = generation, activation = model.invocationGeneration
        func current() -> Bool { !closed && connected && generation == connection && model.isActive && model.invocationGeneration == activation }
        defer { exchanging = false; requestTask = nil; if !closed { onStatus?() } }
        do {
            guard !token.isEmpty else { throw ModernNativeRelayError.rejected(status: 401) }
            // Send only the immutable accepted history actually saved. Edits
            // authored while disk I/O waits remain pending for the next exchange.
            let saved = try await persistence.save()
            guard current() else { return }
            let captured = try ModernSession.restore(saved.accepted, actorID: model.session.actorID)
            presenceRevision &+= 1
            struct Request: Encodable { let actorID: String; let batch: ModernBatch; let state: WritingSyncState; let presence: Presence }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue(token, forHTTPHeaderField: "X-Local-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Request(actorID: model.session.actorID,
                batch: captured.changes(since: receipt), state: captured.syncState,
                presence: Presence(actor: model.session.actorID, revision: presenceRevision)))
            let task = Task { @MainActor in try await transport(request) }; requestTask = task
            let response = try await task.value
            guard current() else { return }
            guard response.data.count <= 128_000_000,
                  let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ModernNativeRelayError.invalidReply }
            if response.status == 413 {
                struct Capacity: Decodable { let error: String; let maxBytes: Int }
                let capacity = try JSONDecoder().decode(Capacity.self, from: response.data)
                guard capacity.error == "transportCapacityExceeded", capacity.maxBytes > 0 else { throw ModernNativeRelayError.invalidReply }
                transportCapacityBytes = capacity.maxBytes
                throw ModernNativeRelayError.transportCapacityExceeded(maxBytes: capacity.maxBytes)
            }
            if response.status == 409 {
                guard json["error"] as? String == "modernRecoveryRequired" else { throw ModernNativeRelayError.invalidReply }
                do { try model.receive(ModernBatch(json: response.data, atKeyPath: ["recovery", "batch"])) }
                catch ModernSessionError.recoveryRequired(_) { }
                try await persistence.save()
                guard current() else { return }
                throw ModernNativeRelayError.recoveryNeedsRetry
            }
            guard response.status == 200 else { throw ModernNativeRelayError.rejected(status: response.status) }
            guard let stateJSON = json["state"], let presenceJSON = json["presence"] else { throw ModernNativeRelayError.invalidReply }
            let batch = try ModernBatch(json: response.data, atKeyPath: ["batch"])
            let state = try JSONDecoder().decode(WritingSyncState.self, from: JSONSerialization.data(withJSONObject: stateJSON))
            let presence = try JSONDecoder().decode([Presence].self, from: JSONSerialization.data(withJSONObject: presenceJSON))
            _ = try model.session.changes(since: state)
            var known = Set(model.session.syncState.received); known.formUnion(batch.changes.map(\.id))
            let held = try JSONSerialization.jsonObject(with: model.session.exportDeferredChanges()) as? [Any] ?? []
            for packet in held { known.formUnion(try ModernBatch(json: JSONSerialization.data(withJSONObject: packet)).changes.map(\.id)) }
            guard Set(state.received).isSubset(of: known) else { throw ModernNativeRelayError.invalidReply }
            do { try model.receive(batch) }
            catch {
                if case ModernSessionError.recoveryRequired(_) = error { try await persistence.save() }
                throw error
            }
            try await persistence.save(confirmingRelay: ModernRelayReceipt(key: relayKey, receipt: state))
            guard current() else { return }
            transportCapacityBytes = nil; peers = presence.filter { $0.actor != model.session.actorID }
        } catch {
            guard current() else { return }
            lastError = String(describing: error); throw error
        }
    }
    private static func validateEndpoint(_ endpoint: URL) throws {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(components.host ?? "")),
              components.host?.isEmpty == false else { throw ModernNativeRelayError.invalidEndpoint }
    }
    private static func send(_ request: URLRequest) async throws -> ModernRelayHTTPResponse {
        let session = URLSession(configuration: .ephemeral, delegate: NoRelayRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ModernNativeRelayError.invalidReply }
        return ModernRelayHTTPResponse(status: response.statusCode, data: data)
    }
}
