import Foundation
@testable import BlockEditorCore
import Testing

private func paragraph(_ id: String, _ text: String) throws -> Block {
    try Block(fields: ["id": .string(id), "type": .string("paragraph"), "content": .array(text.isEmpty ? [] : [textNode(text)])])
}
private func writing(_ actor: String, _ blocks: [Block]) throws -> WritingSession {
    try WritingSession(documentID: "original-document", actorID: actor, epoch: "writing-1", document: Document(blocks: blocks))
}
private func exchange(_ a: WritingSession, _ b: WritingSession) throws {
    let first = a.changes(), second = b.changes()
    try a.receive(second); try b.receive(first)
}

@Test func writingSessionSplitFollowsRemoteTextMarksSelectionsAndOneUndo() throws {
    let blocks = [try paragraph("left", "abcd")], a = try writing("a", blocks), b = try writing("b", blocks)
    let anchor = try b.position(at: TextAddress("left"), offset: 3, affinity: .after)
    let splitSelection = try a.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "right")
    try b.replaceText(at: TextAddress("left"), range: 3..<3, with: "X")
    try b.format(at: TextAddress("left"), range: 2..<3, markType: "bold", mark: .object(["type": .string("bold")]))
    try exchange(a, b)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.text) == ["ab", "cXd"])
    #expect(a.document.blocks[1].fields["content"]?.array?.first?["marks"] == .array([.object(["type": .string("bold")])]))
    #expect(try a.resolve(anchor).offset == 1)
    #expect(try a.resolve(anchor).address == a.textAddress(of: a.node(at: NodeAddress("right"))))
    #expect(try a.resolve(splitSelection).offset == 0)
    try a.undo(); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.text) == ["abcXd"])
    #expect(!a.canUndo && a.canRedo)
    #expect(try a.resolve(anchor).offset == 3)
    try a.redo(); #expect(a.document.blocks.map(\.text) == ["ab", "cXd"])
}

@Test func writingSessionMergeKeepsEmptySourceRemoteInputAndRestoresOrigins() throws {
    let blocks = [try paragraph("left", "ab"), try paragraph("right", "")]
    let a = try writing("a", blocks), b = try writing("b", blocks)
    let emptyPosition = try b.position(at: TextAddress("right"), offset: 0)
    try a.mergeParagraphs(left: a.node(at: NodeAddress("left")), right: a.node(at: NodeAddress("right")))
    try b.replaceText(at: TextAddress("right"), range: 0..<0, with: "X")
    try exchange(a, b)
    #expect(a.document.blocks.map(\.text) == ["abX"])
    #expect(try a.resolve(emptyPosition).address == a.textAddress(of: a.node(at: NodeAddress("left"))))
    try a.undo(); #expect(a.document.blocks.map(\.text) == ["ab", "X"])
    #expect(try a.resolve(emptyPosition).address == a.textAddress(of: a.node(at: NodeAddress("right"))))
}

@Test func writingSessionUndoEmptySplitRetainsIndependentRemoteParagraph() throws {
    let a = try writing("a", [paragraph("left", "ab")]), b = try writing("b", [paragraph("left", "ab")])
    try a.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "right")
    try b.receive(a.changes())
    try b.replaceText(at: TextAddress("right"), range: 0..<0, with: "remote")
    try a.receive(b.changes()); try a.undo()
    #expect(a.document.blocks.map(\.text) == ["ab", "remote"])
    #expect(a.document.blocks.map(\.id) == ["left", "right"])
}

@Test func writingSessionUnicodeReferenceAndUnknownPayloadSurviveSplitReopen() throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("stable"), "entityType": .string("note"), "label": .string("世界😀"), "host": .object(["keep": .bool(true)])])
    let bold: JSONValue = .object(["type": .string("bold")])
    var scalar = textNode("😀e\u{301}", marks: [bold]).object!
    scalar["host"] = .string("keep")
    let block = try Block(fields: ["id": .string("left"), "type": .string("paragraph"), "content": .array([.object(scalar), reference]), "consumer": .string("preserved")])
    let a = try writing("a", [block])
    let accepted = try a.save()
    #expect(throws: EditorError.invalidRange) { try a.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "bad") }
    #expect(throws: EditorError.invalidRange) { try a.splitParagraph(at: TextAddress("left"), range: 5..<5, newBlockID: "bad") }
    #expect(try a.save() == accepted)
    try a.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "right")
    #expect(a.document.blocks.map(\.text) == ["😀", "e\u{301}世界😀"])
    #expect(a.document.blocks[1].fields["content"]?.array?.last == reference)
    #expect(a.document.blocks[0].fields["consumer"] == .string("preserved"))
    let restored = try WritingSession.restore(a.save(), actorID: "a")
    #expect(restored.document == a.document && restored.canUndo)
    try restored.undo(); #expect(try restored.document == Document(blocks: [block]))
    let peer = try WritingSession.restore(a.save(), actorID: "new-author")
    #expect(!peer.canUndo)
}

