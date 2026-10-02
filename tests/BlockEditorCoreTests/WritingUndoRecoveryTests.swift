import BlockEditorCore
import Foundation
import Testing

private struct UndoRecoveryEnvelope: Encodable { let reason: MergeRecoveryReason; let batch: WritingBatch }

private func requiredWritingUndo(_ actor: String) throws -> (WritingSession, WritingSession, NodeID, ChangeID) {
    let rich: JSONValue = .object(["id": .string("rich"), "type": .string("paragraph"), "host": .string("keep"),
        "content": .array([textNode("café 😀", marks: [.object(["type": .string("bold")])]),
            .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("external"), "label": .string("Reference")])])])
    let baseline = try Document(blocks: [Block(fields: rich.object!)])
    let a = try WritingSession(documentID: "undo-recovery", actorID: actor, epoch: "v4-undo", document: baseline, protocolVersion: 4)
    let b = try WritingSession(documentID: "undo-recovery", actorID: "peer", epoch: "v4-undo", document: baseline, protocolVersion: 4)
    let selected = try a.insertCollectionNodes([.object(["id": .string("math"), "type": .string("math"), "expression": .string("x+y"),
        "extension": .object(["remote": .bool(false), "later": .number(0)])])], into: .root)
    let math = try #require(selected.nodes.first), creation = try #require(a.changes().changes.first?.id)
    try b.receive(a.changes())
    let peer = WritingChange(id: ChangeID(counter: 2, actor: "peer"), body: .edit([
        .structure(.setNodeField(identity: math, path: ["extension", "remote"], value: .bool(true)))]), observed: [creation])
    try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: baseline, changes: [peer], version: 4))
    try a.receive(b.changes())
    return (a, b, math, creation)
}

private func rejectedWritingUndo(_ session: WritingSession) throws -> WritingRecovery {
    do { try session.undo(); Issue.record("Invalid required-field undo was accepted") }
    catch WritingSessionError.recoveryRequired(let proposal) { return proposal }
    return try #require(session.mergeRecovery)
}

@Test(arguments: ["a", "z"])
func v4RequiredUndoPersistsAndExplicitRedoRetainsEveryHistory(actor: String) throws {
    let (a, b, math, creation) = try requiredWritingUndo(actor)
    let accepted = try a.save(), receipts = a.syncState, document = a.document
    let proposal = try rejectedWritingUndo(a)
    #expect(proposal.reason == .schemaConstraint && proposal.batch.changes.count == 3)
    #expect(try a.save() == accepted && a.syncState == receipts && a.document == document)
    #expect(throws: WritingSessionError.self) { try a.redo() }
    #expect(throws: WritingSessionError.self) { try a.replaceText(at: TextAddress("rich"), range: 0..<0, with: "blocked") }
    let exported = try #require(try a.exportRecovery())
    let restored = try WritingSession.restore(accepted, actorID: actor)
    do { try restored.restoreRecovery(exported); Issue.record("Invalid proposal was admitted") } catch WritingSessionError.recoveryRequired { }
    #expect(restored.mergeRecovery == proposal && restored.syncState == receipts)
    #expect(try restored.save() == accepted)
    #expect(throws: EditorError.invalidChange) { try restored.repairRedo(ChangeID(counter: 2, actor: "peer")) }
    #expect(restored.mergeRecovery == proposal)
    #expect(try restored.save() == accepted)
    var prepared = false, sawFinalHistory = false
    restored.onWillReceive = {
        prepared = (try? restored.save()) == accepted && restored.mergeRecovery == proposal
        #expect(throws: EditorError.invalidChange) { try restored.repairRedo(creation) }
    }
    restored.onChange = { _, _ in sawFinalHistory = restored.mergeRecovery == nil && restored.canUndo }
    try restored.repairRedo(creation)
    #expect(prepared && sawFinalHistory)
    #expect(restored.changes().changes.count == 4)
    #expect(proposal.batch.changes.allSatisfy { restored.changes().changes.contains($0) })
    #expect(restored.document == document)
    try b.receive(restored.changes()); try b.receive(restored.changes()); try restored.receive(b.changes())
    #expect(b.document == document && restored.mergeRecovery == nil)
    #expect(try restored.address(of: math) == NodeAddress("math"))
    let reopened = try WritingSession.restore(restored.save(), actorID: actor)
    #expect(reopened.document == document && reopened.canUndo)
}

