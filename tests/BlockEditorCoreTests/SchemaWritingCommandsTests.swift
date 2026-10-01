import BlockEditorCore
import Foundation
import Testing

private func schemaSession(_ blocks: [Block], actor: String = "a") throws -> WritingSession {
    try WritingSession(documentID: "schema-commands", actorID: actor, epoch: "schema-v4", document: Document(blocks: blocks), protocolVersion: 4)
}
private let schemaReference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("t"), "label": .string("TASK")])
@Test(arguments: ["ordered", "unordered", "todo"]) func schemaListConversionKeepsRootIdentityRichAtomsMetadataAndRemoteUndo(style: String) throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A😀", marks: [.object(["type": .string("bold")])]), schemaReference]), "extension": .object(["keep": .bool(true)])])
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    let original = try a.node(at: NodeAddress("p"))
    let caret = try a.convertBlock(at: TextAddress("p"), offset: 1, to: WritingBlockTarget(type: "list", style: style))
    let item = TextAddress("p", path: ["items", "p-item", "content"])
    #expect(try a.node(at: NodeAddress("p")) == original)
    #expect(a.document.blocks[0].id == "p" && a.document.blocks[0].type == "list")
    #expect(try a.node(at: NodeAddress("p", path: ["items", "p-item"])) != original)
    try b.replaceText(at: TextAddress("p"), range: 3..<3, with: "R", marks: [])
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.text(at: item) == "A😀RTASK")
    #expect(try a.resolve(caret).offset == 1)
    #expect(a.document.blocks[0].fields["extension"] == block.fields["extension"])
    #expect(a.document.blocks[0].fields["items"]?.array?.first?["content"]?.array?.last == schemaReference)
    try b.replaceText(at: item, range: 0..<0, with: "X", marks: [])
    try a.receive(b.changes())
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks[0].type == "paragraph")
    #expect(try reopened.text(at: TextAddress("p")) == "XA😀RTASK")
    #expect(try reopened.node(at: NodeAddress("p")) == original)
    try reopened.redo(); #expect(reopened.document == a.document)
}

@Test func schemaCodeShortcutAndEncodingRoundTripRetainIdentityAndBothOrigins() throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("```café😀")]), "extension": .string("keep")])
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    let original = try a.node(at: NodeAddress("p"))
    let caret = try a.markdownShortcut(at: TextAddress("p"), offset: 3)
    #expect(a.document.blocks[0].fields["code"] == .string("café😀"))
    #expect(try a.resolve(caret).offset == 0)
    try b.receive(a.changes())
    try b.replaceText(at: TextAddress("p", path: ["code"]), range: 0..<0, with: "X", marks: [])
    try a.receive(b.changes())
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(try reopened.text(at: TextAddress("p")) == "```Xcafé😀")
    #expect(try reopened.node(at: NodeAddress("p")) == original)
    try reopened.redo()
    try reopened.convertBlock(at: TextAddress("p", path: ["code"]), offset: 1, to: WritingBlockTarget(type: "paragraph"))
    #expect(try reopened.text(at: TextAddress("p")) == "Xcafé😀")
    #expect(try reopened.node(at: NodeAddress("p")) == original)
}

@Test func schemaRichCodeRejectionAndRemoteRichUnionPreserveAcceptedState() throws {
    for content in [[textNode("rich", marks: [.object(["type": .string("bold")])])], [schemaReference]] {
        let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array(content)])
        let a = try schemaSession([block]), before = try a.save()
        #expect(throws: EditorError.self) { try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "code")) }
        #expect(try a.save() == before)
    }
    let block = try Block.paragraph(id: "p", text: "plain")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "code"))
    let before = try a.save()
    try b.format(at: TextAddress("p"), range: 0..<1, markType: "bold", mark: .object(["type": .string("bold")]))
    do { try a.receive(b.changes()); Issue.record("Rich atoms were flattened into code") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == before && a.mergeRecovery?.reason == .schemaConstraint)
}

@Test func schemaSoleEmptyListExitKeepsRootIdentityAndRemoteReopenedUndo() throws {
    let item: JSONValue = .object(["id": .string("i"), "content": .array([]), "checked": .bool(true), "hostItem": .string("keep")])
    let block = try Block(fields: ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([item]), "extension": .string("root")])
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    let original = try a.node(at: NodeAddress("p")), field = TextAddress("p", path: ["items", "i", "content"])
    a.allowedBlockTypes = ["paragraph"]
    let caret = try a.enterListItem(at: field, range: 0..<0, newItemID: "unused")
    #expect(try a.node(at: NodeAddress("p")) == original)
    #expect(a.document.blocks[0].type == "paragraph" && a.document.blocks[0].id == "p")
    #expect(a.document.blocks[0].fields["checked"] == .bool(true))
    #expect(a.document.blocks[0].fields["hostItem"] == .string("keep"))
    #expect(try a.resolve(caret).offset == 0)
    try b.replaceText(at: field, range: 0..<0, with: "R", marks: [])
    try a.receive(b.changes())
    #expect(try a.text(at: TextAddress("p")) == "R")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks[0].type == "list")
    #expect(try reopened.text(at: field) == "R")
    #expect(try reopened.node(at: NodeAddress("p")) == original)
}

