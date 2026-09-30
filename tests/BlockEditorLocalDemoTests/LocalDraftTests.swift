import BlockEditorCore
import BlockEditorLocalDemo
import Foundation
import Testing

@Test func draftRestoresExclusiveAuthorHistoryAndPreservesRemoteChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    let endpoint = URL(string: "http://127.0.0.1:4319/rooms/draft")!
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let remote = try EditorSession(documentID: "d", actorID: "remote", document: baseline)
    do {
        let draft = try LocalDraft(file: file)
        #expect(try draft.restore(endpoint: endpoint) == nil)
        #expect(throws: DraftError.alreadyOpen) { try LocalDraft(file: file) }
        let local = try EditorSession(documentID: "d", actorID: "local", document: baseline)
        try local.replaceText(at: TextAddress("p"), range: 5..<5, with: " local 😀")
        try draft.save(local, endpoint: endpoint)
    }
    try remote.replaceText(at: TextAddress("p"), range: 5..<5, with: " remote 世界")
    let draft = try LocalDraft(file: file)
    let restored = try #require(try draft.restore(endpoint: endpoint))
    #expect(restored.actorID == "local")
    #expect(restored.canUndo)
    try restored.receive(remote.changes())
    try remote.receive(restored.changes())
    #expect(try restored.document == remote.document)
    try restored.undo()
    #expect(try restored.text(at: TextAddress("p")) == "Hello remote 世界")
    let bytes = try Data(contentsOf: file)
    #expect(throws: DraftError.differentEndpoint) { try draft.restore(endpoint: URL(string: "http://127.0.0.1:4319/rooms/other")!) }
    #expect(try Data(contentsOf: file) == bytes)
    var incompatible = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    incompatible["version"] = 99
    let newer = try JSONSerialization.data(withJSONObject: incompatible)
    try newer.write(to: file)
    #expect(throws: DraftError.unsupportedVersion) { try draft.restore(endpoint: endpoint) }
    #expect(try Data(contentsOf: file) == newer)
}

@Test func corruptDraftIsNotSilentlyReplaced() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    let draft = try LocalDraft(file: file)
    let corrupt = Data("not a saved document".utf8)
    try corrupt.write(to: file)
    #expect(throws: (any Error).self) { try draft.restore(endpoint: URL(string: "http://localhost/room")!) }
    #expect(try Data(contentsOf: file) == corrupt)
}