@Test func writingSessionReplacementAndSoftBreakAreAtomicAndCompositionGuarded() throws {
    let a = try writing("a", [paragraph("left", "abcd")])
    let position = try a.replaceText(at: TextAddress("left"), range: 1..<3, with: "😀")
    #expect(a.document.blocks.map(\.text) == ["a😀d"])
    #expect(try a.resolve(position).offset == 3)
    try a.undo(); #expect(a.document.blocks.map(\.text) == ["abcd"])
    try a.softBreak(at: TextAddress("left"), range: 2..<2)
    #expect(a.document.blocks.map(\.text) == ["ab\ncd"])
    a.isComposing = true
    let accepted = try a.save()
    #expect(throws: WritingSessionError.compositionActive) { try a.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "right") }
    #expect(try a.save() == accepted)
}

@Test func writingSessionObserverSeesFinalUndoAndRedoHistory() throws {
    let a = try writing("a", [paragraph("left", "ab")])
    try a.replaceText(at: TextAddress("left"), range: 2..<2, with: "X")
    var observed: [Bool] = []
    a.onChange = { _, _ in observed = [a.canUndo, a.canRedo] }
    try a.undo(); #expect(observed == [false, true])
    try a.redo(); #expect(observed == [true, false])
}

@Test func writingSessionRejectsOldEpochProtocolAndMalformedBirthWithoutAcknowledging() throws {
    let a = try writing("a", [paragraph("left", "ab")]), accepted = try a.save()
    #expect(throws: WritingSessionError.incompatibleEpoch) { try a.receive(WritingBatch(documentID: a.documentID, epoch: "old", baseline: a.baseline, changes: [])) }
    #expect(throws: EditorError.unsupportedVersion(2)) { try a.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [], version: 2)) }
    let origin = WritingField(node: .baseline(blockID: "left", path: []), name: "content"), id = ChangeID(counter: 1, actor: "b")
    let bad = WritingAtomSeed(key: WritingAtomKey(origin: origin, element: ElementID(change: id, index: -1)), node: textNode("X"), edge: .start, route: .field(origin))
    #expect(throws: EditorError.invalidChange) { try a.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [WritingChange(id: id, body: .edit([.text(.insert(bad))]))])) }
    let oversized = WritingAtomSeed(key: WritingAtomKey(origin: origin, element: ElementID(change: id, index: 2_147_483_648)), node: textNode("X"), edge: .start, route: .field(origin))
    #expect(throws: EditorError.invalidChange) { try a.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [WritingChange(id: id, body: .edit([.text(.insert(oversized))]))])) }
    #expect(try a.save() == accepted && a.mergeRecovery == nil && a.syncState.received.isEmpty)
}

@Test func writingSessionCausalGapRecoveryPersistsSeparatelyAndReplaysOnRejoin() throws {
    let a = try writing("a", [paragraph("left", "ab")]), b = try writing("b", [paragraph("left", "ab")])
    try b.replaceText(at: TextAddress("left"), range: 1..<1, with: "X")
    let receipt = b.syncState
    try b.replaceText(at: TextAddress("left"), range: 1..<1, with: "Y")
    let accepted = try a.save()
    do { try a.receive(b.changes(since: receipt)); Issue.record("Missing causal atom was acknowledged") }
    catch WritingSessionError.recoveryRequired { }
    #expect(try a.save() == accepted && a.syncState.received.isEmpty)
    let pending = try #require(try a.exportRecovery())
    let reopened = try WritingSession.restore(accepted, actorID: "a")
    do { try reopened.restoreRecovery(pending) } catch WritingSessionError.recoveryRequired { }
    #expect(reopened.mergeRecovery == a.mergeRecovery)
    try reopened.receive(b.changes())
    #expect(reopened.document.blocks.map(\.text) == ["aYXb"])
    #expect(reopened.mergeRecovery == nil && reopened.syncState.received.count == 2)
}

