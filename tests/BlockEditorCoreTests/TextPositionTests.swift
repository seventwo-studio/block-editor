import BlockEditorCore
import Foundation
import Testing

@Test func textPositionsFollowRemoteEditsDeletionUndoAndRestore() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "A😀BC")])
    let a = try EditorSession(documentID: "positions", actorID: "a", document: baseline)
    let b = try EditorSession(documentID: "positions", actorID: "b", document: baseline)
    let address = TextAddress("p"), saved = try a.save()
    let beforeB = try a.position(at: address, offset: 3)
    let afterEmoji = try a.position(at: address, offset: 3, affinity: .after)
    let start = try a.position(at: address, offset: 0, affinity: .after)
    let end = try a.position(at: address, offset: 5)
    #expect(try a.save() == saved)
    #expect(throws: EditorError.invalidRange) { try a.position(at: address, offset: 2) }
    try b.replaceText(at: address, range: 3..<3, with: "x")
    try b.replaceText(at: address, range: 0..<0, with: "!")
    try a.receive(b.changes())
    #expect(try a.offset(of: beforeB) == 5)
    #expect(try a.offset(of: afterEmoji) == 4)
    #expect(try a.offset(of: start) == 0)
    #expect(try a.offset(of: end) == 7)
    try b.replaceText(at: address, range: 2..<4, with: "")
    try a.receive(b.changes())
    #expect(try a.offset(of: beforeB) == 3)
    #expect(try a.offset(of: afterEmoji) == 2)
    let restored = try EditorSession.restore(a.save(), actorID: "a")
    let decoded = try JSONDecoder().decode(TextPosition.self, from: JSONEncoder().encode(beforeB))
    #expect(try restored.offset(of: decoded) == 3)
    try b.undo(); try restored.receive(b.changes())
    #expect(try restored.offset(of: beforeB) == 5)
    #expect(try restored.offset(of: afterEmoji) == 4)
    try restored.delete(blockID: "p")
    #expect(throws: EditorError.invalidPath) { try restored.offset(of: beforeB) }
    try restored.undo()
    #expect(try restored.offset(of: beforeB) == 5)
}

@Test func textPositionsWaitForMissingCausalAnchorsAndRejectOtherDocuments() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p")])
    let a = try EditorSession(documentID: "positions", actorID: "a", document: baseline)
    let b = try EditorSession(documentID: "positions", actorID: "b", document: baseline)
    let address = TextAddress("p")
    try b.replaceText(at: address, range: 0..<0, with: "Y")
    try b.replaceText(at: address, range: 1..<1, with: "Z")
    let position = try b.position(at: address, offset: 1)
    let changes = b.changes().changes
    try a.receive(ChangeBatch(documentID: "positions", baseline: baseline, changes: [changes[1]]))
    #expect(throws: EditorError.invalidRange) { try a.offset(of: position) }
    try a.receive(b.changes())
    #expect(try a.offset(of: position) == 1)
    let other = try EditorSession(documentID: "other", actorID: "other", document: baseline)
    #expect(throws: EditorError.differentDocument) { try other.offset(of: position) }
}

@Test func nestedPositionsRespectAtomicReferencesAndDoNotChangeSavedState() throws {
    let reference: JSONValue = .object(["type": .string("mention"), "entityId": .string("person"), "entityType": .string("user"), "label": .string("Mira")])
    let baseline = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("unordered"),
        "items": .array([.object(["id": .string("item"), "content": .array([reference, textNode("x")])])])])])
    let session = try EditorSession(documentID: "nested", actorID: "a", document: baseline)
    let address = TextAddress("list", path: ["items", "item", "content"])
    let saved = try session.save()
    let interior = try session.position(at: address, offset: 2)
    #expect(try session.offset(of: interior) == 2)
    let position = try session.position(at: address, offset: 4)
    #expect(try session.offset(of: position) == 4)
    #expect(try session.save() == saved)
    try session.replaceText(at: address, range: 0..<4, with: "😀")
    #expect(try session.offset(of: position) == 2)
    #expect(try session.offset(of: interior) == 2)
}