@Test func schemaConversionUndoProjectsPeerItemWithSameIdentityAndSuffix() throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    let original = try a.node(at: NodeAddress("p"))
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    let caret = try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    let peer = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "peer"])
    #expect(a.document.blocks.map(\.type) == ["paragraph", "paragraph"])
    #expect(a.document.blocks.map(\.text) == ["ab", "cd"])
    #expect(try a.node(at: NodeAddress("p")) == original)
    #expect(try a.node(at: NodeAddress("peer")) == peer)
    #expect(a.document.blocks[1].fields["checked"] == .bool(false))
    #expect(try a.resolve(caret).address.identity == peer)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
    try reopened.redo()
    #expect(reopened.document.blocks[0].type == "list")
}

@Test func schemaV4CannotEnterV3SessionAndRestrictionsRemainAtomic() throws {
    let block = try Block.paragraph(id: "p", text: "- text")
    let a = try schemaSession([block])
    a.allowedBlockTypes = ["paragraph"]
    let before = try a.save()
    #expect(throws: EditorError.restrictedBlock("list")) { try a.markdownShortcut(at: TextAddress("p"), offset: 2) }
    #expect(try a.save() == before)
    a.allowedBlockTypes = nil
    try a.markdownShortcut(at: TextAddress("p"), offset: 2)
    let legacy = try WritingSession(documentID: "schema-commands", actorID: "old", epoch: "schema-v4", document: Document(blocks: [block]))
    let old = try legacy.save()
    #expect(throws: EditorError.unsupportedVersion(4)) { try legacy.receive(a.changes()) }
    #expect(try legacy.save() == old)
    let spoof = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: a.changes().changes, version: 3)
    #expect(throws: EditorError.invalidChange) { try legacy.receive(spoof) }
    #expect(try legacy.save() == old)
    #expect(a.changes().version == 4 && a.syncState.version == 4)
}

@Test func schemaUndoKeepsPeerSubtreeIdentityMarksReferencesAndOpaqueChildren() throws {
    let sourceItem: JSONValue = .object(["id": .string("source"), "content": .array([textNode("peer😀", marks: [.object(["type": .string("bold")])]), schemaReference]), "checked": .bool(true), "hostPeer": .string("keep"), "children": .array([.object(["id": .string("child"), "content": .array([textNode("child"), schemaReference]), "hostChild": .number(7)])])])
    let foreign = try Block(fields: ["id": .string("foreign"), "type": .string("list"), "style": .string("todo"), "items": .array([sourceItem])])
    let block = try Block.paragraph(id: "p", text: "original")
    let a = try schemaSession([block, foreign]), b = try schemaSession([block, foreign], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    let root = try b.node(at: NodeAddress("p")), source = try b.node(at: NodeAddress("foreign", path: ["items", "source"]))
    let duplicated = try b.duplicate(WritingSelection(nodes: [source]), into: NodeCollection(owner: root, field: "items"))
    let peer = try #require(duplicated.nodes.first)
    let copied = try #require(b.copy(duplicated).nodes.first)
    let peerLabel = try #require(copied["id"]?.string), childLabel = try #require(copied["children"]?.array?.first?["id"]?.string)
    let child = try b.node(at: NodeAddress("p", path: ["items", peerLabel, "children", childLabel]))
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.node(at: NodeAddress(peerLabel)) == peer)
    #expect(try a.node(at: NodeAddress(peerLabel, path: ["children", childLabel])) == child)
    var expected = try #require(copied.object); expected["type"] = .string("paragraph")
    #expect(a.document.blocks.first(where: { $0.id == peerLabel })?.fields == expected)
    #expect(try a.text(at: a.textAddress(of: child)) == "childTASK")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
}

@Test(arguments: ["a", "z"]) func schemaConversionAndOldOriginEditConvergeUnderReversedActorAndDeliveryOrder(converter: String) throws {
    let block = try Block.paragraph(id: "p", text: "A😀B")
    let a = try schemaSession([block], actor: converter), b = try schemaSession([block], actor: "m")
    try a.convertBlock(at: TextAddress("p"), offset: 1, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.replaceText(at: TextAddress("p"), range: 3..<3, with: "R", marks: [])
    let convert = a.changes(), edit = b.changes()
    try a.receive(edit); try a.receive(edit)
    try b.receive(convert); try b.receive(convert)
    #expect(a.document == b.document)
    #expect(try a.text(at: TextAddress("p", path: ["items", "p-item", "content"])) == "A😀RB")
    let c = try schemaSession([block], actor: "fresh")
    try c.receive(edit); try c.receive(convert)
    #expect(c.document == a.document)
    let d = try schemaSession([block], actor: "reverse")
    try d.receive(convert); try d.receive(edit)
    #expect(d.document == a.document)
    #expect(try WritingSession.restore(d.save(), actorID: "restore").document == a.document)
}

@Test(arguments: ["style", "items", "code"]) func schemaConversionRejectsReservedUnknownFieldCollisionsWithoutMutation(key: String) throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("keep")]), key: .object(["host": .bool(true)])])
    let session = try schemaSession([block]), before = try session.save()
    let target = WritingBlockTarget(type: key == "code" ? "code" : "list", style: "ordered")
    #expect(throws: EditorError.self) { try session.convertBlock(at: TextAddress("p"), offset: 0, to: target) }
    #expect(try session.save() == before && session.document.blocks[0] == block)
}

