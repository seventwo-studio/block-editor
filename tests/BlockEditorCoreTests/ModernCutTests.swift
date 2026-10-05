import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernCutTests {
    private func document() throws -> ModernDocument { try ModernDocument(documentID: "cut", title: "Title", blocks: [Block.paragraph(id: "p", text: "ABC"), Block.paragraph(id: "q", text: "Other")]) }
    private func session(_ actor: String = "a", _ d: ModernDocument? = nil) throws -> ModernSession {
        try ModernSession(documentID: (d ?? document()).documentID, actorID: actor, epoch: "cut", document: d ?? document())
    }
    private func node(_ s: ModernSession, _ label: String, path: [String] = []) throws -> NodeID { try s.node(at: NodeAddress(label, path: path)) }
    private func target(_ s: ModernSession) throws -> ModernDeleteTarget {
        try ModernDeleteTarget(ranges: [s.captureTextRange(in: s.field(node: node(s, "p")), start: 2, end: 1)])
    }
    private func unchanged(_ s: ModernSession, _ before: Data, _ receipt: WritingSyncState) throws {
        #expect(try s.save() == before); #expect(s.syncState == receipt)
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let aa = try a.changes(), bb = try b.changes(); try a.receive(bb); try b.receive(aa)
    }
    @Test func publicationFailureOrThrowDoesNotDeleteOrCreateHistoryAndPublisherSeesExactPayloadFirst() throws {
        let s = try session(), target = try target(s), before = try s.save(), receipt = s.syncState
        var calls = 0
        let failure = try s.cut(target) { clipboard in
            calls += 1; #expect(clipboard.plainText == "B"); try unchanged(s, before, receipt); return false
        }
        #expect(calls == 1 && failure.status == "unavailable" && failure.reason == "clipboardPublicationFailed" && failure.retainedClipboard?.plainText == "B")
        try unchanged(s, before, receipt)
        let thrown = try s.cut(target) { _ in calls += 1; throw EditorError.invalidChange }
        #expect(calls == 2 && thrown.status == "unavailable" && thrown.result == nil)
        try unchanged(s, before, receipt)
    }
    @Test func delayedMixedCutPreservesPeerTextAndDeletesOnlyCapturedOriginsInOneGroup() throws {
        let a = try session(), b = try session("b")
        let partial = try target(a), selected = try a.captureNodes([node(a, "q")])
        let preparation = try a.prepareCut(ModernDeleteTarget(nodes: selected, ranges: partial.ranges)), original = try preparation.clipboard.json()
        #expect(preparation.clipboard.plainText == "B\nOther" && !a.canUndo)
        let field = try b.field(node: node(b, "p")); try b.replaceText(in: field, range: 0..<0, with: "R")
        try b.replaceText(in: field, range: 3..<3, with: "X"); try a.receive(b.changes())
        let result = a.finishCut(preparation, published: true)
        #expect(result.status == "applied" && preparation.phase == .applied && result.transaction == preparation.transaction)
        #expect(a.document.blocks.map(\.id) == ["p"] && a.document.blocks[0].text == "RAXC")
        #expect(try preparation.clipboard.json() == original)
        try exchange(a, b); #expect(a.document == b.document)
        try a.undo(); #expect(a.document.blocks.map(\.text) == ["RABXC", "Other"] && !a.canUndo)
        try a.redo(); try exchange(a, b); #expect(a.document == b.document && a.document.blocks[0].text == "RAXC")
    }
    @Test func duplicateDeliveryCannotReenterPublicationOrImplicitlyRedoAfterUndo() throws {
        let s = try session(), preparation = try s.prepareCut(target(s))
        var callback: ModernCutOutcome?
        s.onChange = { _, _ in callback = s.finishCut(preparation, published: true) }
        let result = s.finishCut(preparation, published: true); s.onChange = nil
        #expect(result.status == "applied" && callback?.reason == "cutAlreadyApplying")
        try s.undo(); let before = try s.save(), receipt = s.syncState
        let duplicate = s.finishCut(preparation, published: true)
        #expect(duplicate.status == "noop" && duplicate.reason == "cutAlreadyApplied" && duplicate.result == nil && duplicate.transaction == nil)
        try unchanged(s, before, receipt); #expect(s.document.blocks[0].text == "ABC" && s.canRedo)
        let reopened = try ModernSession.restore(before, actorID: "a")
        #expect(reopened.finishCut(preparation, published: true).reason == "cutSessionChanged")
        try reopened.redo(); #expect(reopened.document.blocks[0].text == "AC")
    }
    @Test func preparationAndDelayedCompletionRecheckPolicyCompositionAndCancellationWithoutPublishingHistory() throws {
        let s = try session(), target = try target(s), before = try s.save(), receipt = s.syncState
        s.allowedCommands = []
        #expect(throws: ModernSessionError.self) { _ = try s.prepareCut(target) }; s.allowedCommands = nil
        let preparation = try s.prepareCut(target)
        s.allowedCommands = []; #expect(s.finishCut(preparation, published: true).reason == "hostPolicy")
        s.allowedCommands = nil; s.isComposing = true; #expect(s.finishCut(preparation, published: true).reason == "compositionActive")
        s.isComposing = false; try unchanged(s, before, receipt)
        #expect(s.finishCut(preparation, published: true).status == "applied")
        let cancelled = try s.prepareCut(ModernDeleteTarget(nodes: s.captureNodes([node(s, "q")])))
        try s.cancelCut(cancelled); let after = try s.save(), afterReceipt = s.syncState
        let late = s.finishCut(cancelled, published: true)
        #expect(late.reason == "cutCancelled" && late.retainedClipboard?.plainText == "Other")
        try unchanged(s, after, afterReceipt)
    }
    @Test func deletedAndReusedSourceLabelOrDifferentSessionCannotRetargetDelayedCut() throws {
        let s = try session(), selected = try s.captureNodes([node(s, "q")]), preparation = try s.prepareCut(ModernDeleteTarget(nodes: selected))
        _ = try s.delete(ModernDeleteTarget(nodes: selected))
        _ = try s.insertBlock(Block.paragraph(id: "q", text: "Replacement"), at: s.captureBoundary())
        let before = try s.save(), receipt = s.syncState
        let result = s.finishCut(preparation, published: true)
        #expect(result.status == "unavailable" && result.retainedClipboard?.plainText == "Other")
        try unchanged(s, before, receipt)
        let other = try session("other"), original = try other.save(), state = other.syncState
        #expect(other.finishCut(preparation, published: true).reason == "cutSessionChanged")
        try unchanged(other, original, state)
    }
    @Test func titleCutSupportsBackwardOverlappingRangesAndPeerTextWithOneReplacementGroup() throws {
        let a = try session(), b = try session("b")
        a.allowedCommands = ["replaceTitle", "undo", "redo"]
        let ranges = try [a.captureTextRange(in: a.titleField, start: 4, end: 1), a.captureTextRange(in: a.titleField, start: 2, end: 5)]
        let preparation = try a.prepareCut(ModernDeleteTarget(ranges: ranges))
        #expect(preparation.clipboard.plainText == "itle")
        try b.replaceText(in: b.titleField, range: 0..<0, with: "Peer "); try a.receive(b.changes())
        let result = a.finishCut(preparation, published: true)
        #expect(result.status == "applied" && a.document.title == "Peer T" && a.document.blocks == b.document.blocks)
        try a.undo(); #expect(a.document.title == "Peer Title" && !a.canUndo)
        try a.redo(); #expect(a.document.title == "Peer T")
        let mixed = try ModernDeleteTarget(nodes: a.captureNodes([node(a, "q")]), ranges: [a.captureTextRange(in: a.titleField, start: 0, end: 1)])
        #expect(throws: EditorError.self) { _ = try a.prepareCut(mixed) }
    }
    @Test func capturedPartialCutFollowsPeerSplitWithoutRemovingUnobservedTailText() throws {
        let a = try session(), b = try session("b"), f = try a.field(node: node(a, "p"))
        let preparation = try a.prepareCut(ModernDeleteTarget(ranges: [a.captureTextRange(in: f, start: 1, end: 3)]))
        _ = try b.splitBlock(in: b.captureTextRange(in: b.field(node: node(b, "p")), start: 2, end: 2), newBlockID: "tail")
        try b.replaceText(in: b.field(node: node(b, "tail")), range: 1..<1, with: "X"); try a.receive(b.changes())
        #expect(a.finishCut(preparation, published: true).status == "applied")
        #expect(a.document.blocks.map(\.text) == ["A", "X", "Other"] && preparation.clipboard.plainText == "BC")
        try exchange(a, b); #expect(a.document == b.document)
        let reopened = try ModernSession.restore(a.save(), actorID: "a"); try reopened.undo()
        #expect(reopened.document.blocks.map(\.text) == ["AB", "CX", "Other"])
        try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func emptyPublicationConsumesItsPreparationAndNeverDeletesLaterPeerInput() throws {
        let s = try session(), field = try s.field(node: node(s, "p")), target = try ModernDeleteTarget(ranges: [s.captureTextRange(in: field, start: 1, end: 1)])
        let preparation = try s.prepareCut(target), before = try s.save(), receipt = s.syncState
        #expect(preparation.clipboard.plainText == "")
        #expect(s.finishCut(preparation, published: true).status == "noop" && preparation.phase == .applied)
        try unchanged(s, before, receipt)
        try s.replaceText(in: field, range: 1..<1, with: "Later"); let after = try s.save(), afterReceipt = s.syncState
        #expect(s.finishCut(preparation, published: true).reason == "cutAlreadyApplied")
        try unchanged(s, after, afterReceipt)
    }

    @Test func wholeLayoutCutKeepsUnobservedPeerChildInItsValidOriginalContainer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let d = try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/columns-3000.json")))
        let a = try session("a", d), b = try session("b", d), layout = try node(a, "layout")
        let preparation = try a.prepareCut(ModernDeleteTarget(nodes: a.captureNodes([layout])))
        let second = try node(b, "layout", path: ["columns", "second-column"]), collection = NodeCollection(owner: second, field: "children")
        _ = try b.insertBlock(Block.paragraph(id: "peer", text: "Peer child"), at: b.captureBoundary(in: collection))
        try a.receive(b.changes())
        #expect(a.finishCut(preparation, published: true).status == "applied")
        var minimal = d.blocks[0].fields, columns = minimal["columns"]!.array!
        for index in columns.indices {
            var value = columns[index].object!
            value["children"] = .array(index == 0 ? [] : [.object(try Block.paragraph(id: "peer", text: "Peer child").fields)])
            columns[index] = .object(value)
        }
        minimal["columns"] = .array(columns)
        let expected = try ModernDocument(documentID: d.documentID, title: d.title, blocks: [Block(fields: minimal), d.blocks[1]])
        #expect(a.document == expected && !preparation.clipboard.plainText.contains("Peer child"))
        try exchange(a, b); #expect(a.document == b.document)
        try a.undo(); #expect(a.document.blocks[0].fields["columns"]!.array![1]["children"]!.array!.contains { $0["id"] == .string("peer") })
        let reopened = try ModernSession.restore(a.save(), actorID: "a"); try reopened.redo(); #expect(reopened.document == expected)
    }
    @Test func pendingRecoveryRetainsPublishedClipboardUntilOriginalCausalHistoryArrives() throws {
        let a = try session(), b = try session("b"), preparation = try a.prepareCut(target(a))
        _ = try b.insertBlock(Block.paragraph(id: "peer", text: "R"), at: b.captureBoundary(after: node(b, "q")))
        try b.replaceText(in: b.field(node: node(b, "peer")), range: 1..<1, with: "!")
        let batch = try b.changes(), before = a.document, receipt = a.syncState
        #expect(throws: ModernSessionError.self) { try a.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [batch.changes[1]])) }
        let failed = a.finishCut(preparation, published: true)
        #expect(failed.status == "recoveryRequired" && failed.retainedClipboard?.plainText == "B" && preparation.phase == .prepared)
        #expect(a.document == before && a.syncState == receipt)
        try a.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [batch.changes[0]]))
        #expect(a.finishCut(preparation, published: true).status == "applied")
        #expect(a.document.blocks.map(\.text) == ["AC", "Other", "R!"] && a.mergeRecovery == nil)
    }
}