@Test(arguments: ["a", "z"])
func v4TextRepairCompletesRequiredUndoAndPreservesAdditionalPeerMetadata(actor: String) throws {
    let (a, b, math, creation) = try requiredWritingUndo(actor)
    let accepted = try a.save(), receipts = a.syncState, rich = a.document.blocks.first { $0.id == "rich" }
    _ = try rejectedWritingUndo(a)
    let peer = WritingChange(id: ChangeID(counter: 3, actor: "peer"), body: .edit([
        .structure(.setNodeField(identity: math, path: ["extension", "later"], value: .number(7)))]),
        observed: [creation, ChangeID(counter: 2, actor: "peer")])
    try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: [peer], version: 4))
    for _ in 0..<2 {
        do { try a.receive(b.changes()); Issue.record("Required field remains invalid") } catch WritingSessionError.recoveryRequired { }
    }
    let proposal = try #require(a.mergeRecovery), bytes = try #require(try a.exportRecovery())
    #expect(proposal.batch.changes.count == 4 && a.syncState == receipts)
    #expect(try a.save() == accepted)
    let resumed = try WritingSession.restore(accepted, actorID: actor)
    do { try resumed.restoreRecovery(bytes); Issue.record("Invalid proposal was admitted") } catch WritingSessionError.recoveryRequired { }
    #expect(throws: EditorError.invalidChange) { try resumed.repairText(node: math, field: "expression", text: "") }
    #expect(throws: EditorError.invalidPath) { try resumed.repairText(node: math, field: "children", text: "bad") }
    #expect(throws: EditorError.invalidRange) {
        try resumed.repairText(node: .baseline(blockID: "rich", path: []), field: "content", text: "café 😀RefeXrence")
    }
    #expect(resumed.mergeRecovery == proposal && resumed.syncState == receipts)
    #expect(try resumed.save() == accepted)
    var finalUndo = false
    resumed.onChange = { _, _ in finalUndo = resumed.canUndo && resumed.mergeRecovery == nil }
    try resumed.repairText(node: math, field: "expression", text: "restored x+y 😀")
    #expect(finalUndo && resumed.changes().changes.count == 5)
    #expect(resumed.document.blocks.first { $0.id == "rich" } == rich)
    let repaired = try #require(resumed.document.blocks.first { $0.id == "math" })
    #expect(repaired.fields["expression"] == .string("restored x+y 😀"))
    #expect(repaired.fields["extension"] == .object(["remote": .bool(true), "later": .number(7)]))
    #expect(proposal.batch.changes.allSatisfy { resumed.changes().changes.contains($0) })
    try b.receive(resumed.changes()); try b.receive(resumed.changes())
    #expect(b.document == resumed.document)
    let saved = try resumed.save(), redoTarget = try #require(resumed.changes().changes.last?.id)
    let reopened = try WritingSession.restore(saved, actorID: actor)
    _ = try rejectedWritingUndo(reopened)
    #expect(try reopened.save() == saved)
    try reopened.repairRedo(redoTarget)
    #expect(reopened.document == resumed.document && reopened.mergeRecovery == nil)
}

@Test func v4RepairGuardsPreserveAcceptedAndPendingHistories() throws {
    let (a, _, math, creation) = try requiredWritingUndo("a")
    _ = try rejectedWritingUndo(a)
    let saved = try a.save(), pending = a.mergeRecovery, receipts = a.syncState
    a.isComposing = true
    #expect(throws: EditorError.invalidChange) { try a.repairRedo(creation) }
    #expect(throws: EditorError.invalidChange) { try a.repairText(node: math, field: "expression", text: "fixed") }
    a.isComposing = false
    let release = a.deferRemoteChanges()
    #expect(throws: EditorError.invalidChange) { try a.repairText(node: math, field: "expression", text: "fixed") }
    try release()
    let incompatible = UndoRecoveryEnvelope(reason: .schemaConstraint, batch: WritingBatch(documentID: "wrong", epoch: a.epoch, baseline: a.baseline, changes: [], version: 4))
    #expect(throws: EditorError.differentDocument) { try a.restoreRecovery(JSONEncoder().encode(incompatible)) }
    let old = UndoRecoveryEnvelope(reason: .schemaConstraint, batch: WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [], version: 3))
    #expect(throws: EditorError.unsupportedVersion(3)) { try a.restoreRecovery(JSONEncoder().encode(old)) }
    #expect(throws: EditorError.invalidRange) { try a.repairText(node: math, field: "expression", text: String(repeating: "x", count: 100_001)) }
    #expect(try a.save() == saved && a.syncState == receipts && a.mergeRecovery == pending)
    let legacy = try WritingSession(documentID: "legacy", actorID: "a", epoch: "v3", document: Document(blocks: []))
    #expect(throws: EditorError.unsupportedVersion(3)) { try legacy.repairRedo(creation) }
    #expect(throws: EditorError.unsupportedVersion(3)) { try legacy.repairText(node: math, field: "expression", text: "fixed") }
}

