import BlockEditorCore
import Foundation
import Testing

@Test func inlineReconciliationKeepsFormattingOperationsSeparateFromText() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "abc")])
    let a = try EditorSession(documentID: "d", actorID: "a", document: document)
    let b = try EditorSession(documentID: "d", actorID: "b", document: document)
    try a.setInline(at: TextAddress("p"), nodes: [textNode("abc", marks: [.object(["type": .string("bold")])])])
    try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "X")
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(try a.document.blocks[0].text == "aXbc")
    try a.undo(); try b.receive(a.changes())
    #expect(try b.document.blocks[0].text == "aXbc")
    #expect(try b.document.blocks[0].fields["content"]?.array == [textNode("aXbc")])
}

@Test func partialReferenceEditBecomesPlainText() throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([
        .object(["type": .string("mention"), "entityType": .string("user"), "entityId": .string("u"), "label": .string("Alice")]), textNode(" follows")
    ])])
    let a = try EditorSession(documentID: "d", actorID: "a", document: Document(blocks: [block]))
    try a.setText(at: TextAddress("p"), to: "Alicia follows")
    #expect(try a.document.blocks[0].text == "Alicia follows")
    #expect(try a.document.blocks[0].fields["content"]?.array == [textNode("Alicia follows")])
    try a.undo()
    #expect(try a.document.blocks[0] == block)
}

@Test func codeUsesCharacterMergingToo() throws {
    let document = try Document(blocks: [Block(fields: ["id": .string("c"), "type": .string("code"), "code": .string("abc"), "language": .string("swift")])])
    let a = try EditorSession(documentID: "d", actorID: "a", document: document)
    let b = try EditorSession(documentID: "d", actorID: "b", document: document)
    let address = TextAddress("c", path: ["code"])
    try a.replaceText(at: address, range: 1..<1, with: "A")
    try b.replaceText(at: address, range: 1..<1, with: "B")
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(try a.document.blocks[0].fields["code"] == .string("aBAbc"))
}
