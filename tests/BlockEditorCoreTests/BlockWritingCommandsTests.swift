import BlockEditorCore
import Foundation
import Testing

private func commandsSession(_ blocks: [Block], actor: String = "a") throws -> WritingSession {
    try WritingSession(documentID: "block-commands", actorID: actor, epoch: "commands-v4", document: Document(blocks: blocks), protocolVersion: 4)
}
private let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("t"), "label": .string("TASK")])
private func listBlock(_ items: [JSONValue], style: String = "todo") throws -> Block {
    try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string(style), "items": .array(items), "extension": .object(["keep": .bool(true)])])
}

@Test func blockConversionKeepsIdentityRichContentAndAuthorUndoAfterReopen() throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A😀", marks: [.object(["type": .string("bold")])]), reference]), "extension": .object(["opaque": .array([.number(1), .bool(true)])])])
    let a = try commandsSession([block]), b = try commandsSession([block], actor: "b")
    let node = try a.node(at: NodeAddress("p"))
    let caret = try a.convertBlock(at: TextAddress("p"), offset: 1, to: WritingBlockTarget(type: "heading", level: 2))
    #expect(try a.node(at: NodeAddress("p")) == node)
    #expect(a.changes().changes.count == 1)
    try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "R", marks: [])
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.resolve(caret).offset == 2)
    #expect(a.document.blocks[0].fields["extension"] == block.fields["extension"])
    #expect(a.document.blocks[0].fields["content"]?.array?.last == reference)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks[0].type == "paragraph")
    #expect(try reopened.text(at: TextAddress("p")) == "RA😀TASK")
    #expect(reopened.document.blocks[0].fields["level"] == nil)
    try reopened.redo()
    #expect(reopened.document == a.document)
}

@Test func markdownHeadingConsumesPrefixInOneUndoAndRespectsPolicyAndComposition() throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("## café "), reference]), "extension": .string("keep")])
    let a = try commandsSession([block])
    let before = try a.save()
    a.allowedBlockTypes = ["paragraph"]
    #expect(throws: EditorError.restrictedBlock("heading")) { try a.markdownShortcut(at: TextAddress("p"), offset: 3) }
    #expect(try a.save() == before)
    a.allowedBlockTypes = nil; a.isComposing = true
    #expect(throws: WritingSessionError.compositionActive) { try a.markdownShortcut(at: TextAddress("p"), offset: 3) }
    a.isComposing = false
    let caret = try a.markdownShortcut(at: TextAddress("p"), offset: 3)
    #expect(a.document.blocks[0].id == "p")
    #expect(a.document.blocks[0].fields["level"] == .number(2))
    #expect(try a.text(at: TextAddress("p")) == "café TASK")
    #expect(try a.resolve(caret).offset == 0)
    #expect(a.changes().changes.count == 1)
    try a.undo(); #expect(a.document.blocks == [block])
    try a.redo(); #expect(try a.text(at: TextAddress("p")) == "café TASK")
}

@Test func listContinuationKeepsMarksReferencesChildrenAndRemoteSuffix() throws {
    let item: JSONValue = .object(["id": .string("i"), "content": .array([textNode("A😀", marks: [.object(["type": .string("bold")])]), reference]), "checked": .bool(true), "extension": .string("item"), "children": .array([.object(["id": .string("child"), "content": .array([textNode("keep")])])])])
    let block = try listBlock([item]); let a = try commandsSession([block]), b = try commandsSession([block], actor: "b")
    let field = TextAddress("list", path: ["items", "i", "content"])
    let caret = try a.enterListItem(at: field, range: 1..<1, newItemID: "next")
    let next = TextAddress("list", path: ["items", "next", "content"])
    try b.replaceText(at: field, range: 3..<3, with: "R", marks: [])
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.text(at: field) == "A")
    #expect(try a.text(at: next) == "😀RTASK")
    #expect(try a.resolve(caret).offset == 0)
    let items = try #require(a.document.blocks[0].fields["items"]?.array)
    #expect(items[0]["children"] == item["children"])
    #expect(items[1]["checked"] == .bool(false))
    #expect(items[1]["extension"] == .string("item"))
    #expect(items[1]["content"]?.array?.last == reference)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(try reopened.text(at: field) == "A😀RTASK")
    #expect(reopened.document.blocks[0].fields["items"]?.array?.count == 1)
}