@Test(arguments: [false, true], [false, true]) func schemaConcurrentListConversionsKeepRecoverableUnionAndEitherAuthorCanRepair(reverseActors: Bool, repairFirst: Bool) throws {
    let block = try Block.paragraph(id: "p", text: "keep😀")
    let first = reverseActors ? "z" : "a", second = reverseActors ? "a" : "z"
    let a = try schemaSession([block], actor: first), b = try schemaSession([block], actor: second)
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    let aa = a.changes(), bb = b.changes(), beforeA = try a.save(), beforeB = try b.save()
    do { try a.receive(bb); Issue.record("Competing wrappers must require reconciliation") } catch WritingSessionError.recoveryRequired { }
    do { try b.receive(aa); Issue.record("Competing wrappers must require reconciliation") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == beforeA && b.save() == beforeB)
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    #expect(a.mergeRecovery?.batch.changes.count == 2)
    if repairFirst {
        try a.repairUndo(ChangeID(counter: 1, actor: first)); try b.receive(a.changes())
    } else {
        try b.repairUndo(ChangeID(counter: 1, actor: second)); try a.receive(b.changes())
    }
    #expect(a.document == b.document)
    #expect(a.document.blocks[0].id == "p" && a.document.blocks[0].type == "list")
    #expect(try a.text(at: TextAddress("p", path: ["items", "p-item", "content"])) == "keep😀")
    #expect(try WritingSession.restore(a.save(), actorID: first).document == a.document)
}

@Test func schemaOverlappingMovedItemConversionOriginsNeverDependOnDictionaryOrder() throws {
    let item: JSONValue = .object(["id": .string("i"), "content": .array([textNode("keep😀"), schemaReference]), "host": .string("item")])
    let left = try Block(fields: ["id": .string("left"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("list"), "style": .string("ordered"), "items": .array([])])
    let a = try schemaSession([left, right]), b = try schemaSession([left, right], actor: "b")
    let origin = try b.node(at: NodeAddress("left", path: ["items", "i"])), rightID = try b.node(at: NodeAddress("right"))
    try a.convertBlock(at: TextAddress("left", path: ["items", "i", "content"]), offset: 0, to: WritingBlockTarget(type: "paragraph"))
    try b.move(WritingSelection(nodes: [origin]), into: NodeCollection(owner: rightID, field: "items"))
    try b.convertBlock(at: TextAddress("right", path: ["items", "i", "content"]), offset: 0, to: WritingBlockTarget(type: "paragraph"))
    let aa = a.changes(), bb = b.changes(), beforeA = try a.save(), beforeB = try b.save()
    do { try a.receive(bb); Issue.record("A shared origin must not silently overwrite aliases") } catch WritingSessionError.recoveryRequired { }
    do { try b.receive(aa); Issue.record("A shared origin must not silently overwrite aliases") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == beforeA && b.save() == beforeB)
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    #expect(a.mergeRecovery?.batch.changes.count == 3)
}

@Test func schemaPeerListStyleSurvivesWrapperUndoAsMetadataAndRedoUsesPeerStyle() throws {
    let block = try Block.paragraph(id: "p", text: "keep")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    try b.convertBlock(at: TextAddress("p", path: ["items", "p-item", "content"]), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks[0].type == "paragraph" && a.document.blocks[0].fields["style"] == .string("ordered"))
    #expect(try a.text(at: TextAddress("p")) == "keep")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
    try reopened.redo()
    #expect(reopened.document.blocks[0].type == "list" && reopened.document.blocks[0].fields["style"] == .string("ordered"))
    #expect(try reopened.text(at: TextAddress("p", path: ["items", "p-item", "content"])) == "keep")
}

@Test func schemaBaselineItemMoveUndoAndRedoKeepIdentityAndSubtree() throws {
    let item: JSONValue = .object(["id": .string("peer"), "content": .array([textNode("keep😀"), schemaReference]), "host": .string("item"), "children": .array([.object(["id": .string("child"), "content": .array([textNode("child")])])])])
    let foreign = try Block(fields: ["id": .string("foreign"), "type": .string("list"), "style": .string("ordered"), "items": .array([item])])
    let block = try Block.paragraph(id: "p", text: "root")
    let a = try schemaSession([block, foreign]), b = try schemaSession([block, foreign], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    let root = try b.node(at: NodeAddress("p")), peer = try b.node(at: NodeAddress("foreign", path: ["items", "peer"]))
    try b.move(WritingSelection(nodes: [peer]), into: NodeCollection(owner: root, field: "items"))
    try a.receive(b.changes())
    let document = a.document
    try a.undo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.node(at: NodeAddress("peer")) == peer)
    var expected = try #require(item.object); expected["type"] = .string("paragraph")
    #expect(a.document.blocks.first(where: { $0.id == "peer" })?.fields == expected)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
    try reopened.redo()
    #expect(reopened.document == document)
    #expect(try reopened.node(at: NodeAddress("p", path: ["items", "peer"])) == peer)
}

@Test(arguments: [3, 4], ["level", "variant"]) func schemaInlineConversionDoesNotOverwriteUnknownReservedMetadata(version: Int, key: String) throws {
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("keep")]), key: .object(["host": .string("keep")])])
    let a = try WritingSession(documentID: "collision", actorID: "a", epoch: "collision", document: Document(blocks: [block]), protocolVersion: version)
    let before = try a.save()
    let target = key == "level" ? WritingBlockTarget(type: "heading", level: 2) : WritingBlockTarget(type: "callout", variant: "info")
    #expect(throws: EditorError.self) { try a.convertBlock(at: TextAddress("p"), offset: 0, to: target) }
    #expect(try a.save() == before && a.document.blocks[0] == block)
    let heading = try Block(fields: ["id": .string("h"), "type": .string("heading"), "level": .number(1), "content": .array([textNode("keep")])])
    let ordinary = try WritingSession(documentID: "heading", actorID: "a", epoch: "heading", document: Document(blocks: [heading]), protocolVersion: version)
    if version == 4 {
        try ordinary.convertBlock(at: TextAddress("h"), offset: 0, to: WritingBlockTarget(type: "heading", level: 2))
        #expect(ordinary.document.blocks[0].fields["level"] == .number(2))
    } else {
        let headingBefore = try ordinary.save()
        #expect(throws: EditorError.unsupportedVersion(3)) { try ordinary.convertBlock(at: TextAddress("h"), offset: 0, to: WritingBlockTarget(type: "heading", level: 2)) }
        #expect(try ordinary.save() == headingBefore)
    }
}

