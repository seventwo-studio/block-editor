import BlockEditorCore
import Foundation
import Testing

private func thresholdBaseline(_ length: Int) throws -> Document {
    let math = try Block(fields: ["id": .string("math"), "type": .string("math"),
        "expression": .string(String(repeating: "x", count: length)),
        "consumer": .object(["id": .string("math-opaque"), "children": .array([.object(["id": .string("opaque-child")])])])])
    let rich = try Block(fields: ["id": .string("rich"), "type": .string("paragraph"), "host": .string("retained"),
        "content": .array([
            .object(["type": .string("text"), "text": .string("café 東京😀"), "marks": .array([.object(["type": .string("bold")])])]),
            .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("outside"), "label": .string("Task"),
                "consumer": .object(["id": .string("reference-opaque")])])])])
    return try Document(blocks: [math, rich])
}
private func thresholdSession(_ baseline: Document, version: Int, actor: String) throws -> WritingSession {
    try WritingSession(documentID: "threshold-\(version)", actorID: actor, epoch: "math-limit-\(version)", document: baseline, protocolVersion: version)
}
private func thresholdPending(_ receiver: WritingSession, batch: WritingBatch) throws -> WritingRecovery {
    do { try receiver.receive(batch); Issue.record("Over-limit union was admitted") }
    catch WritingSessionError.recoveryRequired(let proposal) { return proposal }
    return try #require(receiver.mergeRecovery)
}
private func thresholdExpression(_ baseline: Document, length: Int, suffix: String) throws -> Document {
    var blocks = baseline.blocks
    blocks[0].fields["expression"] = .string(String(repeating: "x", count: length) + suffix)
    return try Document(blocks: blocks)
}

// Each offline edit is valid. This uses the production 10,000 UTF-16-unit math
// constraint; no test-only limit or generated engine output forms the oracle.
@Test(arguments: [4, 5], ["a", "z"])
func writingMathThresholdUnionAt10000PreservesBothAuthorsAndUndo(version: Int, actor: String) throws {
    let baseline = try thresholdBaseline(9_998)
    let a = try thresholdSession(baseline, version: version, actor: actor)
    let b = try thresholdSession(baseline, version: version, actor: "m")
    let address = TextAddress("math", path: ["expression"])
    let positionA = try a.replaceText(at: address, range: 9_998..<9_998, with: "A")
    let positionB = try b.replaceText(at: address, range: 9_998..<9_998, with: "B")
    #expect(a.document == (try thresholdExpression(baseline, length: 9_998, suffix: "A")))
    #expect(b.document == (try thresholdExpression(baseline, length: 9_998, suffix: "B")))
    let batchA = a.changes(), batchB = b.changes()
    try a.receive(batchB); try b.receive(batchA)
    try b.receive(batchA); try a.receive(batchB)
    // Immutable same-edge birth order traverses the later actor first.
    let suffix = actor == "z" ? "AB" : "BA"
    let expected = try thresholdExpression(baseline, length: 9_998, suffix: suffix)
    #expect(a.document == expected && b.document == expected)
    #expect(a.mergeRecovery == nil && b.mergeRecovery == nil)
    #expect(a.changes().changes.count == 2 && b.changes().changes.count == 2)
    #expect(try a.resolve(positionA).offset == (actor == "z" ? 9_999 : 10_000))
    #expect(try b.resolve(positionB).offset == (actor == "z" ? 10_000 : 9_999))
    let reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    let undone = try thresholdExpression(baseline, length: 9_998, suffix: "B")
    #expect(reopened.document == undone && b.document == undone)
    #expect(reopened.canRedo && !reopened.canUndo)
    try reopened.redo(); try b.receive(reopened.changes()); try b.receive(reopened.changes())
    #expect(reopened.document == expected && b.document == expected)
    #expect(reopened.document.blocks[1] == baseline.blocks[1])
}