@Test func writingSessionCompositionDefersReceiptsCapturesSelectionAndReleasesOnce() throws {
    let a = try writing("a", [paragraph("left", "ab")]), b = try writing("b", [paragraph("left", "ab")])
    let release = a.deferRemoteChanges(), accepted = try a.save()
    try b.replaceText(at: TextAddress("left"), range: 1..<1, with: "X")
    try a.receive(b.changes())
    #expect(try a.save() == accepted && a.syncState.received.isEmpty)
    #expect(try JSONDecoder().decode([WritingBatch].self, from: a.exportDeferredChanges()).count == 1)
    var captured = false
    a.onWillReceive = {
        captured = a.document.blocks[0].text == "ab"
        #expect(throws: EditorError.invalidChange) { try a.replaceText(at: TextAddress("left"), range: 0..<0, with: "bad") }
    }
    try release(); #expect(captured && a.document.blocks[0].text == "aXb")
    let applied = try a.save(); try release(); #expect(try a.save() == applied)
}

@Test func writingSessionReferenceInteriorSelectionFollowsSplitAndDeletion() throws {
    let ref: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("same"), "entityType": .string("note"), "label": .string("A😀B")])
    let block = try Block(fields: ["id": .string("left"), "type": .string("paragraph"), "content": .array([textNode("x"), ref])])
    let a = try writing("a", [block]), position = try a.position(at: TextAddress("left"), offset: 4)
    #expect(throws: EditorError.invalidRange) { try a.position(at: TextAddress("left"), offset: 3) }
    try a.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "right")
    #expect(try a.resolve(position).offset == 3)
    try a.replaceText(at: TextAddress("right"), range: 0..<4, with: "")
    #expect(try a.resolve(position).offset == 0)
}

@Test func writingSessionReentrantCompositionQueueRetainsNewPacketsDuringDrain() throws {
    let blocks = [try paragraph("left", "ab")]
    let a = try writing("a", blocks), b = try writing("b", blocks), c = try writing("c", blocks)
    try b.replaceText(at: TextAddress("left"), range: 0..<0, with: "B")
    try c.replaceText(at: TextAddress("left"), range: 2..<2, with: "C")
    let release = a.deferRemoteChanges()
    try a.receive(b.changes())
    var secondRelease: (() throws -> Void)?
    a.onChange = { _, _ in
        if secondRelease == nil {
            secondRelease = a.deferRemoteChanges()
            do { try a.receive(c.changes()) } catch { Issue.record("Callback queue failed: \(error)") }
        }
    }
    try release()
    #expect(a.document.blocks[0].text == "Bab")
    #expect(try JSONDecoder().decode([WritingBatch].self, from: a.exportDeferredChanges()).count == 1)
    try secondRelease?()
    #expect(a.document.blocks[0].text == "BabC")
    #expect(a.syncState.received.count == 2)
}

@Test func writingSessionCutoverPreservesDocumentIDRequiresReconciliationAndArchivesUndo() throws {
    let document = try Document(blocks: [paragraph("left", "ab")])
    let old = try EditorSession(documentID: "same-document", actorID: "a", document: document, collaborationVersion: 2)
    let offline = try EditorSession(documentID: old.documentID, actorID: "b", document: document, collaborationVersion: 2)
    try old.replaceText(at: TextAddress("left"), range: 0..<0, with: "A")
    let accepted = try old.save()
    try offline.replaceText(at: TextAddress("left"), range: 2..<2, with: "B")
    let premature = WritingCutoverArchive(acceptedSnapshot: accepted, unacknowledged: [offline.changes()], reconciledSnapshot: accepted, epoch: "v3")
    #expect(throws: EditorError.invalidChange) { try ProtocolMigration.cutoverToV3(premature, actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true) }
    try old.receive(offline.changes())
    let archive = WritingCutoverArchive(acceptedSnapshot: accepted, unacknowledged: [offline.changes()], reconciledSnapshot: try old.save(), epoch: "v3")
    #expect(throws: EditorError.invalidChange) { try ProtocolMigration.cutoverToV3(archive, actorID: "a", oldWritersStopped: false, archivePersisted: true, resetUndoAcknowledged: true) }
    let next = try ProtocolMigration.cutoverToV3(archive, actorID: "a", oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true)
    #expect(next.documentID == old.documentID && next.epoch == "v3")
    #expect(try next.document == old.document)
    #expect(!next.canUndo && next.changes().changes.isEmpty)
    #expect(try EditorSession.restore(archive.acceptedSnapshot, actorID: "a").canUndo)
}