@Test func schemaRetiredListStyleStillRejectsMalformedWireAttribute() throws {
    let block = try Block.paragraph(id: "p", text: "keep")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    try b.convertBlock(at: TextAddress("p", path: ["items", "p-item", "content"]), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try a.receive(b.changes()); try a.undo()
    let before = try a.save(), node = try a.node(at: NodeAddress("p"))
    let forged = WritingChange(id: ChangeID(counter: 10, actor: "bad"), body: .edit([.convertBlock(node: node, type: "list", attributes: ["style": .object(["bad": .bool(true)])])]), observed: [])
    let batch = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: a.changes().changes + [forged], version: 4)
    #expect(throws: EditorError.invalidChange) { try a.receive(batch) }
    #expect(try a.save() == before && a.mergeRecovery == nil)
}

@Test(arguments: [false, true]) func schemaInactiveConversionAllowsEitherAuthorToRepairPriorSortedMetadataConflict(repairConversion: Bool) throws {
    let block = try Block.paragraph(id: "p", text: "keep")
    let a = try schemaSession([block], actor: "z")
    var b = try schemaSession([block], actor: "a")
    let node = try a.node(at: NodeAddress("p"))
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "heading", level: 2))
    let metadata = WritingChange(id: ChangeID(counter: 1, actor: "a"), body: .edit([.structure(.setNodeField(identity: node, path: ["level"], value: .string("host-level")))]), observed: [])
    // Model a retained author snapshot: receive alone does not mark a remote
    // change as local undo history, even when its actor matches the writer.
    var authored = try #require(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: [metadata], version: 4))).object)
    authored["localHistory"] = .object(["actorID": .string("a"), "undo": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([metadata.id])), "redo": .array([])])
    b = try WritingSession.restore(JSONEncoder().encode(JSONValue.object(authored)), actorID: "a")
    let aa = a.changes(), bb = b.changes(), beforeA = try a.save(), beforeB = try b.save()
    do { try a.receive(bb); Issue.record("Unknown metadata conflict must remain recoverable") } catch WritingSessionError.recoveryRequired { }
    do { try b.receive(aa); Issue.record("Unknown metadata conflict must remain recoverable") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == beforeA && b.save() == beforeB)
    if repairConversion { try a.repairUndo(ChangeID(counter: 1, actor: "z")); try b.receive(a.changes()) }
    else { try b.repairUndo(ChangeID(counter: 1, actor: "a")); try a.receive(b.changes()) }
    #expect(a.document == b.document)
    #expect(a.document.blocks[0].fields["level"] == (repairConversion ? .string("host-level") : .number(2)))
    #expect(try WritingSession.restore(a.save(), actorID: "z").document == a.document)
}

