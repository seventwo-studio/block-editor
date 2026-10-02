import BlockEditorCore
import Testing

@Test(arguments: [false, true], ["a", "z"]) func v4SequentialInsertionKeepsObservedRunOrderAndPeerUndo(list: Bool, actor: String) throws {
    let content = [textNode("C", marks: [.object(["type": .string("bold")])])]
    let block = try Block(fields: list ? ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("i"), "content": .array(content), "checked": .bool(true)])])] : ["id": .string("p"), "type": .string("paragraph"), "content": .array(content)])
    let document = try Document(blocks: [block]), address = list ? TextAddress("p", path: ["items", "i", "content"]) : TextAddress("p")
    let a = try WritingSession(documentID: "sequential", actorID: actor, epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "sequential", actorID: "m", epoch: "v4", document: document, protocolVersion: 4)
    try a.replaceText(at: address, range: 0..<0, with: "東京")
    try a.replaceText(at: address, range: 1..<1, with: "😀")
    #expect(try a.text(at: address) == "東😀京C")
    let caret = try a.replaceText(at: address, range: 4..<4, with: "X")
    #expect(try a.text(at: address) == "東😀京XC" && a.resolve(caret).offset == 5)
    try b.replaceText(at: address, range: 1..<1, with: "R"); let remote = b.changes(); try a.receive(remote); try b.receive(a.changes()); try a.receive(remote)
    #expect(try a.text(at: address) == "東😀京XCR" && a.document == b.document)
    let reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); #expect(try reopened.text(at: address) == "東😀京CR")
    try reopened.redo(); #expect(reopened.document == a.document)
    let accepted = try a.save(); #expect(throws: EditorError.invalidRange) { try a.replaceText(at: address, range: 2..<2, with: "invalid") }; #expect(try a.save() == accepted)
}

@Test(arguments: [false, true]) func v4SoftBreakAfterInsertedRunSurvivesTransferredAndJoinedHistory(splitFirst: Bool) throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "AC")])
    let a = try WritingSession(documentID: "boundary-history", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    try a.replaceText(at: TextAddress("p"), range: 1..<1, with: "東京")
    var address = TextAddress("p")
    if splitFirst {
        try a.splitParagraph(at: address, range: 1..<1, newBlockID: "tail"); address = TextAddress("tail")
    } else {
        try a.splitParagraph(at: address, range: 0..<0, newBlockID: "tail")
        try a.mergeParagraphs(left: a.node(at: NodeAddress("p")), right: a.node(at: NodeAddress("tail")))
    }
    let offset = splitFirst ? 2 : 3
    try a.softBreak(at: address, range: offset..<offset)
    #expect(try a.text(at: address) == (splitFirst ? "東京\nC" : "A東京\nC"))
    let reopened = try WritingSession.restore(a.save(), actorID: "a"); try reopened.undo()
    #expect(try reopened.text(at: address) == (splitFirst ? "東京C" : "A東京C"))
    try reopened.redo(); #expect(reopened.document == a.document)
}

@Test func v4InsertionAfterReferenceNeighborRetainsAtomicPayloadAndMarks() throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("t"), "label": .string("TASK")])
    let document = try Document(blocks: [Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([reference, textNode("C", marks: [.object(["type": .string("italic")])])])])])
    let a = try WritingSession(documentID: "boundary-rich", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    try a.replaceText(at: TextAddress("p"), range: 4..<4, with: "東京")
    try a.replaceText(at: TextAddress("p"), range: 6..<6, with: "X")
    #expect(a.document.blocks[0].text == "TASK東京XC")
    let content = try #require(a.document.blocks[0].fields["content"]?.array)
    #expect(content.first == reference)
    #expect(content.last?["marks"] == .array([.object(["type": .string("italic")])]))
    let accepted = try a.save(); #expect(throws: EditorError.invalidRange) { try a.replaceText(at: TextAddress("p"), range: 1..<2, with: "invalid") }; #expect(try a.save() == accepted)
}