@Test(arguments: [false, true]) func writingSessionConcurrentDifferentCutsPreserveSegmentOrder(swap: Bool) throws {
    let blocks = [try paragraph("left", "abcd")]
    let lower = try writing(swap ? "b" : "a", blocks), upper = try writing(swap ? "a" : "b", blocks)
    try lower.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "lower-cut")
    try upper.splitParagraph(at: TextAddress("left"), range: 3..<3, newBlockID: "upper-cut")
    try exchange(lower, upper)
    #expect(lower.document == upper.document)
    #expect(lower.document.blocks.map(\.text) == ["a", "bc", "d"])
    #expect(lower.document.blocks.map(\.id) == ["left", "lower-cut", "upper-cut"])
    try lower.undo(); try upper.receive(lower.changes())
    #expect(lower.document.blocks.map(\.text) == ["abc", "d"])
    try upper.undo(); try lower.receive(upper.changes())
    #expect(lower.document.blocks.map(\.text) == ["abcd"])
}

@Test func writingSessionConcurrentSameCutRetainsBothBreaksAndUndo() throws {
    let blocks = [try paragraph("left", "abcd")], a = try writing("a", blocks), b = try writing("b", blocks)
    try a.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "first-cut")
    try b.splitParagraph(at: TextAddress("left"), range: 2..<2, newBlockID: "second-cut")
    try exchange(a, b)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.text) == ["ab", "", "cd"])
    #expect(a.document.blocks.map(\.id) == ["left", "first-cut", "second-cut"])
    try a.undo(); try b.receive(a.changes())
    #expect(a.document.blocks.map(\.text) == ["ab", "cd"])
    try b.undo(); try a.receive(b.changes())
    #expect(a.document.blocks.map(\.text) == ["abcd"])
}

@Test(arguments: [false, true], ["left", "right"]) func writingSessionConcurrentMergeSplitFollowsBoundary(swap: Bool, side: String) throws {
    let blocks = [try paragraph("left", "ab"), try paragraph("right", "cd")]
    let merge = try writing(swap ? "b" : "a", blocks), split = try writing(swap ? "a" : "b", blocks)
    try merge.mergeParagraphs(left: merge.node(at: NodeAddress("left")), right: merge.node(at: NodeAddress("right")))
    try split.splitParagraph(at: TextAddress(side), range: 1..<1, newBlockID: "cut")
    try exchange(merge, split)
    #expect(merge.document == split.document)
    #expect(merge.document.blocks.map(\.text) == (side == "left" ? ["a", "bcd"] : ["abc", "d"]))
    try merge.undo(); try split.receive(merge.changes())
    #expect(merge.document.blocks.map(\.text) == (side == "left" ? ["a", "b", "cd"] : ["ab", "c", "d"]))
}