@Test func emptyNestedListItemOutdentsWithoutChangingIdentity() throws {
    let empty: JSONValue = .object(["id": .string("empty"), "content": .array([]), "checked": .bool(true), "extension": .string("keep")])
    let parent: JSONValue = .object(["id": .string("parent"), "content": .array([textNode("parent")]), "children": .array([empty])])
    let block = try listBlock([parent]); let a = try commandsSession([block])
    let field = TextAddress("list", path: ["items", "parent", "children", "empty", "content"])
    let identity = try a.node(at: NodeAddress("list", path: ["items", "parent", "children", "empty"]))
    let caret = try a.enterListItem(at: field, range: 0..<0, newItemID: "unused")
    #expect(try a.address(of: identity).path == ["items", "empty"])
    #expect(try a.resolve(caret).address.identity == identity)
    #expect(a.document.blocks[0].fields["items"]?.array?.last == empty)
    try a.undo(); #expect(a.document.blocks == [block])
}

@Test func emptyLastRootItemExitsAndUndoRetainsConcurrentRemoteInput() throws {
    let first: JSONValue = .object(["id": .string("first"), "content": .array([textNode("one")])])
    let last: JSONValue = .object(["id": .string("empty"), "content": .array([]), "extension": .string("keep")])
    let block = try listBlock([first, last]); let a = try commandsSession([block]), b = try commandsSession([block], actor: "b")
    let owner = try a.node(at: NodeAddress("list")), field = TextAddress("list", path: ["items", "empty", "content"])
    let caret = try a.enterListItem(at: field, range: 0..<0, newItemID: "unused")
    #expect(try a.node(at: NodeAddress("list")) == owner)
    #expect(a.document.blocks[1].id == "empty")
    #expect(a.document.blocks[1].fields["extension"] == .string("keep"))
    try b.replaceText(at: field, range: 0..<0, with: "R", marks: [])
    try a.receive(b.changes())
    #expect(try a.text(at: TextAddress("empty")) == "R")
    #expect(try a.resolve(caret).address.identity != nil)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks.count == 1)
    #expect(try reopened.text(at: field) == "R")
    #expect(reopened.document.blocks[0].fields["extension"] == block.fields["extension"])
}

@Test func v3NewBlockCommandsLeaveAcceptedStateUntouched() throws {
    let a = try WritingSession(documentID: "v3-commands", actorID: "a", epoch: "v3", document: Document(blocks: [Block.paragraph(id: "p", text: "# keep")]))
    let before = try a.save()
    #expect(throws: EditorError.unsupportedVersion(3)) { try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "heading")) }
    #expect(throws: EditorError.unsupportedVersion(3)) { try a.markdownShortcut(at: TextAddress("p"), offset: 2) }
    #expect(try a.save() == before)
    let item: JSONValue = .object(["id": .string("empty"), "content": .array([])])
    let list = try WritingSession(documentID: "v3-list", actorID: "a", epoch: "v3", document: Document(blocks: [listBlock([item])]))
    let listBefore = try list.save()
    #expect(throws: EditorError.unsupportedVersion(3)) { try list.enterListItem(at: TextAddress("list", path: ["items", "empty", "content"]), range: 0..<0, newItemID: "unused") }
    #expect(try list.save() == listBefore)
}

@Test func concurrentConversionAndParagraphSplitConvergeWithRemotePreservingUndo() throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try commandsSession([block]), b = try commandsSession([block], actor: "b")
    let original = try a.node(at: NodeAddress("p"))
    try a.convertBlock(at: TextAddress("p"), offset: 1, to: WritingBlockTarget(type: "heading", level: 2))
    try b.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    let aa = a.changes(), bb = b.changes()
    try a.receive(bb); try b.receive(aa); try a.receive(bb)
    #expect(a.document == b.document)
    #expect(try a.node(at: NodeAddress("p")) == original)
    #expect(a.document.blocks.map(\.text) == ["ab", "cd"])
    #expect(a.document.blocks.map(\.type) == ["heading", "paragraph"])
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks.map(\.type) == ["paragraph", "paragraph"])
    #expect(reopened.document.blocks.map(\.text) == ["ab", "cd"])
    try b.receive(reopened.changes()); try b.undo()
    #expect(b.document.blocks == [block])
}

