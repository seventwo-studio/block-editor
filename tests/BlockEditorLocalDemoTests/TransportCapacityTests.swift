import BlockEditorCore
import BlockEditorLocalDemo
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

private final class CapacityResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"transportCapacityExceeded","maxBytes":8000000}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func transportCapacityFailureRetainsHistoryForExportRestartAndRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = URL(string: "http://localhost/rooms/capacity")!
    let session = try EditorSession(documentID: "capacity", actorID: "author", document: Document(blocks: [.paragraph(id: "p", text: "Original")]), collaborationVersion: 2)
    try session.setText(at: TextAddress("p"), to: "Unacknowledged café 😀")
    let snapshot = try session.save(), receipts = session.syncState
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CapacityResponse.self]
    let transport = URLSession(configuration: configuration)
    defer { transport.invalidateAndCancel() }
    let client = LocalRelayClient(session: session, endpoint: endpoint, token: "test", transport: transport)
    await #expect(throws: RelayError.transportCapacityExceeded(maxBytes: 8_000_000)) { try await client.exchange() }
    #expect(client.transportCapacityBytes == 8_000_000)
    #expect(client.pendingChanges == 1)
    #expect(client.peers.isEmpty)
    #expect(try session.save() == snapshot)
    #expect(session.syncState == receipts)
    #expect(session.mergeRecovery == nil)
    let archive = directory.appendingPathComponent("retained.json")
    do {
        let draft = try LocalDraft(file: directory.appendingPathComponent("draft.json"))
        try draft.save(session, endpoint: endpoint)
        try draft.exportRecovery(session, endpoint: endpoint, to: archive)
    }
    let bytes = try Data(contentsOf: archive)
    let archiveStore = try LocalDraft(file: archive)
    let reopened = try #require(try archiveStore.restore(endpoint: endpoint))
    #expect(reopened.actorID != session.actorID)
    #expect(try reopened.document == session.document)
    #expect(reopened.changes() == session.changes())
    let retry = LocalRelayClient(session: reopened, endpoint: endpoint, token: "test", transport: transport)
    await #expect(throws: RelayError.transportCapacityExceeded(maxBytes: 8_000_000)) { try await retry.exchange() }
    #expect(retry.pendingChanges == 1)
    #expect(reopened.syncState == receipts)
    #expect(try Data(contentsOf: archive) == bytes)
    #expect(throws: DraftError.archiveExists) { try archiveStore.exportRecovery(reopened, endpoint: endpoint, to: archive) }
    #expect(try Data(contentsOf: archive) == bytes)
}
