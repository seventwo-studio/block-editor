import BlockEditorCore
import Foundation
import Testing

private enum RecoveryCollection: String, CaseIterable {
    case root, toggleChildren, listItems, tableRows, tableCells
}
private func recoveryValue(_ kind: RecoveryCollection, author: String, seed: Int) -> JSONValue {
    let content: [JSONValue] = [textNode("\(author) café 👩🏽‍💻 \(seed)", marks: [.object(["type": .string("italic")])]),
        .object(["type": .string("entity-ref"), "entityId": .string("\(author)-\(seed)"), "entityType": .string("note"), "label": .string("Ref")])]
    var value: [String: JSONValue] = ["id": .string("same"), "host": .object(["id": .string("opaque"), "keep": .bool(true)])]
    switch kind {
    case .root, .toggleChildren: value["type"] = .string("paragraph"); value["content"] = .array(content)
    case .listItems: value["content"] = .array(content); value["checked"] = .bool(true); value["children"] = .array([])
    case .tableRows: value["cells"] = .array([.object(["id": .string("cell"), "content": .array(content), "header": .bool(true)])])
    case .tableCells: value["content"] = .array(content); value["header"] = .bool(true)
    }
    return .object(value)
}
private func recoveryContainer(_ kind: RecoveryCollection, id: String, members: [JSONValue] = []) throws -> Block {
    var value: [String: JSONValue] = ["id": .string(id), "extension": .object(["remote": .number(0)])]
    switch kind {
    case .root, .toggleChildren: value["type"] = .string("toggle"); value["summary"] = .array([textNode(id)]); value["children"] = .array(members)
    case .listItems: value["type"] = .string("list"); value["style"] = .string("todo"); value["items"] = .array(members)
    case .tableRows: value["type"] = .string("table"); value["rows"] = .array(members)
    case .tableCells: value["type"] = .string("table"); value["rows"] = .array([.object(["id": .string("row"), "cells": .array(members)])])
    }
    return try Block(fields: value)
}
private func recoveryCollection(_ kind: RecoveryCollection, container: String?) -> NodeCollection {
    guard let container else { return .root }
    let field: String
    switch kind { case .root, .toggleChildren: field = "children"; case .listItems: field = "items"; case .tableRows: field = "rows"; case .tableCells: field = "cells" }
    return NodeCollection(owner: .baseline(blockID: container, path: kind == .tableCells ? ["rows", "row"] : []), field: field)
}
private func expectPending(_ session: EditorSession, _ batch: ChangeBatch) throws -> MergeRecovery {
    do { try session.receive(batch); Issue.record("Invalid union accepted") }
    catch EditorError.mergeRecoveryRequired(let proposal) { return proposal }
    return try #require(session.mergeRecovery)
}

