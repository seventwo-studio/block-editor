import BlockEditorCore
import BlockEditorLocalDemo
import Foundation
import Testing

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOCK_EDITOR_RELAY_URL"] != nil))
func appleRelayRecoversOfflineDraftsAndDeferredComposition() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = try #require(environment["BLOCK_EDITOR_RELAY_URL"].flatMap(URL.init(string:)))
    try #require(["127.0.0.1", "localhost"].contains(root.host ?? ""))
    let token = try #require(environment["BLOCK_EDITOR_RELAY_TOKEN"])
    let endpoint = root.appendingPathComponent("rooms/apple-\(UUID().uuidString)")
    let a = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "apple-a")
    let b = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "apple-b")
    let address = TextAddress("p")
    let baseline = try a.session.text(at: address)
    let savedBeforePresence = try a.session.save()
    try await a.exchange(); try await b.exchange(); try await a.exchange()
    #expect(a.peers.contains { $0.actor == "apple-b" })
    #expect(try a.session.save() == savedBeforePresence)

    a.setConnected(false)
    #expect(a.peers.isEmpty)
    try a.session.replaceText(at: address, range: 0..<0, with: "offline 😀 ")
    a.setToken("invalid-while-offline")
    try await a.exchange() // A disconnected client must not issue this unauthorized request.
    #expect(a.lastError == nil)
    #expect(a.pendingChanges > 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    do { let draft = try LocalDraft(file: file); try draft.save(a.session, endpoint: endpoint) }

    try b.session.replaceText(at: address, range: 0..<0, with: "remote 世界 ")
    try await b.exchange()
    let draft = try LocalDraft(file: file)
    let restored = try #require(try draft.restore(endpoint: endpoint))
    let resumed = LocalRelayClient(session: restored, endpoint: endpoint, token: token)
    #expect(restored.canUndo)
    try await resumed.exchange(); try await b.exchange(); try await resumed.exchange()
    #expect(try restored.document == b.session.document)
    #expect(try restored.text(at: address).contains("offline 😀 "))
    #expect(try restored.text(at: address).contains("remote 世界 "))
    #expect(resumed.pendingChanges == 0)
    try restored.undo(); try await resumed.exchange(); try await b.exchange()
    #expect(try restored.text(at: address) == "remote 世界 " + baseline)
    #expect(try restored.document == b.session.document)

    let receiptBeforeHold = restored.syncState
    let finish = restored.deferRemoteChanges()
    try b.session.replaceText(at: address, range: 0..<0, with: "during composition ")
    try await b.exchange(); try await resumed.exchange()
    #expect(restored.syncState == receiptBeforeHold)
    #expect(try !restored.text(at: address).contains("during composition "))
    try finish(); try await resumed.exchange()
    #expect(try restored.document == b.session.document)
    let observer = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "apple-observer")
    #expect(try observer.session.document == restored.document)

    resumed.setToken("invalid")
    await #expect(throws: (any Error).self) { try await resumed.exchange() }
    #expect(resumed.lastError != nil)
    resumed.setToken(token); try await resumed.exchange()
    #expect(resumed.lastError == nil)
}