@Test func schemaOrdinaryConversionCannotBeSpoofedIntoV3BatchOrRestore() throws {
    let block = try Block.paragraph(id: "p", text: "keep")
    let a = try schemaSession([block])
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "heading", level: 2))
    let old = try WritingSession(documentID: a.documentID, actorID: "old", epoch: a.epoch, document: Document(blocks: [block]))
    let before = try old.save()
    let spoof = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: a.changes().changes, version: 3)
    #expect(throws: EditorError.invalidChange) { try old.receive(spoof) }
    #expect(try old.save() == before)
    #expect(throws: EditorError.invalidChange) { try WritingSession.restore(JSONEncoder().encode(spoof), actorID: "old") }
}

@Test(arguments: [false, true]) func schemaListTextSemanticsCannotBeSpoofedIntoV3BatchOrRestore(exit: Bool) throws {
    let items: [JSONValue] = exit
        ? [.object(["id": .string("first"), "content": .array([textNode("one")])]), .object(["id": .string("i"), "content": .array([])])]
        : [.object(["id": .string("i"), "content": .array([textNode("abcd")])])]
    let block = try Block(fields: ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array(items)])
    let a = try schemaSession([block])
    try a.enterListItem(at: TextAddress("p", path: ["items", "i", "content"]), range: exit ? 0..<0 : 2..<2, newItemID: "next")
    let old = try WritingSession(documentID: a.documentID, actorID: "old", epoch: a.epoch, document: Document(blocks: [block]))
    let before = try old.save(), spoof = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: a.changes().changes, version: 3)
    #expect(throws: EditorError.invalidChange) { try old.receive(spoof) }
    #expect(try old.save() == before)
    #expect(throws: EditorError.invalidChange) { try WritingSession.restore(JSONEncoder().encode(spoof), actorID: "old") }
}

@Test(arguments: ["list", "code"], [false, true]) func schemaConversionAndOldParagraphSplitUseRetainedOriginWithAuthorUndo(type: String, reverseActors: Bool) throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let first = reverseActors ? "z" : "a", second = reverseActors ? "a" : "z"
    let a = try schemaSession([block], actor: first), b = try schemaSession([block], actor: second)
    let origin = try a.node(at: NodeAddress("p"))
    try a.convertBlock(at: TextAddress("p"), offset: 1, to: WritingBlockTarget(type: type, style: "ordered"))
    try b.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    let aa = a.changes(), bb = b.changes()
    try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "q"])
    #expect(a.document.blocks.map(\.type) == [type, "paragraph"])
    let field = type == "list" ? TextAddress("p", path: ["items", "p-item", "content"]) : TextAddress("p", path: ["code"])
    #expect(try a.text(at: field) == "ab")
    #expect(try a.text(at: TextAddress("q")) == "cd")
    let reopened = try WritingSession.restore(a.save(), actorID: first)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document == b.document)
    #expect(reopened.document.blocks.map(\.type) == ["paragraph", "paragraph"])
    #expect(try reopened.node(at: NodeAddress("p")) == origin)
    try b.undo(); #expect(b.document.blocks == [block])
}

@Test(arguments: ["list", "code"], [false, true]) func schemaConvertedMergeSourceRetainsUnionForEitherAuthorRepair(type: String, repairConversion: Bool) throws {
    let blocks = [try Block.paragraph(id: "left", text: "ab"), try Block.paragraph(id: "right", text: "cd")]
    let a = try schemaSession(blocks), b = try schemaSession(blocks, actor: "b")
    let left = try b.node(at: NodeAddress("left")), right = try b.node(at: NodeAddress("right"))
    try a.convertBlock(at: TextAddress("right"), offset: 0, to: WritingBlockTarget(type: type, style: "ordered"))
    try b.mergeParagraphs(left: left, right: right)
    let aa = a.changes(), bb = b.changes(), beforeA = try a.save(), beforeB = try b.save()
    do { try a.receive(bb); Issue.record("Converted merge source needs reconciliation") } catch WritingSessionError.recoveryRequired { }
    do { try b.receive(aa); Issue.record("Converted merge source needs reconciliation") } catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == beforeA && b.save() == beforeB)
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    if repairConversion {
        try a.repairUndo(ChangeID(counter: 1, actor: "a")); try b.receive(a.changes())
        #expect(a.document.blocks.map(\.text) == ["abcd"])
    } else {
        try b.repairUndo(ChangeID(counter: 1, actor: "b")); try a.receive(b.changes())
        #expect(a.document.blocks.map(\.type) == ["paragraph", type])
        let field = type == "list" ? TextAddress("right", path: ["items", "right-item", "content"]) : TextAddress("right", path: ["code"])
        #expect(try a.text(at: field) == "cd")
    }
    #expect(a.document == b.document)
    #expect(try WritingSession.restore(a.save(), actorID: "a").document == a.document)
}

