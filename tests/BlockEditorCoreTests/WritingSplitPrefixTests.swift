import BlockEditorCore
import Testing

@Test(arguments: [false, true]) func v4SplitKeepsObservedInsertedPrefixAndPeerUndo(list: Bool) throws {
    let paragraph = try Block.paragraph(id: "p", text: "AB")
    let block = list ? try Block(fields: ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("i"), "content": .array([textNode("AB")]), "checked": .bool(true)])])]) : paragraph
    let document = try Document(blocks: [block]), address = list ? TextAddress("p", path: ["items", "i", "content"]) : TextAddress("p")
    let a = try WritingSession(documentID: "split-prefix", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "split-prefix", actorID: "b", epoch: "v4", document: document, protocolVersion: 4)
    try a.replaceText(at: address, range: 1..<1, with: "東京")
    try b.replaceText(at: address, range: 2..<2, with: "R"); try a.receive(b.changes())
    if list { try a.enterListItem(at: address, range: 3..<3, newItemID: "tail") }
    else { try a.splitParagraph(at: address, range: 3..<3, newBlockID: "tail") }
    #expect(try a.text(at: address) == "A東京")
    let tail = list ? TextAddress("p", path: ["items", "tail", "content"]) : TextAddress("tail")
    #expect(try a.text(at: tail) == "BR")
    try b.receive(a.changes()); #expect(a.document == b.document)
    try b.replaceText(at: tail, range: 1..<1, with: "X"); try a.receive(b.changes())
    try a.undo(); #expect(try a.text(at: address) == "A東京BXR")
    try a.redo(); #expect(try a.text(at: address) == "A東京" && a.text(at: tail) == "BXR")
}

@Test(arguments: ["a", "z"]) func v4ConcurrentCutsKeepEachObservedPrefixPartition(actor: String) throws {
    let document = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let a = try WritingSession(documentID: "split-prefix", actorID: actor, epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "split-prefix", actorID: "m", epoch: "v4", document: document, protocolVersion: 4)
    try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "first")
    try b.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "second")
    let aa = a.changes(), bb = b.changes(); try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.text) == ["a", "b", "cd"])
}

@Test(arguments: ["a", "z"]) func v4ConcurrentCutPreservesUnobservedInsertedPrefixInEarlierTail(actor: String) throws {
    let document = try Document(blocks: [Block.paragraph(id: "p", text: "AB")])
    let a = try WritingSession(documentID: "split-prefix", actorID: actor, epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "split-prefix", actorID: "m", epoch: "v4", document: document, protocolVersion: 4)
    try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "first")
    try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "東京😀")
    try b.splitParagraph(at: TextAddress("p"), range: 5..<5, newBlockID: "second")
    let aa = a.changes(), bb = b.changes(); try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.text) == ["A", "東京😀", "B"])
    try a.undo(); #expect(a.document.blocks.map(\.text) == ["A東京😀", "B"])
    try b.receive(a.changes()); try a.redo(); try b.receive(a.changes()); #expect(a.document == b.document)
    try b.undo(); #expect(b.document.blocks.map(\.text) == ["A", "東京😀B"])
}

@Test(arguments: [false, true]) func v4CausalSplitPinsEarlierDestinationAndJoinedPrefix(joinFirst: Bool) throws {
    let document = try Document(blocks: [Block.paragraph(id: "p", text: "ABCD")])
    let a = try WritingSession(documentID: "split-prefix", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "first")
    let root = try a.node(at: NodeAddress("p")), first = try a.node(at: NodeAddress("first"))
    if joinFirst { try a.mergeParagraphs(left: root, right: first) }
    let address = TextAddress(joinFirst ? "p" : "first")
    try a.replaceText(at: address, range: 1..<1, with: "東京")
    try a.splitParagraph(at: address, range: 3..<3, newBlockID: "second")
    #expect(a.document.blocks.map(\.text) == (joinFirst ? ["A東京", "BCD"] : ["A", "B東京", "CD"]))
    let reopened = try WritingSession.restore(a.save(), actorID: "a"); try reopened.undo()
    #expect(reopened.document.blocks.map(\.text) == (joinFirst ? ["A東京BCD"] : ["A", "B東京CD"]))
    try reopened.redo(); #expect(reopened.document == a.document)
}

@Test(arguments: [false, true], ["a", "z"]) func v4ObservedRichPrefixSelectionReplacementRetainsReferencesFormattingAndPeerUndo(list: Bool, actor: String) throws {
    let ref: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("t"), "label": .string("TASK")])
    let content: [JSONValue] = [textNode("A"), ref, textNode("B😀C", marks: [.object(["type": .string("bold")])])]
    let block = try Block(fields: list ? ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("i"), "content": .array(content), "checked": .bool(true), "host": .string("keep")])])] : ["id": .string("p"), "type": .string("paragraph"), "content": .array(content), "host": .string("keep")])
    let document = try Document(blocks: [block]), source = list ? TextAddress("p", path: ["items", "i", "content"]) : TextAddress("p")
    let a = try WritingSession(documentID: "rich-prefix", actorID: actor, epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "rich-prefix", actorID: "m", epoch: "v4", document: document, protocolVersion: 4)
    try a.replaceText(at: source, range: 5..<5, with: "東京")
    try b.format(at: source, range: 6..<8, markType: "italic", mark: .object(["type": .string("italic")]))
    try b.replaceText(at: source, range: 9..<9, with: "R"); try a.receive(b.changes())
    let caret = list ? try a.enterListItem(at: source, range: 7..<8, newItemID: "tail") : try a.splitParagraph(at: source, range: 7..<8, newBlockID: "tail")
    let tail = list ? TextAddress("p", path: ["items", "tail", "content"]) : TextAddress("tail")
    #expect(try a.text(at: source) == "ATASK東京" && a.text(at: tail) == "😀CR" && a.resolve(caret).offset == 0)
    let prefix = list ? a.document.blocks[0].fields["items"]?.array?.first?["content"]?.array : a.document.blocks[0].fields["content"]?.array
    #expect(prefix?.contains(ref) == true)
    let suffix = list ? a.document.blocks[0].fields["items"]?.array?.last?["content"]?.array : a.document.blocks[1].fields["content"]?.array
    #expect(suffix?.first?["marks"] == .array([.object(["type": .string("bold")]), .object(["type": .string("italic")])]))
    try b.receive(a.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(a.save(), actorID: actor); try reopened.undo()
    #expect(try reopened.text(at: source) == "ATASK東京B😀CR")
    try reopened.redo(); #expect(reopened.document == a.document)
}