@Test func v4PendingReceiveBlocksHistoryEvenWhenNeitherStackHasAnEntry() throws {
    let (a, b, _, _) = try requiredWritingUndo("a")
    _ = try rejectedWritingUndo(a)
    let observer = try WritingSession(documentID: a.documentID, actorID: "observer", epoch: a.epoch, document: a.baseline, protocolVersion: 4)
    try observer.receive(b.changes())
    let accepted = try observer.save(), receipts = observer.syncState
    do { try observer.restoreRecovery(try #require(try a.exportRecovery())); Issue.record("Invalid pending undo admitted") } catch WritingSessionError.recoveryRequired { }
    #expect(!observer.canUndo && !observer.canRedo)
    #expect(throws: WritingSessionError.self) { try observer.undo() }
    #expect(throws: WritingSessionError.self) { try observer.redo() }
    #expect(try observer.save() == accepted && observer.syncState == receipts && observer.mergeRecovery == a.mergeRecovery)
}

@Test(arguments: ["a", "z"])
func v4ConcurrentTextRepairsRetainBothAuthorsAndRecoverAfterBothUndos(actor: String) throws {
    let (a, b, math, _) = try requiredWritingUndo(actor)
    let acceptedA = try a.save(), acceptedB = try b.save(), rich = a.document.blocks.first { $0.id == "rich" }
    let rejected = try rejectedWritingUndo(a)
    do { try b.restoreRecovery(try #require(try a.exportRecovery())); Issue.record("Invalid shared Undo admitted") }
    catch WritingSessionError.recoveryRequired { }
    #expect(a.mergeRecovery == rejected && b.mergeRecovery == rejected)
    #expect(try a.save() == acceptedA)
    #expect(try b.save() == acceptedB)
    try a.repairText(node: math, field: "expression", text: "Left😀")
    try b.repairText(node: math, field: "expression", text: "Righté")
    let ownA = try #require(a.changes().changes.first { $0.id.actor == actor && $0.id.counter == 4 }?.id)
    let ownB = try #require(b.changes().changes.first { $0.id.actor == "peer" && $0.id.counter == 4 }?.id)
    let repairA = a.changes(), repairB = b.changes()
    try a.receive(repairB); try a.receive(repairB)
    try b.receive(repairA); try b.receive(repairA)
    #expect(a.document == b.document && a.changes().changes.count == 5)
    let expression = try a.text(at: TextAddress("math", path: ["expression"], identity: math))
    #expect(expression == "Left😀Righté" || expression == "RightéLeft😀")
    #expect(a.document.blocks.first { $0.id == "rich" } == rich)
    #expect(a.document.blocks.first { $0.id == "math" }?.fields["extension"] == .object(["remote": .bool(true), "later": .number(0)]))
    let reopenedA = try WritingSession.restore(a.save(), actorID: actor)
    let reopenedB = try WritingSession.restore(b.save(), actorID: "peer")
    try reopenedA.undo(); try reopenedB.undo()
    #expect(try reopenedA.text(at: TextAddress("math", path: ["expression"], identity: math)) == "Righté")
    #expect(try reopenedB.text(at: TextAddress("math", path: ["expression"], identity: math)) == "Left😀")
    let afterUndoA = try reopenedA.save(), afterUndoB = try reopenedB.save()
    let receiptA = reopenedA.syncState, receiptB = reopenedB.syncState
    let undoA = reopenedA.changes(), undoB = reopenedB.changes()
    for _ in 0..<2 {
        do { try reopenedA.receive(undoB); Issue.record("Both repairs undone left required expression empty") }
        catch WritingSessionError.recoveryRequired { }
        do { try reopenedB.receive(undoA); Issue.record("Both repairs undone left required expression empty") }
        catch WritingSessionError.recoveryRequired { }
    }
    #expect(reopenedA.mergeRecovery == reopenedB.mergeRecovery)
    #expect(reopenedA.syncState == receiptA && reopenedB.syncState == receiptB)
    #expect(try reopenedA.save() == afterUndoA)
    #expect(try reopenedB.save() == afterUndoB)
    let pendingA = try #require(try reopenedA.exportRecovery()), pendingB = try #require(try reopenedB.exportRecovery())
    let restartedA = try WritingSession.restore(afterUndoA, actorID: actor)
    let restartedB = try WritingSession.restore(afterUndoB, actorID: "peer")
    do { try restartedA.restoreRecovery(pendingA); Issue.record("Invalid restarted proposal admitted") }
    catch WritingSessionError.recoveryRequired { }
    do { try restartedB.restoreRecovery(pendingB); Issue.record("Invalid restarted proposal admitted") }
    catch WritingSessionError.recoveryRequired { }
    try restartedA.repairRedo(ownA); try restartedB.repairRedo(ownB)
    let redoA = restartedA.changes(), redoB = restartedB.changes()
    try restartedB.receive(redoA); try restartedB.receive(redoA)
    try restartedA.receive(redoB); try restartedA.receive(redoB)
    #expect(restartedA.document == restartedB.document && restartedA.document == a.document)
    #expect(restartedA.mergeRecovery == nil && restartedB.mergeRecovery == nil)
    #expect(restartedA.changes().changes.count == 9 && restartedB.changes().changes.count == 9)
    #expect(restartedA.document.blocks.first { $0.id == "rich" } == rich)
    #expect(try restartedA.address(of: math) == NodeAddress("math"))
}