@Test(arguments: ["list", "code"]) func schemaConvertedMergeDestinationPreservesTypeIdentityAndBothAuthorUndo(type: String) throws {
    let blocks = [try Block.paragraph(id: "left", text: "ab"), try Block.paragraph(id: "right", text: "cd")]
    let a = try schemaSession(blocks), b = try schemaSession(blocks, actor: "b")
    let left = try b.node(at: NodeAddress("left")), right = try b.node(at: NodeAddress("right"))
    try a.convertBlock(at: TextAddress("left"), offset: 0, to: WritingBlockTarget(type: type, style: "ordered"))
    try b.mergeParagraphs(left: left, right: right)
    let aa = a.changes(), bb = b.changes(); try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document && a.document.blocks.count == 1)
    #expect(a.document.blocks[0].type == type)
    #expect(try a.node(at: NodeAddress("left")) == left)
    let field = type == "list" ? TextAddress("left", path: ["items", "left-item", "content"]) : TextAddress("left", path: ["code"])
    #expect(try a.text(at: field) == "abcd")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); try b.receive(reopened.changes()); try b.undo()
    #expect(b.document.blocks == blocks)
}

@Test(arguments: [false, true]) func schemaProjectedPeerParagraphSupportsEnterMoveUndoAndReopen(baseline: Bool) throws {
    let original = try Block.paragraph(id: "p", text: baseline ? "root" : "abcd")
    let foreignItem: JSONValue = .object(["id": .string("peer"), "content": .array([textNode("cd")]), "host": .string("keep")])
    let foreign = try Block(fields: ["id": .string("foreign"), "type": .string("list"), "style": .string("ordered"), "items": .array([foreignItem])])
    let blocks = baseline ? [original, foreign] : [original]
    let a = try schemaSession(blocks), b = try schemaSession(blocks, actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    let peer: NodeID
    if baseline {
        peer = try b.node(at: NodeAddress("foreign", path: ["items", "peer"]))
        try b.move(WritingSelection(nodes: [peer]), into: NodeCollection(owner: b.node(at: NodeAddress("p")), field: "items"))
    } else {
        try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
        peer = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    }
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    #expect(try b.node(at: NodeAddress("peer")) == peer)
    let before = b.document
    let caret = try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    #expect(try b.text(at: TextAddress("peer")) == "c")
    #expect(try b.text(at: TextAddress("tail")) == "d")
    #expect(try b.resolve(caret).offset == 0)
    try a.receive(b.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(b.save(), actorID: "b")
    #expect(reopened.document == b.document)
    let root = try reopened.node(at: NodeAddress("p"))
    try reopened.move(WritingSelection(nodes: [peer]), into: .root, after: root)
    try a.receive(reopened.changes()); #expect(a.document == reopened.document)
    #expect(try reopened.node(at: NodeAddress("peer")) == peer)
    try reopened.undo(); try reopened.undo()
    #expect(reopened.document == before)
    try reopened.redo(); #expect(try reopened.text(at: TextAddress("tail")) == "d")
}

@Test func schemaRetainedRoleAnchorsKeepMultiplePeerParagraphOrderAndWrapperRedo() throws {
    let block = try Block.paragraph(id: "p", text: "abcdef")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer1")
    try b.enterListItem(at: TextAddress("p", path: ["items", "peer1", "content"]), range: 2..<2, newItemID: "peer2")
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    #expect(b.document.blocks.map(\.id) == ["p", "peer1", "peer2"])
    try b.splitParagraph(at: TextAddress("peer2"), range: 1..<1, newBlockID: "tail")
    #expect(b.document.blocks.map(\.id) == ["p", "peer1", "peer2", "tail"])
    #expect(b.document.blocks.map(\.text) == ["ab", "cd", "e", "f"])
    try a.receive(b.changes()); try a.redo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "peer1", "peer2", "tail"])
    #expect(a.document.blocks[0].type == "list")
    #expect(try a.text(at: TextAddress("p", path: ["items", "p-item", "content"])) == "ab")
    let reopened = try WritingSession.restore(b.save(), actorID: "b")
    try reopened.undo()
    #expect(reopened.document.blocks.count == 1)
    #expect(reopened.document.blocks[0].fields["items"]?.array?.map { $0["id"]?.string } == ["p-item", "peer1", "peer2"])
    #expect(try reopened.text(at: TextAddress("p", path: ["items", "peer2", "content"])) == "ef")
}

@Test(arguments: ["retirement", "owner", "anchor"]) func schemaMalformedRetainedRoleDoesNotChangeAcceptedSaveOrReachV3(fault: String) throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    let latest = try #require(b.changes().changes.last)
    guard case .edit(let operations) = latest.body,
          case .retainParagraphRole(let role) = try #require(operations.first) else { Issue.record("Missing retained role"); return }
    let forgedRole = WritingParagraphRole(node: role.node,
        owner: fault == "owner" ? .baseline(blockID: "missing", path: []) : role.owner,
        retirement: fault == "retirement" ? ChangeID(counter: 0, actor: "missing") : role.retirement,
        exposure: role.exposure,
        after: fault == "anchor" ? .role(owner: role.owner, node: role.node) : role.after)
    let forged = WritingChange(id: ChangeID(counter: 99, actor: "bad"), body: .edit([.retainParagraphRole(forgedRole)]), observed: b.changes().changes.map(\.id).reduce(into: [String: ChangeID]()) { $0[$1.actor] = $1 }.values.sorted())
    let batch = WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: b.changes().changes + [forged], version: 4)
    let before = try b.save()
    #expect(throws: EditorError.invalidChange) { try b.receive(batch) }
    #expect(try b.save() == before)
    let old = try WritingSession(documentID: b.documentID, actorID: "old", epoch: b.epoch, document: Document(blocks: [block]))
    let spoof = WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: b.changes().changes, version: 3)
    #expect(throws: EditorError.invalidChange) { try old.receive(spoof) }
}

