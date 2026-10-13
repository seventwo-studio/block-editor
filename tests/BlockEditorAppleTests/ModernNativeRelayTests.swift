import BlockEditorApple
import BlockEditorCore
import Foundation
import Testing

@MainActor @Suite struct ModernNativeRelayTests {
    @MainActor private final class Control<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let endpoint = URL(string: "http://127.0.0.1:4319/rooms/native")!
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modern-native-relay-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func session(_ actor: String) throws -> ModernSession {
        let paragraph = try Block(fields: ["id": .string("p"), "type": .string("paragraph"),
            "content": .array([.object(["type": .string("text"), "text": .string("ABC😀")])]),
            "consumer": .object(["opaque": .string("keep")])])
        return try ModernSession(documentID: "native", actorID: actor, epoch: "epoch",
            document: ModernDocument(documentID: "native", title: "Title", blocks: [paragraph]))
    }
    private func store(_ directory: URL) -> ModernHostStore {
        ModernHostStore(url: directory.appendingPathComponent("pair.json"), documentID: "native", actorID: "author")
    }
    private func response(_ server: ModernSession, request: URLRequest) throws -> ModernRelayHTTPResponse {
        let batch = try ModernBatch(json: #require(request.httpBody), atKeyPath: ["batch"])
        try server.receive(batch)
        let bytes = try JSONSerialization.data(withJSONObject: [
            "batch": JSONSerialization.jsonObject(with: server.changes().json()),
            "state": JSONSerialization.jsonObject(with: JSONEncoder().encode(server.syncState)),
            "presence": [["actor": "peer", "revision": 1]],
        ])
        return ModernRelayHTTPResponse(status: 200, data: bytes)
    }
    private func field(_ session: ModernSession) throws -> WritingField { try session.field(node: session.node(at: NodeAddress("p"))) }

    @Test func failedAcknowledgmentSaveKeepsPendingAndRetryPreservesPeerUndo() async throws {
        let root = try directory(), parked = root.appendingPathExtension("parked")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: parked) }
        let a = try session("author"), peer = try session("peer"), server = try session("server")
        try a.replaceText(in: field(a), range: 0..<0, with: "Own ")
        try peer.replaceTitle(range: 0..<5, with: "Peer title"); try server.receive(peer.changes())
        let model = ModernEditorModel(session: a), persistence = ModernPersistenceController(model: model, store: store(root))
        var fail = true
        let relay = try ModernNativeRelayClient(persistence: persistence, endpoint: endpoint, relayKey: "room/native", token: "test-only") { request in
            let reply = try response(server, request: request)
            if fail { try FileManager.default.moveItem(at: root, to: parked); fail = false }
            return reply
        }
        await #expect(throws: (any Error).self) { try await relay.exchange() }
        #expect(relay.receipt.received.isEmpty && relay.pendingChanges == 2)
        #expect(model.document.title == "Peer title" && model.document.blocks[0].text == "Own ABC😀")
        try FileManager.default.moveItem(at: parked, to: root)
        try await relay.exchange()
        #expect(relay.pendingChanges == 0 && server.syncState.received.count == 2)
        let pair = try #require(try await persistence.store.load())
        #expect(pair.relay?.receipt == relay.receipt)
        #expect(!String(decoding: try JSONEncoder().encode(pair), as: UTF8.self).contains("test-only"))
        relay.close()
        var reads = 0
        let opened = try await ModernNativeRelayClient.open(store: persistence.store, endpoint: endpoint, relayKey: "room/native", token: "") { _ in
            reads += 1; throw ModernNativeRelayError.rejected(status: 401)
        }
        #expect(reads == 0 && !opened.connected && opened.pendingChanges == 0)
        try opened.persistence.model.undo()
        let expected = try ModernDocument(documentID: "native", title: "Peer title", blocks: session("baseline").document.blocks)
        #expect(opened.persistence.model.document == expected)
        try opened.persistence.model.redo()
        #expect(opened.persistence.model.document == model.document)
    }

    @Test func inputAuthoredDuringTransmissionRemainsUnacknowledged() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try session("author"), server = try session("server"), model = ModernEditorModel(session: a)
        try a.replaceTitle(range: 0..<0, with: "First ")
        var first = true
        let relay = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store(root)),
            endpoint: endpoint, relayKey: "room/native", token: "test-only") { request in
            if first { try a.replaceText(in: field(a), range: 0..<0, with: "Later "); first = false }
            return try response(server, request: request)
        }
        try await relay.exchange()
        #expect(server.document.blocks[0].text == "ABC😀" && relay.pendingChanges == 1)
        #expect(try await relay.persistence.store.load()?.restore().session.document == a.document)
        try await relay.exchange()
        #expect(relay.pendingChanges == 0 && server.document == a.document)
    }

    @Test func documentAndCredentialABARejectDelayedResponses() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = ModernEditorModel(session: try session("author")), peer = try session("peer"), server = try session("server")
        try peer.replaceTitle(range: 0..<5, with: "Must not apply"); try server.receive(peer.changes())
        let activation = Control(true)
        var relay: ModernNativeRelayClient!
        relay = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store(root)),
            endpoint: endpoint, relayKey: "room/native", token: "test-only") { request in
            if activation.value { model.isActive = false; model.isActive = true }
            else { relay.setToken("second"); relay.setToken("test-only") }
            return try response(server, request: request)
        }
        let original = try model.session.save()
        try await relay.exchange(); activation.value = false; try await relay.exchange()
        #expect(try model.session.save() == original && relay.receipt.received.isEmpty && relay.peers.isEmpty)
    }

    @Test func rejectedRecoveryIsDurableAndOnlyOwnBirthIsExplicitlyRepaired() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try session("author"), peer = try session("peer"), server = try session("server")
        _ = try a.insertBlock(.paragraph(id: "collision", text: "Own"))
        let own = try #require(a.changes().changes.first?.id)
        _ = try peer.insertBlock(.paragraph(id: "collision", text: "Peer")); try server.receive(peer.changes())
        let persistence = ModernPersistenceController(model: ModernEditorModel(session: a), store: store(root))
        let transport: ModernNativeRelayTransport = { request in
            do { return try response(server, request: request) }
            catch ModernSessionError.recoveryRequired(let recovery) {
                let bytes = try JSONSerialization.data(withJSONObject: ["error": "modernRecoveryRequired",
                    "recovery": JSONSerialization.jsonObject(with: JSONEncoder().encode(recovery))])
                return ModernRelayHTTPResponse(status: 409, data: bytes)
            }
        }
        let relay = try ModernNativeRelayClient(persistence: persistence, endpoint: endpoint, relayKey: "room/native", token: "test-only", transport: transport)
        let original = try a.save()
        await #expect(throws: ModernNativeRelayError.recoveryNeedsRetry) { try await relay.exchange() }
        #expect(try a.save() == original && relay.receipt.received.isEmpty)
        let pair = try #require(try await persistence.store.load())
        #expect(pair.recovery != nil && pair.relay?.receipt.received.isEmpty == true)
        relay.close()
        let opened = try await ModernNativeRelayClient.open(store: persistence.store, endpoint: endpoint, relayKey: "room/native", token: "test-only", transport: transport)
        try opened.persistence.model.session.repairUndo([own])
        try await opened.exchange()
        let expected = try ModernDocument(documentID: "native", title: "Title", blocks: [.paragraph(id: "collision", text: "Peer")] + session("baseline").document.blocks)
        #expect(opened.persistence.model.document == expected && server.document == expected && opened.pendingChanges == 0)
    }

    @Test func heldPeerReceiptAndOriginalDraftReopenWithoutResumingComposition() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try session("author"), peer = try session("peer"), server = try session("server")
        try a.replaceText(in: field(a), range: 0..<0, with: "Own ")
        let release = try a.holdRemoteChanges(); defer { try? release() }
        let draft = ModernPendingInput(target: try a.captureTextRange(in: field(a), start: 4, end: 4), text: "東京😀", selection: 4..<4, reason: "Original marked input")
        a.isComposing = true
        try peer.replaceTitle(range: 0..<5, with: "Peer title"); try server.receive(peer.changes())
        let model = ModernEditorModel(session: a, pendingInputs: [draft]), persistence = ModernPersistenceController(model: model, store: store(root))
        let relay = try ModernNativeRelayClient(persistence: persistence, endpoint: endpoint, relayKey: "room/native", token: "test-only") { try response(server, request: $0) }
        try await relay.exchange()
        #expect(model.document.title == "Title" && relay.pendingChanges == 0)
        relay.close()
        let opened = try await ModernNativeRelayClient.open(store: persistence.store, endpoint: endpoint, relayKey: "room/native", token: "") { _ in
            throw ModernNativeRelayError.rejected(status: 401)
        }
        #expect(!opened.persistence.model.session.isComposing && Array(opened.persistence.model.pendingInputs.values) == [draft])
        #expect(opened.persistence.model.document.title == "Title")
        try #require(opened.restoredHost).resumeDeferredChanges()
        #expect(opened.persistence.model.document.title == "Peer title")
        try opened.persistence.model.undo()
        #expect(opened.persistence.model.document.blocks[0].text == "ABC😀" && opened.persistence.model.document.title == "Peer title")
    }

    @Test func malformedScopeDuplicateKeysAndUnknownReceiptCannotPublishPeerWork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = ModernEditorModel(session: try session("author")), peer = try session("peer"), server = try session("server")
        try peer.replaceTitle(range: 0..<5, with: "Not accepted"); try server.receive(peer.changes())
        let mode = Control(0)
        let relay = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store(root)),
            endpoint: endpoint, relayKey: "room/native", token: "test-only") { request in
            let valid = try response(server, request: request)
            if mode.value == 0 {
                let text = String(decoding: valid.data, as: UTF8.self)
                return ModernRelayHTTPResponse(status: 200, data: Data(text.replacingOccurrences(of: "\"batch\":", with: "\"batch\":{},\"batch\":").utf8))
            }
            var json = try #require(JSONSerialization.jsonObject(with: valid.data) as? [String: Any])
            var receipt = try #require(json["state"] as? [String: Any])
            if mode.value == 1 { receipt["epoch"] = "other" }
            else { receipt["received"] = [["actor": "unknown", "counter": 1]] }
            json["state"] = receipt
            return ModernRelayHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: json))
        }
        let original = try model.session.save()
        for next in 0..<3 {
            mode.value = next
            await #expect(throws: (any Error).self) { try await relay.exchange() }
            #expect(try model.session.save() == original && relay.receipt.received.isEmpty)
        }
        #expect(throws: ModernNativeRelayError.clientAlreadyAttached) {
            try ModernNativeRelayClient(persistence: relay.persistence, endpoint: endpoint, relayKey: "room/native", token: "test-only")
        }
        #expect(throws: ModernNativeRelayError.invalidEndpoint) {
            try ModernNativeRelayClient(persistence: relay.persistence, endpoint: URL(string: "https://user:secret@example.com/room?token=secret")!, relayKey: "room/native", token: "")
        }
    }

    @Test func capacityFailureRetainsCompleteLocalHistoryAndReceipt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try session("author"), model = ModernEditorModel(session: a)
        try a.replaceText(in: field(a), range: 0..<0, with: String(repeating: "世界😀", count: 1000))
        let relay = try ModernNativeRelayClient(persistence: ModernPersistenceController(model: model, store: store(root)),
            endpoint: endpoint, relayKey: "room/native", token: "test-only") { _ in
            ModernRelayHTTPResponse(status: 413, data: Data(#"{"error":"transportCapacityExceeded","maxBytes":8000000}"#.utf8))
        }
        let original = try a.save()
        await #expect(throws: ModernNativeRelayError.transportCapacityExceeded(maxBytes: 8_000_000)) { try await relay.exchange() }
        #expect(try a.save() == original && relay.pendingChanges == 1 && relay.receipt.received.isEmpty)
        #expect(try await relay.persistence.store.load()?.accepted == original)
    }
}
