import BlockEditorCore
import Foundation
import Testing

@Test func sharedBridgeFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "bridge", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let bridge = EditorBridge()
    var last: JSONValue = .null
    for request in try #require(fixture["requests"]?.array) {
        last = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(request)))
        #expect(last["ok"] == .bool(true))
    }
    #expect(last["value"] == fixture["expected"])
}

@Test func invalidKnownShapesAreRejectedWithoutChangingTheDocument() throws {
    let session = try EditorSession(documentID: "doc", actorID: "a", document: Document(blocks: [.paragraph(id: "p", text: "keep")]))
    let before = try session.document
    #expect(throws: EditorError.self) {
        try session.insert(Block(fields: ["id": .string("h"), "type": .string("heading"), "level": .number(8)]))
    }
    #expect(throws: EditorError.self) {
        try session.setInline(at: TextAddress("p"), nodes: [.object(["type": .string("text"), "text": .string("bad"), "marks": .array([.object(["type": .string("unknown")])])])])
    }
    #expect(try session.document == before)
    #expect(!session.canUndo)
}