private func schemaRetiredPeer(text: String = "abcd") throws -> (WritingSession, WritingSession, NodeID) {
    let block = try Block.paragraph(id: "p", text: text)
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    let peer = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    return (a, b, peer)
}

@Test(arguments: ["heading", "code", "list", "shortcut", "mergeLeft", "mergeRight"])
func schemaRetainedPeerSupportsConversionShortcutAndMerge(command: String) throws {
    let (a, b, peer) = try schemaRetiredPeer(text: command == "shortcut" ? "ab# cd" : "abcd")
    let before = b.document
    if command == "shortcut" {
        try b.markdownShortcut(at: TextAddress("peer"), offset: 2)
        #expect(b.document.blocks[1].type == "heading")
    } else if command == "mergeLeft" || command == "mergeRight" {
        let root = try b.node(at: NodeAddress("p"))
        if command == "mergeLeft" {
            try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
            let tail = try b.node(at: NodeAddress("tail"))
            try b.mergeParagraphs(left: peer, right: tail)
            try b.undo(); try b.undo()
            #expect(b.document == before)
            try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail2")
            try b.mergeParagraphs(left: peer, right: b.node(at: NodeAddress("tail2")))
        } else { try b.mergeParagraphs(left: command == "mergeLeft" ? peer : root, right: command == "mergeLeft" ? root : peer) }
        #expect(command == "mergeLeft" ? b.document.blocks.count == 2 : b.document.blocks.count == 1)
    } else {
        try b.convertBlock(at: TextAddress("peer"), offset: 1, to: WritingBlockTarget(type: command, level: command == "heading" ? 2 : nil, style: command == "list" ? "todo" : nil))
        #expect(try b.node(at: NodeAddress("peer")) == peer)
        try b.move(WritingSelection(nodes: [peer]), into: .root, after: b.node(at: NodeAddress("p")))
        #expect(b.document.blocks[1].type == command)
        try b.undo()
    }
    try a.receive(b.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(b.save(), actorID: "b")
    #expect(reopened.document == b.document)
    try reopened.undo()
    if command == "mergeLeft" { try reopened.undo() }
    #expect(reopened.document == before)
    try reopened.redo()
    if command == "mergeLeft" { try reopened.redo() }
    #expect(reopened.document == b.document)
}

@Test(arguments: ["a", "z"]) func schemaConcurrentUnobservedPeerAndRetirementCanRetainRole(undoActor: String) throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try schemaSession([block], actor: undoActor), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    try a.undo(); let retired = a.changes(); try a.receive(b.changes()); try b.receive(retired)
    #expect(a.document == b.document && b.document.blocks.map(\.id) == ["p", "peer"])
    try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    try a.receive(b.changes()); #expect(a.document == b.document)
    #expect(try WritingSession.restore(b.save(), actorID: "b").document == b.document)
}

@Test func schemaRetirementBeforePeerBirthCannotForgeExposure() throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try schemaSession([block]), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try a.undo(); let retirementID = try #require(a.changes().changes.last?.id)
    try a.redo(); try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    let node = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    let owner = try b.node(at: NodeAddress("p")), exposure = try #require(b.changes().changes.last?.id)
    let role = WritingParagraphRole(node: node, owner: owner, retirement: retirementID, exposure: [exposure], after: .initial(owner))
    let forged = WritingChange(id: ChangeID(counter: 9, actor: "bad"), body: .edit([.retainParagraphRole(role)]), observed: b.changes().changes.map(\.id).reduce(into: [String: ChangeID]()) { $0[$1.actor] = $1 }.values.sorted())
    let before = try b.save()
    #expect(throws: EditorError.invalidChange) { try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: b.changes().changes + [forged], version: 4)) }
    #expect(try b.save() == before && b.mergeRecovery == nil)
}

