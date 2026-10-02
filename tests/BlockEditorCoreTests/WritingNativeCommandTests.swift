import BlockEditorCore
import Testing

@Test(arguments: ["heading", "quote", "callout"]) func v4InlineEnterPreservesSourceAttributesRichSuffixAndAuthorUndo(type: String) throws {
    var fields: [String: JSONValue] = ["id": .string("p"), "type": .string(type), "content": .array([textNode("A😀B", marks: [.object(["type": .string("bold")])])]), "host": .string("keep")]
    if type == "heading" { fields["level"] = .number(2) }
    if type == "callout" { fields["variant"] = .string("info") }
    let document = try Document(blocks: [Block(fields: fields)])
    let a = try WritingSession(documentID: "inline-enter", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "inline-enter", actorID: "b", epoch: "v4", document: document, protocolVersion: 4)
    let origin = try a.node(at: NodeAddress("p"))
    let caret = try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "tail")
    #expect(a.document.blocks.map(\.text) == ["A", "😀B"])
    #expect(a.document.blocks[0].fields["host"] == .string("keep") && a.document.blocks[0].type == type)
    #expect(try a.node(at: NodeAddress("p")) == origin && a.resolve(caret).offset == 0)
    try b.replaceText(at: TextAddress("p"), range: 4..<4, with: "R"); try a.receive(b.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    try a.undo(); #expect(a.document.blocks.map(\.text) == ["A😀BR"])
    let legacy = try WritingSession(documentID: "legacy", actorID: "a", epoch: "v3", document: document)
    let accepted = try legacy.save()
    #expect(throws: EditorError.invalidPath) { try legacy.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "tail") }
    #expect(try legacy.save() == accepted)
}

@Test func v4ScalarMetadataIsAtomicAndCannotReplaceSchemaRichTextOrConversionAttributes() throws {
    let item: JSONValue = .object(["id": .string("i"), "content": .array([textNode("keep")]), "checked": .bool(false)])
    let block = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let a = try WritingSession(documentID: "leaf", actorID: "a", epoch: "v4", document: Document(blocks: [block]), protocolVersion: 4)
    let identity = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let accepted = try a.save()
    for path in [["content"], ["content", "text"], ["type"], ["id"], ["style"], ["children"], ["host", "items"]] {
        #expect(throws: EditorError.invalidPath) { try a.setNodeField(identity, path: path, value: .string("discard")) }
        #expect(try a.save() == accepted)
    }
    #expect(throws: EditorError.self) { try a.setNodeField(identity, path: ["checked"], value: .string("wrong")) }
    #expect(try a.save() == accepted)
    try a.setNodeField(identity, path: ["checked"], value: .bool(true))
    #expect(a.document.blocks[0].fields["items"]?.array?.first?["checked"] == .bool(true))
    let reopened = try WritingSession.restore(a.save(), actorID: "a"); try reopened.undo()
    #expect(reopened.document.blocks == [block])
}

@Test func v4ScalarMetadataPreservesOpaqueCompositeValuesAndRejectsActiveComposition() throws {
    let fields: [String: JSONValue] = ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("keep")]), "host": .object(["title": .string("before"), "token": .string("preserve")]), "hostArray": .array([.object(["id": .string("opaque"), "value": .string("keep")])])]
    let a = try WritingSession(documentID: "leaf-opaque", actorID: "a", epoch: "v4", document: Document(blocks: [Block(fields: fields)]), protocolVersion: 4)
    let node = try a.node(at: NodeAddress("p")), accepted = try a.save()
    for path in [["host"], ["hostArray"]] {
        #expect(throws: EditorError.invalidPath) { try a.setNodeField(node, path: path, value: .string("discard")) }
        #expect(try a.save() == accepted)
    }
    a.isComposing = true
    #expect(throws: WritingSessionError.compositionActive) { try a.setNodeField(node, path: ["host", "title"], value: .string("rejected")) }
    #expect(try a.save() == accepted); a.isComposing = false
    try a.setNodeField(node, path: ["host", "title"], value: .string("after"))
    #expect(a.document.blocks[0].fields["host"] == .object(["title": .string("after"), "token": .string("preserve")]))
    #expect(a.document.blocks[0].fields["hostArray"] == fields["hostArray"])
    try a.undo(); #expect(a.document.blocks[0].fields == fields)
}