@Test(arguments: ["writing", "blockCommands", "schemaCommands", "roleCommands", "collectionCommands", "exitCommands", "pinCommands", "boundaryCommands", "undoRecoveryCommands", "clipboardCommands", "spliceCommands", "thresholdCommands", "depthCommands", "importCommands", "paste6Commands"]) func writingSharedBridgeFixture(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)), bridge = EditorBridge()
    var captured: [String: JSONValue] = [:]
    for step in fixture["steps"]!.array! {
        var request = step["request"]!.object!
        for (key, binding) in step["bindings"]?.object ?? [:] {
            let path = binding.array?.compactMap(\.string) ?? [binding.string!]
            var value = captured[path[0]]!
            for part in path.dropFirst() { value = value[part]! }
            request[key] = value
        }
        let response = try JSONDecoder().decode(JSONValue.self, from: bridge.call(canonicalEncoder().encode(JSONValue.object(request))))
        if let error = step["error"] { #expect(response["ok"] == .bool(false)); #expect(response["error"] == error) }
        else { #expect(response["ok"] == .bool(true), "\(response)") }
        if let capture = step["capture"]?.string { captured[capture] = response[step["error"] == nil ? "value" : "recovery"] }
    }
    for pair in fixture["equal"]!.array! { #expect(captured[pair.array![0].string!] == captured[pair.array![1].string!]) }
    for (key, blocks) in fixture["expectedBlocks"]!.object! { #expect(captured[key]?["blocks"] == blocks, "\(key)") }
    for (key, expected) in fixture["expectedValues"]!.object! { #expect(captured[key] == expected, "\(key)") }
}

@Test(arguments: [0, 1]) func writingSessionSequentialCutsKeepObservedSiblingOrder(offset: Int) throws {
    let a = try writing("a", [paragraph("left", "abcd")])
    try a.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "first")
    try a.splitParagraph(at: TextAddress("left"), range: offset..<offset, newBlockID: "second")
    #expect(a.document.blocks.map(\.id) == ["left", "second", "first"])
    #expect(a.document.blocks.map(\.text) == (offset == 1 ? ["a", "", "bcd"] : ["", "a", "bcd"]))
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
    try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["a", "bcd"])
    try reopened.redo(); #expect(reopened.document == a.document)
}

@Test func writingSessionRecoveryRepairUndoPreservesRemoteCutAndFailureProposal() throws {
    let blocks = [try paragraph("left", "abcd")], a = try writing("a", blocks), b = try writing("b", blocks)
    try a.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "collision")
    try b.splitParagraph(at: TextAddress("left"), range: 3..<3, newBlockID: "collision")
    let accepted = try a.save()
    do { try a.receive(b.changes()); Issue.record("Conflicting sibling labels were acknowledged") } catch WritingSessionError.recoveryRequired { }
    let proposal = a.mergeRecovery
    #expect(try a.save() == accepted && proposal != nil)
    #expect(throws: EditorError.invalidChange) { try a.repairUndo(ChangeID(counter: 1, actor: "b")) }
    #expect(a.mergeRecovery == proposal)
    try a.repairUndo(ChangeID(counter: 1, actor: "a"))
    #expect(a.document.blocks.map(\.text) == ["abc", "d"])
    #expect(a.document.blocks.map(\.id) == ["left", "collision"])
    #expect(a.mergeRecovery == nil && a.changes().changes.count == 3 && a.canRedo)
    try b.receive(a.changes()); #expect(a.document == b.document)
}

@Test func writingSessionNewLinksRejectUnsafeSchemesWithoutChangingLegacyBaseline() throws {
    let old: JSONValue = .object(["type": .string("link"), "href": .string("javascript:legacy")])
    let block = try Block(fields: ["id": .string("left"), "type": .string("paragraph"), "content": .array([textNode("a", marks: [old])])])
    let a = try writing("a", [block]), accepted = try a.save()
    #expect(throws: EditorError.invalidChange) { try a.replaceText(at: TextAddress("left"), range: 1..<1, with: "bad", marks: [old]) }
    #expect(try a.save() == accepted && a.document.blocks[0] == block)
}

@Test func writingSessionEmptyTextExtensionsSurviveAuthoringAndUndo() throws {
    let empty: JSONValue = .object(["type": .string("text"), "text": .string(""), "marks": .array([]), "host": .string("retain")])
    let block = try Block(fields: ["id": .string("left"), "type": .string("paragraph"), "content": .array([empty, textNode("ab")])])
    let a = try writing("a", [block])
    try a.replaceText(at: TextAddress("left"), range: 2..<2, with: "X")
    #expect(a.document.blocks[0].fields["content"]?.array?.first == empty)
    try a.undo(); #expect(a.document.blocks == [block])
}

@Test func writingSessionNestedSplitKeepsContainerIDsReferencesAndUndo() throws {
    let child = try paragraph("child", "abcd")
    let toggle = try Block(fields: ["id": .string("root"), "type": .string("toggle"), "summary": .array([textNode("summary")]), "children": .array([.object(child.fields)]), "host": .string("keep")])
    let a = try writing("a", [toggle]), address = TextAddress("root", path: ["children", "child", "content"])
    try a.splitParagraph(at: address, range: 2..<2, newBlockID: "sibling")
    #expect(a.document.blocks[0].fields["host"] == .string("keep"))
    #expect(a.document.blocks[0].fields["children"]?.array?.map { $0["id"]?.string } == ["child", "sibling"])
    #expect(a.document.blocks[0].fields["children"]?.array?.map { plainText($0["content"]?.array ?? []) } == ["ab", "cd"])
    try a.undo(); #expect(a.document.blocks == [toggle])
}

@Test func writingSessionRepairReconcilesRetainedOwnUndoBeforeSaveRestore() throws {
    let blocks = [try paragraph("left", "abcd")], original = try writing("a", blocks), peer = try writing("b", blocks)
    try original.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "collision")
    try original.format(at: TextAddress("left"), range: 0..<1, markType: "bold", mark: .object(["type": .string("bold")]))
    let accepted = try original.save()
    let stopped = try WritingSession.restore(accepted, actorID: "a")
    try stopped.undo()
    try peer.splitParagraph(at: TextAddress("left"), range: 3..<3, newBlockID: "collision")
    let resumed = try WritingSession.restore(accepted, actorID: "a")
    let union = WritingBatch(documentID: resumed.documentID, epoch: resumed.epoch, baseline: resumed.baseline, changes: stopped.changes().changes + peer.changes().changes)
    do { try resumed.receive(union); Issue.record("Sibling identity conflict was acknowledged") } catch WritingSessionError.recoveryRequired { }
    #expect(try resumed.save() == accepted)
    try resumed.repairUndo(ChangeID(counter: 1, actor: "a"))
    let reopened = try WritingSession.restore(resumed.save(), actorID: "a")
    #expect(!reopened.canUndo && reopened.canRedo)
    #expect(reopened.document == resumed.document)
    #expect(reopened.document.blocks.map(\.text) == ["abc", "d"])
}