@Test(arguments: [4, 5], ["a", "z"])
func writingMathThresholdUnionAt10001RetainsProposalAndRepairsWithoutLosingPeerAtoms(version: Int, actor: String) throws {
    let baseline = try thresholdBaseline(9_999)
    let a = try thresholdSession(baseline, version: version, actor: actor)
    let b = try thresholdSession(baseline, version: version, actor: "m")
    let address = TextAddress("math", path: ["expression"])
    let positionA = try a.replaceText(at: address, range: 9_999..<9_999, with: "A")
    let positionB = try b.replaceText(at: address, range: 9_999..<9_999, with: "B")
    #expect(a.document == (try thresholdExpression(baseline, length: 9_999, suffix: "A")))
    #expect(b.document == (try thresholdExpression(baseline, length: 9_999, suffix: "B")))
    let acceptedA = try a.save(), acceptedB = try b.save()
    let receiptsA = a.syncState, receiptsB = b.syncState, batchA = a.changes(), batchB = b.changes()
    let pendingA = try thresholdPending(a, batch: batchB), pendingB = try thresholdPending(b, batch: batchA)
    #expect(pendingA == pendingB && pendingA.reason == .schemaConstraint)
    #expect(pendingA.batch.version == version && pendingA.batch.changes.count == 2)
    for _ in 0..<2 {
        #expect(try thresholdPending(a, batch: batchB) == pendingA)
        #expect(try thresholdPending(b, batch: batchA) == pendingB)
    }
    #expect(try a.save() == acceptedA)
    #expect(try b.save() == acceptedB)
    #expect(a.syncState == receiptsA && b.syncState == receiptsB)
    #expect(throws: WritingSessionError.self) { try a.undo() }
    #expect(throws: WritingSessionError.self) { try a.replaceText(at: address, range: 0..<0, with: "blocked") }
    let archiveA = try #require(try a.exportRecovery()), archiveB = try #require(try b.exportRecovery())
    let resumedA = try WritingSession.restore(acceptedA, actorID: actor)
    let resumedB = try WritingSession.restore(acceptedB, actorID: "m")
    #expect(throws: WritingSessionError.self) { try resumedA.restoreRecovery(archiveA) }
    #expect(throws: WritingSessionError.self) { try resumedB.restoreRecovery(archiveB) }
    #expect(resumedA.mergeRecovery == pendingA && resumedB.mergeRecovery == pendingB)
    #expect(try resumedA.save() == acceptedA)
    #expect(try resumedB.save() == acceptedB)
    #expect(resumedA.syncState == receiptsA && resumedB.syncState == receiptsB)
    #expect(try thresholdPending(resumedA, batch: batchB) == pendingA)
    let suffix = actor == "z" ? "AB" : "BA"
    // A failed no-op/over-limit repair cannot replace the accepted snapshot or
    // proposal. The successful repair deletes one original baseline scalar,
    // retaining BOTH authored suffix atoms and all sibling rich/opaque payloads.
    #expect(throws: EditorError.self) {
        try resumedA.repairText(node: .baseline(blockID: "math", path: []), field: "expression", text: String(repeating: "x", count: 9_999) + suffix)
    }
    #expect(try resumedA.save() == acceptedA)
    #expect(resumedA.mergeRecovery == pendingA && resumedA.syncState == receiptsA)
    let repaired = try thresholdExpression(baseline, length: 9_998, suffix: suffix)
    try resumedA.repairText(node: .baseline(blockID: "math", path: []), field: "expression", text: String(repeating: "x", count: 9_998) + suffix)
    #expect(resumedA.document == repaired && resumedA.mergeRecovery == nil)
    #expect(resumedA.changes().changes.count == 3)
    #expect(pendingA.batch.changes.allSatisfy { resumedA.changes().changes.contains($0) })
    #expect(try resumedA.resolve(positionA).offset == (actor == "z" ? 9_999 : 10_000))
    #expect(try resumedA.resolve(positionB).offset == (actor == "z" ? 10_000 : 9_999))
    let forwardRepair = resumedA.changes()
    let reverseRepair = WritingBatch(documentID: forwardRepair.documentID, epoch: forwardRepair.epoch, baseline: forwardRepair.baseline,
        changes: forwardRepair.changes.reversed(), version: version)
    try resumedB.receive(reverseRepair); try resumedB.receive(resumedA.changes()); try resumedB.receive(reverseRepair)
    #expect(resumedB.document == repaired && resumedB.mergeRecovery == nil)
    #expect(resumedB.document.blocks[1] == baseline.blocks[1])
    let reopened = try WritingSession.restore(resumedA.save(), actorID: actor)
    let beforeUndo = try reopened.save(), beforeUndoReceipts = reopened.syncState
    let repair = try #require(reopened.changes().changes.first { $0.id.actor == actor && $0.id.counter == 2 }?.id)
    #expect(throws: WritingSessionError.self) { try reopened.undo() }
    let pendingUndo = try #require(reopened.mergeRecovery)
    #expect(pendingUndo.reason == .schemaConstraint && pendingUndo.batch.changes.count == 4)
    #expect(try reopened.save() == beforeUndo)
    #expect(reopened.syncState == beforeUndoReceipts)
    let stopped = try WritingSession.restore(beforeUndo, actorID: actor)
    #expect(throws: WritingSessionError.self) { try stopped.restoreRecovery(try #require(try reopened.exportRecovery())) }
    try stopped.repairRedo(repair)
    #expect(stopped.document == repaired && stopped.mergeRecovery == nil)
    #expect(pendingUndo.batch.changes.allSatisfy { stopped.changes().changes.contains($0) })
    try resumedB.receive(stopped.changes()); try resumedB.receive(stopped.changes())
    #expect(resumedB.document == repaired && resumedB.changes().changes.count == 5)
    #expect(try stopped.resolve(positionA).offset == (actor == "z" ? 9_999 : 10_000))
    #expect(try stopped.resolve(positionB).offset == (actor == "z" ? 10_000 : 9_999))
}