@Test func concurrentDestinationConversionAndParagraphMergePreserveIdentityAndAuthorUndo() throws {
    let blocks = [try Block.paragraph(id: "left", text: "ab"), try Block.paragraph(id: "right", text: "cd")]
    let a = try commandsSession(blocks), b = try commandsSession(blocks, actor: "b")
    let left = try a.node(at: NodeAddress("left")), right = try a.node(at: NodeAddress("right"))
    let caret = try a.convertBlock(at: TextAddress("left"), offset: 1, to: WritingBlockTarget(type: "heading", level: 2))
    try b.mergeParagraphs(left: left, right: right)
    let aa = a.changes(), bb = b.changes()
    try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document)
    #expect(a.document.blocks.count == 1 && a.document.blocks[0].type == "heading")
    #expect(try a.node(at: NodeAddress("left")) == left)
    #expect(try a.text(at: TextAddress("left")) == "abcd")
    #expect(try a.resolve(caret).offset == 1)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks == [try Block.paragraph(id: "left", text: "abcd")])
    try b.receive(reopened.changes()); try b.undo()
    #expect(b.document.blocks == blocks)
}

@Test(arguments: [false, true], [false, true]) func concurrentJoinedSourceConversionRetainsUnionForAuthorReconciliation(reverseActors: Bool, repairMerge: Bool) throws {
    let blocks = [try Block.paragraph(id: "left", text: "ab"), try Block.paragraph(id: "right", text: "cd")]
    let conversionActor = reverseActors ? "z" : "a", mergeActor = reverseActors ? "a" : "b"
    let a = try commandsSession(blocks, actor: conversionActor), b = try commandsSession(blocks, actor: mergeActor)
    let left = try a.node(at: NodeAddress("left")), right = try a.node(at: NodeAddress("right"))
    try a.convertBlock(at: TextAddress("right"), offset: 1, to: WritingBlockTarget(type: "heading", level: 2))
    try b.mergeParagraphs(left: left, right: right)
    let beforeA = try a.save(), beforeB = try b.save(), aa = a.changes(), bb = b.changes()
    do { try a.receive(bb); Issue.record("Source conversion conflict was silently accepted") } catch WritingSessionError.recoveryRequired { }
    do { try b.receive(aa); Issue.record("Source conversion conflict was silently accepted") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == beforeA && b.save() == beforeB)
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    #expect(a.mergeRecovery?.batch.changes.count == 2)
    if repairMerge {
        try b.repairUndo(ChangeID(counter: 1, actor: mergeActor))
        try a.receive(b.changes())
        #expect(a.document == b.document)
        #expect(a.document.blocks.map(\.text) == ["ab", "cd"])
        #expect(a.document.blocks.map(\.type) == ["paragraph", "heading"])
    } else {
        try a.repairUndo(ChangeID(counter: 1, actor: conversionActor))
        try b.receive(a.changes())
        #expect(a.document == b.document)
        #expect(a.document.blocks == [try Block.paragraph(id: "left", text: "abcd")])
    }
}

@Test func duplicateRecursivelyRespectsAuthoringPolicyWithoutChangingAcceptedHistory() throws {
    let heading = try Block(fields: ["id": .string("h"), "type": .string("heading"), "level": .number(2), "content": .array([textNode("keep")])])
    let nested = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([]), "children": .array([.object(heading.fields)]), "host": .string("keep")])
    let item: JSONValue = .object(["id": .string("i"), "content": .array([textNode("item")])])
    let list = try listBlock([item])
    for (block, allowed, denied) in [(heading, Set(["paragraph"]), "heading"), (nested, Set(["toggle", "paragraph"]), "heading")] {
        let session = try commandsSession([block])
        let selection = WritingSelection(nodes: [try session.node(at: NodeAddress(block.id))])
        let before = try session.save(); session.allowedBlockTypes = allowed
        #expect(try session.copy(selection).nodes == [.object(block.fields)])
        #expect(throws: EditorError.restrictedBlock(denied)) { try session.duplicate(selection, into: .root) }
        #expect(try session.save() == before)
        #expect(session.changes().changes.isEmpty)
        session.allowedBlockTypes = nil
        _ = try session.duplicate(selection, into: .root)
        #expect(session.document.blocks.count == 2)
    }
    let session = try commandsSession([list])
    let root = try session.node(at: NodeAddress("list"))
    let selected = WritingSelection(nodes: [try session.node(at: NodeAddress("list", path: ["items", "i"]))])
    let before = try session.save(); session.allowedBlockTypes = ["paragraph"]
    #expect(throws: EditorError.restrictedBlock("list")) { try session.duplicate(selected, into: NodeCollection(owner: root, field: "items")) }
    #expect(try session.save() == before)
    #expect(session.changes().changes.isEmpty)
}