@Test func writingSessionEmptyCodeHasNoSyntheticInlineRecord() throws {
    let block = try Block(fields: ["id": .string("code"), "type": .string("code"), "code": .string(""), "host": .string("keep")])
    let a = try writing("a", [block]), address = TextAddress("code", path: ["code"])
    try a.replaceText(at: address, range: 0..<0, with: "x")
    #expect(a.document.blocks[0].fields["code"] == .string("x"))
    try a.undo(); #expect(a.document.blocks == [block])
}

@Test(arguments: [false, true]) func writingSessionDeletionCannotCollapseDifferentCutRanks(swap: Bool) throws {
    let blocks = [try paragraph("left", "abcd")]
    let lower = try writing(swap ? "b" : "a", blocks), upper = try writing(swap ? "a" : "b", blocks), remote = try writing("c", blocks)
    try lower.splitParagraph(at: TextAddress("left"), range: 1..<1, newBlockID: "lower")
    try upper.splitParagraph(at: TextAddress("left"), range: 3..<3, newBlockID: "upper")
    try remote.replaceText(at: TextAddress("left"), range: 1..<3, with: "")
    try exchange(lower, upper); try lower.receive(remote.changes()); try upper.receive(remote.changes())
    #expect(lower.document == upper.document)
    #expect(lower.document.blocks.map(\.id) == ["left", "lower", "upper"])
    #expect(lower.document.blocks.map(\.text) == ["a", "", "d"])
}

@Test func writingSessionStoppedAuthorReorderedUndoRedoRestoresWinningHistory() throws {
    let original = try writing("a", [paragraph("left", "ab")])
    try original.replaceText(at: TextAddress("left"), range: 2..<2, with: "X")
    let accepted = try original.save(), stopped = try WritingSession.restore(accepted, actorID: "a")
    try stopped.undo(); let undo = stopped.changes().changes.last!
    try stopped.redo(); let redo = stopped.changes().changes.last!
    let resumed = try WritingSession.restore(accepted, actorID: "a")
    func packet(_ changes: [WritingChange]) -> WritingBatch { WritingBatch(documentID: resumed.documentID, epoch: resumed.epoch, baseline: resumed.baseline, changes: changes) }
    try resumed.receive(packet([redo]))
    try resumed.receive(packet([undo]))
    #expect(resumed.document.blocks[0].text == "abX" && resumed.canUndo && !resumed.canRedo)
    let reopened = try WritingSession.restore(resumed.save(), actorID: "a")
    #expect(reopened.document == resumed.document && reopened.canUndo && !reopened.canRedo)
    try reopened.undo(); #expect(reopened.document.blocks[0].text == "ab")
}