@Test func schemaRoleDeltaBeforeDependenciesRetainsRecoveryAndReopens() throws {
    let (_, b, _) = try schemaRetiredPeer()
    let previous = b.syncState
    try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    let fresh = try schemaSession([Block.paragraph(id: "p", text: "abcd")], actor: "fresh")
    let before = try fresh.save()
    do { try fresh.receive(b.changes(since: previous)); Issue.record("Expected missing predecessor") }
    catch { #expect(fresh.mergeRecovery?.reason == .schemaConstraint) }
    #expect(try fresh.save() == before)
    let recovery = try #require(try fresh.exportRecovery())
    let reopened = try WritingSession.restore(before, actorID: "fresh")
    do { try reopened.restoreRecovery(recovery); Issue.record("Expected missing predecessor") } catch { #expect(reopened.mergeRecovery?.reason == .schemaConstraint) }
    try fresh.receive(b.changes()); try reopened.receive(b.changes())
    #expect(fresh.document == b.document && reopened.document == b.document)
    #expect(fresh.mergeRecovery == nil && reopened.mergeRecovery == nil)
}

@Test(arguments: ["negative", "zero", "future", "actor", "firstItem"])
func schemaMalformedRoleAnchorAndHiddenFirstItemRejectAtomically(fault: String) throws {
    let (_, b, peer) = try schemaRetiredPeer()
    let owner = try b.node(at: NodeAddress("p"))
    let changes = b.changes().changes
    let retirementID = try #require(changes.last?.id)
    guard case .edit(let original) = changes[0].body, case .schemaConvert(let conversion) = original[0] else { Issue.record("Missing conversion"); return }
    let badChange = ChangeID(counter: fault == "zero" ? 0 : fault == "future" ? 99 : 1, actor: fault == "actor" ? "" : "a")
    let anchor: NodePlacementID = fault == "firstItem" ? .initial(owner) : .edit(ElementID(change: badChange, index: fault == "negative" ? -1 : 0))
    let role = WritingParagraphRole(node: fault == "firstItem" ? conversion.destination.node : peer, owner: owner,
        retirement: retirementID, exposure: [retirementID], after: anchor)
    let forged = WritingChange(id: ChangeID(counter: 9, actor: "bad"), body: .edit([.retainParagraphRole(role)]), observed: b.changes().changes.map(\.id).reduce(into: [String: ChangeID]()) { $0[$1.actor] = $1 }.values.sorted())
    let before = try b.save()
    #expect(throws: EditorError.invalidChange) { try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: changes + [forged], version: 4)) }
    #expect(try b.save() == before && b.mergeRecovery == nil)
}

@Test func schemaInactiveRoleRestoresExactItemAndSupportsLaterListCommands() throws {
    let (a, b, _) = try schemaRetiredPeer()
    try a.redo(); try b.receive(a.changes())
    let originalList = b.document
    try a.undo(); try b.receive(a.changes())
    try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    try a.receive(b.changes()); try a.redo(); try b.receive(a.changes())
    try b.undo()
    #expect(b.document == originalList)
    let peer = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    let first = try b.node(at: NodeAddress("p", path: ["items", "p-item"]))
    try b.move(WritingSelection(nodes: [peer]), into: NodeCollection(owner: b.node(at: NodeAddress("p")), field: "items"), after: first)
    #expect(b.document == originalList)
    try b.enterListItem(at: TextAddress("p", path: ["items", "peer", "content"]), range: 1..<1, newItemID: "next")
    #expect(try b.text(at: TextAddress("p", path: ["items", "next", "content"])) == "d")
    #expect(try WritingSession.restore(b.save(), actorID: "b").document == b.document)
}

@Test(arguments: ["a", "z"]) func schemaRoleCohortExcludesUnobservedConcurrentRedo(redoActor: String) throws {
    let block = try Block.paragraph(id: "p", text: "abcd")
    let a = try schemaSession([block], actor: redoActor), b = try schemaSession([block], actor: "b")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "X")
    try a.redo()
    try b.splitParagraph(at: TextAddress("peer"), range: 1..<1, newBlockID: "tail")
    let aa = a.changes(), bb = b.changes()
    try a.receive(bb); try b.receive(aa)
    #expect(a.document == b.document && a.document.blocks.map(\.id) == ["p", "peer", "tail"])
    #expect(a.document.blocks[0].type == "list")
    #expect(try a.text(at: TextAddress("p", path: ["items", "p-item", "content"])) == "Xab")
    #expect(try a.text(at: TextAddress("peer")) == "c" && a.text(at: TextAddress("tail")) == "d")
    #expect(try WritingSession.restore(a.save(), actorID: redoActor).document == a.document)
    try b.undo(); #expect(b.document.blocks.count == 1)
}

@Test(arguments: ["absent", "duplicateActor", "unsorted", "future", "zero"])
func schemaMalformedV4ObservedFrontierLeavesAcceptedSaveUnchanged(fault: String) throws {
    let (_, b, _) = try schemaRetiredPeer()
    let latest = try #require(b.changes().changes.last)
    let a = latest.id, earlier = ChangeID(counter: 2, actor: "b")
    let observed: [ChangeID]?
    switch fault {
    case "absent": observed = nil
    case "duplicateActor": observed = [ChangeID(counter: 1, actor: a.actor), a]
    case "unsorted": observed = [a, earlier]
    case "future": observed = [ChangeID(counter: 99, actor: "future")]
    default: observed = [ChangeID(counter: 0, actor: "zero")]
    }
    let forged = WritingChange(id: ChangeID(counter: 9, actor: "bad"), body: .edit([.convertBlock(node: try b.node(at: NodeAddress("p")), type: "heading", attributes: ["level": .number(2)])]), observed: observed)
    let before = try b.save()
    #expect(throws: EditorError.invalidChange) { try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: b.changes().changes + [forged], version: 4)) }
    #expect(try b.save() == before && b.mergeRecovery == nil)
}
