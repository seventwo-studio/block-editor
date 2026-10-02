import Foundation
import Testing
@testable import BlockEditorCore

private func reviewSpliceSeed() throws -> Document {
    try Document(blocks: [Block.paragraph(id: "p", text: "AB")])
}
private func reviewSpliceSession(_ baseline: Document) throws -> WritingSession {
    try WritingSession(documentID: "review-splice", actorID: "a", epoch: "five", document: baseline, protocolVersion: 5)
}
private func reviewSpliceChange(_ builder: WritingSession, cut: Int, prefix: String) throws -> WritingChange {
    let root = try builder.node(at: NodeAddress("p"))
    _ = try builder.splitParagraph(at: TextAddress("p"), range: cut..<cut, newBlockID: prefix + "-tail")
    let split = try #require(builder.changes().changes.last)
    guard case .edit(var operations) = split.body else { throw EditorError.invalidChange }
    let tailCreation = ElementID(change: split.id, index: 0), middleCreation = ElementID(change: split.id, index: 1)
    let tail = NodeID.inserted(creation: tailCreation, path: []), middle = NodeID.inserted(creation: middleCreation, path: [])
    let descriptor = try #require(operations.compactMap { operation -> (WritingField, WritingEdge, NodeID?)? in
        if case .text(.splitBoundary(let source, _, let edge, let before)) = operation { return (source, edge, before) }; return nil
    }.first)
    operations = operations.compactMap { operation in
        switch operation { case .structure(.insertNode), .text(.splitBoundary): return nil; default: return operation }
    }
    let imported: JSONValue = .object(["id": .string(prefix + "-middle"), "type": .string("paragraph"),
        "content": .array([textNode("X")]), "opaque": .object(["owner": .string(prefix)])])
    let tailValue: JSONValue = .object(["id": .string(prefix + "-tail"), "type": .string("paragraph"), "content": .array([])])
    operations.insert(contentsOf: [
        .structure(.insertNode(value: imported, identity: middle, collection: .root, placement: middleCreation, after: .initial(root))),
        .structure(.insertNode(value: tailValue, identity: tail, collection: .root, placement: tailCreation, after: .edit(middleCreation)))], at: 0)
    operations.append(.text(.spliceBoundary(source: descriptor.0, destination: WritingField(node: tail, name: "content"),
        edge: descriptor.1, before: descriptor.2, members: [middle, tail])))
    return WritingChange(id: split.id, body: .edit(operations), observed: split.observed)
}
private func reviewSpliceRestore(_ changes: [WritingChange], baseline: Document) throws -> WritingSession {
    let batch = WritingBatch(documentID: "review-splice", epoch: "five", baseline: baseline, changes: changes, version: 5)
    return try WritingSession.restore(canonicalEncoder().encode(batch), actorID: "a")
}

@Test(arguments: [false, true])
func spliceDuplicateDescriptorMustRemainMalformedWhenAuthorUndone(inactive: Bool) throws {
    let baseline = try reviewSpliceSeed(), builder = try reviewSpliceSession(baseline)
    let valid = try reviewSpliceChange(builder, cut: 1, prefix: "first")
    guard case .edit(var operations) = valid.body else { throw EditorError.invalidChange }
    let descriptor = try #require(operations.last)
    operations.append(descriptor)
    let malformed = WritingChange(id: valid.id, body: .edit(operations), observed: valid.observed)
    var changes = [malformed]
    if inactive {
        changes.append(WritingChange(id: ChangeID(counter: 2, actor: "a"), body: .setActive(target: valid.id, active: false), observed: [valid.id]))
    }
    let receiver = try reviewSpliceSession(baseline), accepted = try receiver.save(), receipt = receiver.syncState
    #expect(throws: EditorError.invalidChange) {
        try receiver.receive(WritingBatch(documentID: "review-splice", epoch: "five", baseline: baseline, changes: changes, version: 5))
    }
    #expect(try receiver.save() == accepted)
    #expect(receiver.syncState == receipt && receiver.mergeRecovery == nil)
}

@Test
func sequentialSpliceBeforeFirstImportedMemberMustPrecedeWholeEarlierGroup() throws {
    let baseline = try reviewSpliceSeed(), firstBuilder = try reviewSpliceSession(baseline)
    let first = try reviewSpliceChange(firstBuilder, cut: 1, prefix: "first")
    let secondBuilder = try reviewSpliceRestore([first], baseline: baseline)
    let second = try reviewSpliceChange(secondBuilder, cut: 1, prefix: "second")
    let result = try reviewSpliceRestore([first, second], baseline: baseline)
    #expect(result.document.blocks.map(\.id) == ["p", "second-middle", "second-tail", "first-middle", "first-tail"])
    #expect(result.document.blocks.map(\.text) == ["A", "X", "", "X", "B"])
    #expect(result.document.blocks.first { $0.id == "first-middle" }?.fields["opaque"] == .object(["owner": .string("first")]))
    let reversed = try reviewSpliceRestore([second, first], baseline: baseline)
    #expect(reversed.document == result.document)
}

@Test
func ordinarySplitBeforeFirstImportedMemberMustPrecedeWholeExistingGroup() throws {
    let baseline = try reviewSpliceSeed(), builder = try reviewSpliceSession(baseline)
    let first = try reviewSpliceChange(builder, cut: 1, prefix: "first")
    let result = try reviewSpliceRestore([first], baseline: baseline)
    _ = try result.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "ordinary-tail")
    #expect(result.document.blocks.map(\.id) == ["p", "ordinary-tail", "first-middle", "first-tail"])
    #expect(result.document.blocks.map(\.text) == ["A", "", "X", "B"])
    let reopened = try WritingSession.restore(result.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks.map(\.id) == ["p", "first-middle", "first-tail"])
    try reopened.redo(); #expect(reopened.document == result.document)
}
