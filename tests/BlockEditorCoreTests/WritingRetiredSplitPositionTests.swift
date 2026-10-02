import BlockEditorCore
import Testing

@Test(arguments: [false, true], ["a", "z"]) func v4EmptySplitHeadPositionFollowsRetainedBoundaryAcrossPeerEditsUndoReopenAndRedo(list: Bool, actor: String) throws {
    let block = try Block(fields: list ? ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("i"), "content": .array([textNode("A😀")]), "checked": .bool(true)])])] : ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A😀")])])
    let document = try Document(blocks: [block]), address = list ? TextAddress("p", path: ["items", "i", "content"]) : TextAddress("p")
    let a = try WritingSession(documentID: "retired-head", actorID: actor, epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "retired-head", actorID: "m", epoch: "v4", document: document, protocolVersion: 4)
    let head = try list ? a.enterListItem(at: address, range: 3..<3, newItemID: "tail") : a.splitParagraph(at: address, range: 3..<3, newBlockID: "tail")
    #expect(head.anchor == nil && head.affinity == .after)
    try b.receive(a.changes()); try b.replaceText(at: address, range: 0..<0, with: "L"); try b.replaceText(at: address, range: 4..<4, with: "R")
    try a.receive(b.changes()); try a.receive(b.changes()); try a.undo()
    let accepted = try a.save(), resolved = try a.resolve(head)
    #expect(try resolved.address.identity == a.node(at: NodeAddress("p", path: list ? ["items", "i"] : [])) && resolved.offset == 4)
    #expect(try a.text(at: address) == "LA😀R" && a.save() == accepted)
    let reopened = try WritingSession.restore(accepted, actorID: actor)
    #expect(try reopened.resolve(head).address == resolved.address && reopened.resolve(head).offset == resolved.offset)
    try reopened.redo(); let restored = try reopened.resolve(head)
    #expect(restored.address.identity == head.field.node && restored.offset == 0)
    try reopened.undo(); #expect(try reopened.resolve(head).address == resolved.address && reopened.resolve(head).offset == resolved.offset)
    try b.receive(reopened.changes()); #expect(b.document == reopened.document)
}

@Test func v4EmptySplitHeadPositionFollowsNestedRetiredBirthsWithoutChangingEndSentinels() throws {
    let a = try WritingSession(documentID: "retired-chain", actorID: "a", epoch: "v4", document: Document(blocks: [.paragraph(id: "p", text: "A")]), protocolVersion: 4)
    let first = try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "first")
    let second = try a.splitParagraph(at: TextAddress("first"), range: 0..<0, newBlockID: "second")
    try a.undo(); #expect(try a.resolve(second).address.identity == first.field.node && a.resolve(second).offset == 0)
    try a.undo(); #expect(try a.resolve(second).address.identity == a.node(at: NodeAddress("p")) && a.resolve(second).offset == 1)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(try reopened.resolve(second).address == a.resolve(second).address && reopened.resolve(second).offset == a.resolve(second).offset)
    let end = WritingPosition(documentID: a.documentID, epoch: a.epoch, field: second.field, affinity: .before)
    #expect(throws: (any Error).self) { try a.resolve(end) }
    try reopened.redo(); #expect(try reopened.resolve(second).address.identity == first.field.node)
    try reopened.redo(); #expect(try reopened.resolve(second).address.identity == second.field.node)
}

@Test func retiredSplitHeadPositionPreservesV3AndRejectsUnrelatedDeletion() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "A"), .paragraph(id: "empty", text: "")])
    let legacy = try WritingSession(documentID: "retired-legacy", actorID: "a", epoch: "v3", document: document, protocolVersion: 3)
    let head = try legacy.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "tail")
    try legacy.undo(); #expect(throws: (any Error).self) { try legacy.resolve(head) }
    let a = try WritingSession(documentID: "retired-unrelated", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    let baseline = try a.position(at: TextAddress("empty"), offset: 0)
    try a.delete(WritingSelection(nodes: [a.node(at: NodeAddress("empty"))]))
    #expect(throws: (any Error).self) { try a.resolve(baseline) }
    let split = try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "tail")
    try a.delete(WritingSelection(nodes: [split.field.node]))
    #expect(throws: (any Error).self) { try a.resolve(split) }
    let accepted = try a.save(); #expect(try WritingSession.restore(accepted, actorID: "a").save() == accepted)
}

@Test func v4RetiredSplitHeadTraversesLongValidatedBirthChainWithoutRecursion() throws {
    // Deliver one real retained-history batch rather than replaying thousands
    // of incremental fixtures; every split/toggle still passes wire validation.
    let depth = 256, document = try Document(blocks: [.paragraph(id: "p", text: "")])
    let a = try WritingSession(documentID: "retired-deep", actorID: "local", epoch: "v4", document: document, protocolVersion: 4)
    var changes: [WritingChange] = [], previous: ChangeID?, source = WritingField(node: .baseline(blockID: "p", path: []), name: "content")
    var predecessor = NodePlacementID.initial(source.node)
    for index in 1...depth {
        let id = ChangeID(counter: UInt64(index), actor: "peer"), creation = ElementID(change: id, index: 0)
        let node = NodeID.inserted(creation: creation, path: []), destination = WritingField(node: node, name: "content")
        let value: JSONValue = .object(["id": .string("tail-\(index)"), "type": .string("paragraph"), "content": .array([])])
        changes.append(WritingChange(id: id, body: .edit([.structure(.insertNode(value: value, identity: node, collection: .root, placement: creation, after: predecessor)), .text(.splitBoundary(source: source, destination: destination, edge: .start, before: nil))]), observed: previous.map { [$0] } ?? []))
        previous = id; source = destination; predecessor = .edit(creation)
    }
    for index in 1...depth {
        let id = ChangeID(counter: UInt64(depth + index), actor: "peer")
        changes.append(WritingChange(id: id, body: .setActive(target: ChangeID(counter: UInt64(index), actor: "peer"), active: false), observed: previous.map { [$0] } ?? []))
        previous = id
    }
    try a.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: document, changes: changes, version: 4))
    let position = WritingPosition(documentID: a.documentID, epoch: a.epoch, field: source, affinity: .after)
    let accepted = try a.save(), resolved = try a.resolve(position)
    #expect(try resolved.address.identity == a.node(at: NodeAddress("p")) && resolved.offset == 0)
    #expect(try a.save() == accepted && a.document == document)
}