@Test(arguments: [1, 7, 42, 255], RecoveryCollection.allCases)
private func generatedRecoveryCollisionsRetainAllCollectionKinds(seed: Int, kind: RecoveryCollection) throws {
    let baseline = try Document(blocks: [recoveryContainer(kind, id: "source"), recoveryContainer(kind, id: "left"), recoveryContainer(kind, id: "right")])
    let source = recoveryCollection(kind, container: kind == .root ? nil : "source")
    let left = recoveryCollection(kind, container: "left"), right = recoveryCollection(kind, container: "right")
    let a = try EditorSession(documentID: "generated-recovery", actorID: "a", document: baseline, collaborationVersion: 2)
    let b = try EditorSession(documentID: "generated-recovery", actorID: "b", document: baseline, collaborationVersion: 2)
    let values = [recoveryValue(kind, author: "a", seed: seed), recoveryValue(kind, author: "b", seed: seed)]
    let first = try a.insertNode(values[0], into: source), second = try b.insertNode(values[1], into: source)
    let saveA = try a.save(), saveB = try b.save(), receiptsA = a.syncState, receiptsB = b.syncState
    let proposal = try expectPending(a, b.changes())
    #expect(try expectPending(b, a.changes()) == proposal)
    #expect(try expectPending(a, b.changes()) == proposal)
    #expect(try a.save() == saveA); #expect(try b.save() == saveB)
    #expect(a.syncState == receiptsA); #expect(b.syncState == receiptsB)
    // A third author writes while these two are recovering. Its complete history
    // must remain unapplied until the full rejected union can be admitted.
    let c = try EditorSession(documentID: "generated-recovery", actorID: "c", document: baseline, collaborationVersion: 2)
    let metadata = NodeID.baseline(blockID: "source", path: [])
    try c.setNodeField(metadata, path: ["extension", "remote"], value: .number(Double(seed)))
    let extra = c.changes()
    _ = try expectPending(a, extra); _ = try expectPending(b, extra)
    #expect(a.mergeRecovery == b.mergeRecovery)
    let retained = try JSONEncoder().encode(try #require(a.mergeRecovery))
    let restored = try EditorSession.restore(saveA, actorID: "a")
    _ = try expectPending(restored, JSONDecoder().decode(MergeRecovery.self, from: retained).batch)
    let pendingBeforeRepair = restored.mergeRecovery
    #expect(throws: EditorError.self) { try restored.repairMerge([.move(identity: second, collection: source)]) }
    #expect(restored.mergeRecovery == pendingBeforeRepair); #expect(try restored.save() == saveA)
    #expect(restored.syncState == receiptsA)
    try restored.repairMerge([.move(identity: second, collection: left)])
    try b.repairMerge([.move(identity: second, collection: right)])
    let repairs = [restored.changes(), b.changes()]
    // Fixed seed selects duplicate delivery order; repair actor B wins the same
    // placement regardless of which transport batch arrives first.
    for batch in seed % 2 == 0 ? repairs : repairs.reversed() {
        try restored.receive(batch); try b.receive(batch); try restored.receive(batch)
    }
    var expected = baseline.blocks
    expected[0].fields["extension"] = .object(["remote": .number(Double(seed))])
    if kind == .root { expected.insert(try Block(fields: values[0].object!), at: 0) }
    else { expected[0] = try recoveryContainer(kind, id: "source", members: [values[0]]); expected[0].fields["extension"] = .object(["remote": .number(Double(seed))]) }
    expected[expected.count - 1] = try recoveryContainer(kind, id: "right", members: [values[1]])
    let oracle = try Document(blocks: expected)
    #expect(try restored.document == oracle); #expect(try b.document == oracle)
    #expect(try restored.address(of: first) == (kind == .root ? NodeAddress("same") : NodeAddress("source", path: kind == .tableCells ? ["rows", "row", "cells", "same"] : [source.field, "same"])))
    try restored.undo(); try b.receive(restored.changes()); try b.receive(restored.changes())
    #expect(try restored.document == oracle); #expect(try b.document == oracle)
    let reopened = try EditorSession.restore(restored.save(), actorID: "a")
    #expect(try reopened.document == oracle); #expect(reopened.mergeRecovery == nil)
    #expect(reopened.syncState.received == Set(reopened.changes().changes.map(\.id)))
    // Reactivate the losing repair before undoing the winner. The earlier valid
    // placement becomes effective, preserving both authors' complete payloads.
    try reopened.redo(); try b.receive(reopened.changes())
    #expect(try b.document == oracle)
    try b.undo()
    var earlier = expected
    earlier[earlier.count - 2] = try recoveryContainer(kind, id: "left", members: [values[1]])
    earlier[earlier.count - 1] = try recoveryContainer(kind, id: "right")
    let earlierOracle = try Document(blocks: earlier)
    #expect(try b.document == earlierOracle)
    try reopened.receive(b.changes()); try reopened.receive(b.changes())
    #expect(try reopened.document == earlierOracle)
    try b.redo(); try reopened.receive(b.changes())
    #expect(try b.document == oracle); #expect(try reopened.document == oracle)
}
