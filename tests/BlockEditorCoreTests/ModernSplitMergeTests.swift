@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernSplitMergeTests {
    private func fixture(_ name: String) throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func session(_ actor: String, _ name: String = "unicode") throws -> ModernSession {
        let doc = try fixture(name)
        return try ModernSession(documentID: doc.documentID, actorID: actor, epoch: "cuts", document: doc)
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }
    private func field(_ a: ModernSession, _ address: NodeAddress = NodeAddress("A")) throws -> WritingField {
        try a.field(node: a.node(at: address))
    }
    @Test func retainedSuffixCaretAndPeerReplacementFollowSplitUndoRedoAndReopen() throws {
        let a = try session("a"), b = try session("b"), source = try field(a)
        let original = try a.position(in: source, offset: 2)
        let outcome = try a.splitBlock(in: a.captureTextRange(in: source, start: 1, end: 1), newBlockID: "tail")
        guard case .text(let caret) = outcome.focus else { Issue.record("Missing split caret"); return }
        let tail = try field(a, NodeAddress("tail"))
        #expect(try a.text(in: source) == "A" && a.text(in: tail) == "BC")
        #expect(try a.resolve(original).address.identity == tail.node && a.resolve(original).offset == 1)
        #expect(try a.resolve(caret).offset == 0)
        try b.receive(a.changes())
        try b.replaceText(in: b.captureTextRange(in: tail, start: 0, end: 1), with: "X")
        try exchange(a,b); #expect(try a.text(in: tail) == "XC")
        try a.undo(); #expect(try a.text(in: source) == "AXC")
        #expect(try a.resolve(original).address.identity == source.node && a.resolve(original).offset == 2)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.redo(); #expect(try reopened.text(in: tail) == "XC")
        try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    }
    @Test func concurrentCutsPartitionSuffixInTextOrderAndEachAuthorUndoRetainsOtherCut() throws {
        for reverse in [false,true] {
            let a = try session(reverse ? "z" : "a"), b = try session(reverse ? "a" : "z"), f = try field(a)
            _ = try a.splitBlock(in: a.captureTextRange(in: f, start: 1, end: 1), newBlockID: "first")
            _ = try b.splitBlock(in: b.captureTextRange(in: f, start: 2, end: 2), newBlockID: "second")
            try exchange(a,b)
            #expect(a.document.blocks.prefix(3).map(\.id) == ["A","first","second"] && a.document == b.document)
            #expect(try a.text(in: field(a, NodeAddress("first"))) == "B")
            #expect(try a.text(in: field(a, NodeAddress("second"))) == "C")
            try a.undo(); #expect(try a.text(in: f) == "AB" && a.text(in: field(a, NodeAddress("second"))) == "C")
            try exchange(a,b); try b.undo(); try exchange(a,b)
            #expect(a.document == (try fixture("unicode")) && a.document == b.document)
        }
    }
    @Test func emptySplitHeadReturnsToExactRetainedBoundaryOnUndoIncludingPeerPrefixAndReopen() throws {
        let a = try session("a"), b = try session("b"), f = try field(a)
        let result = try a.splitBlock(in: a.captureTextRange(in: f, start: 3, end: 3), newBlockID: "tail")
        guard case .text(let head) = result.focus else { Issue.record("Missing head"); return }
        #expect(head.anchor == nil)
        try b.receive(a.changes()); try b.replaceText(in: f, range: 0..<0, with: "L")
        try a.receive(b.changes()); try a.undo()
        #expect(try a.resolve(head).address.identity == f.node && a.resolve(head).offset == 4)
        let reopened = try ModernSession.restore(a.save(), actorID:"a")
        #expect(try reopened.resolve(head).offset == 4)
        try reopened.redo(); #expect(try reopened.resolve(head).address.identity == head.field.node && reopened.resolve(head).offset == 0)
    }
    @Test func splitKeepsHeadingSourceMetadataRichReferencesAndAtomicBoundaries() throws {
        let a = try session("a","mixed"), f = try field(a), original = a.document.blocks[0]
        _ = try a.convertBlock(in: a.captureTextRange(in:f,start:0,end:0), to: WritingBlockTarget(type:"heading",level:2))
        _ = try a.splitBlock(in: a.captureTextRange(in:f,start:11,end:11),newBlockID:"tail")
        #expect(a.document.blocks[0].type == "heading" && a.document.blocks[0].fields["level"] == .number(2))
        #expect(a.document.blocks[0].fields["consumer"] == original.fields["consumer"])
        #expect(a.document.blocks[1].fields["content"]?.array?.first == original.fields["content"]?.array?[2])
        try a.undo(); try a.undo(); #expect(a.document == (try fixture("mixed")))
        let saved = try a.save()
        #expect(throws: EditorError.invalidRange) { try a.splitBlock(in:a.captureTextRange(in:f,start:13,end:13),newBlockID:"bad") }
        #expect(try a.save() == saved)
    }
    @Test func nestedChecklistSplitRetainsParentChildrenAndResetsNewItemCheckedState() throws {
        let a = try session("a","mixed"), address = NodeAddress("toggle",path:["children","todo","items","same"]), f = try field(a,address)
        let original = a.document
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:5,end:5),newBlockID:"next")
        let items = a.document.blocks[1].fields["children"]?.array?[1]["items"]?.array ?? []
        #expect(items.count == 2 && items[0]["children"] == original.blocks[1].fields["children"]?.array?[1]["items"]?.array?[0]["children"])
        #expect(items[1]["checked"] == .bool(false) && items[1]["children"] == .array([]))
        #expect(try a.text(in:field(a,NodeAddress("toggle",path:["children","todo","items","next"]))) == " this")
        try a.undo(); #expect(a.document == original)
    }
    @Test func splitAfterColumnRemovalAndUndoKeepsLogicalOriginRoutes() throws {
        let a = try session("a","columns-3000")
        _ = try a.removeColumns(ModernColumnTarget(layout: a.node(at:NodeAddress("layout"))))
        let f = try field(a,NodeAddress("A")), length = try a.text(in:f).utf16.count
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:length,end:length),newBlockID:"tail")
        #expect(a.document.blocks.prefix(2).map(\.id) == ["A","tail"])
        try a.undo(); try a.undo(); #expect(a.document == (try fixture("columns-3000")))
    }
    @Test func concurrentColumnCutsRemainReachableAfterFlatteningUndoAndRejoin() throws {
        let a = try session("a","columns-3000"), b = try session("b","columns-3000")
        let address = NodeAddress("layout",path:["columns","first-column","children","A"]), f = try field(a,address)
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:1,end:1),newBlockID:"first-tail")
        _ = try b.splitBlock(in:b.captureTextRange(in:f,start:2,end:2),newBlockID:"second-tail")
        try exchange(a,b)
        let grouped = a.document
        _ = try a.removeColumns(ModernColumnTarget(layout:a.node(at:NodeAddress("layout"))))
        #expect(a.document.blocks.prefix(3).map(\.id) == ["A","first-tail","second-tail"])
        try b.receive(a.changes()); #expect(b.document == a.document)
        try a.undo(); #expect(a.document == grouped)
        try exchange(a,b); #expect(a.document == b.document)
    }
    @Test func mergeRetainsRightPeerAtomsAndAnchorsAcrossUndoReopen() throws {
        let a = try session("a"), b = try session("b"), left = try a.node(at:NodeAddress("A")), right = try a.node(at:NodeAddress("unicode"))
        let rightField = try a.field(node:right), caret = try a.position(in:rightField,offset:2)
        _ = try a.mergeBlocks(a.captureNodes([left,right]))
        #expect(try a.resolve(caret).address.identity == left && a.resolve(caret).offset == 5)
        try b.replaceText(in:rightField,range:0..<0,with:"peer "); try exchange(a,b)
        #expect(a.document == b.document && a.document.blocks.count == 2)
        try a.undo(); #expect(try a.text(in:rightField).hasPrefix("peer "))
        #expect(try a.resolve(caret).address.identity == right && a.resolve(caret).offset == 7)
        let reopened = try ModernSession.restore(a.save(),actorID:"a"); try reopened.redo(); #expect(reopened.document.blocks.count == 2)
    }
    @Test func incompatibleMergePolicyTitleAndForgedCutProofRejectWithoutHistoryChanges() throws {
        let a = try session("a","mixed"), saved = try a.save(), f = try field(a)
        #expect(throws: EditorError.self) { try a.mergeBlocks(a.captureNodes([a.node(at:NodeAddress("A")),a.node(at:NodeAddress("toggle"))])) }
        #expect(throws: EditorError.self) { try a.splitBlock(in:a.captureTextRange(in:a.titleField,start:1,end:1),newBlockID:"bad") }
        a.allowedCommands = ["replaceText"]
        #expect(throws: ModernSessionError.unavailable("hostPolicy")) { try a.splitBlock(in:a.captureTextRange(in:f,start:1,end:1),newBlockID:"bad") }
        a.allowedCommands = nil; #expect(try a.save() == saved)
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:0,end:0),newBlockID:"tail")
        try a.undo() // Deactivation cannot hide an invalid retained cut proof.
        let packet = try a.changes(), b = try session("b","mixed"), original = try b.save()
        var json = try JSONDecoder().decode(JSONValue.self,from:packet.json())
        var fields = json.object!, changes = fields["changes"]!.array!, change = changes[0].object!, body = change["body"]!.object!, edit = body["edit"]!.object!, ops = edit["_0"]!.array!
        var operation = ops[0].object!, split = operation["splitBlock"]!.object!, payload = split["_0"]!.object!
        payload["suffix"] = .array([]); split["_0"] = .object(payload); operation["splitBlock"] = .object(split); ops[0] = .object(operation)
        edit["_0"] = .array(ops); body["edit"] = .object(edit); change["body"] = .object(body); changes[0] = .object(change); fields["changes"] = .array(changes); json = .object(fields)
        let forged = try ModernBatch(json: canonicalEncoder().encode(json))
        #expect(throws: EditorError.invalidChange) { try b.receive(forged) }; #expect(try b.save() == original)
    }
    @Test func capturedCaretRebasesThroughObservedPeerCutBeforeSecondSplit() throws {
        let a = try session("a"), b = try session("b"), f = try field(a)
        let captured = try a.captureTextRange(in:f,start:2,end:2)
        _ = try b.splitBlock(in:b.captureTextRange(in:f,start:1,end:1),newBlockID:"peer-tail")
        try a.receive(b.changes())
        _ = try a.splitBlock(in:captured,newBlockID:"tail")
        #expect(a.document.blocks.prefix(3).map(\.id) == ["A","peer-tail","tail"])
        #expect(try a.text(in:field(a,NodeAddress("peer-tail"))) == "B" && a.text(in:field(a,NodeAddress("tail"))) == "C")
        try exchange(a,b); #expect(a.document == b.document)
        try a.undo(); #expect(try a.text(in:field(a,NodeAddress("peer-tail"))) == "BC")
    }
    @Test func joinedSourceInputUsesCapturedAtomsAndRejectsUnrelatedFieldAnchor() throws {
        let a = try session("a"), left = try field(a), right = try field(a,NodeAddress("unicode"))
        let captured = try a.captureTextRange(in:right,start:0,end:2)
        _ = try a.mergeBlocks(a.captureNodes([left.node,right.node]))
        try a.replaceText(in:captured,with:"X")
        #expect(try a.text(in:left).hasPrefix("ABCX "))
        let genuine = try a.position(in:left,offset:1), unrelated = try field(a,NodeAddress("rtl"))
        let forged = WritingPosition(documentID:a.documentID,epoch:a.epoch,field:unrelated,anchor:genuine.anchor,affinity:genuine.affinity)
        #expect(throws: EditorError.invalidChange) { try a.resolve(forged) }
        try a.undo(); try a.undo(); #expect(a.document == (try fixture("unicode")))
    }
    @Test func emptyHeadTraversesMultipleRetiredSplitsButExplicitDeletionDoesNotRetarget() throws {
        let a = try session("a"), f = try field(a)
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:3,end:3),newBlockID:"first")
        let first = try field(a,NodeAddress("first"))
        let result = try a.splitBlock(in:a.captureTextRange(in:first,start:0,end:0),newBlockID:"second")
        guard case .text(let head) = result.focus else { Issue.record("Missing head"); return }
        try a.undo(); try a.undo(); #expect(try a.resolve(head).address.identity == f.node && a.resolve(head).offset == 3)
        try a.redo(); try a.redo(); try a.delete(head.field.node)
        #expect(throws: EditorError.self) { try a.resolve(head) }
    }
    @Test func nestedEmptyChecklistEnterOutdentsAndRetainsHistory() throws {
        let a = try session("a","mixed"), f = try field(a,NodeAddress("toggle",path:["children","todo","items","same"]))
        try a.replaceText(in:f,range:0..<10,with:"")
        _ = try a.splitBlock(in:a.captureTextRange(in:f,start:0,end:0),newBlockID:"unused")
        try a.undo()
        // A nested item outdents while retaining its origin and child history.
        let nested = try field(a,NodeAddress("toggle",path:["children","todo","items","same","children","child"]))
        try a.replaceText(in:nested,range:0..<11,with:"")
        let before = a.document
        _ = try a.splitBlock(in:a.captureTextRange(in:nested,start:0,end:0),newBlockID:"unused")
        #expect(try a.node(at:NodeAddress("toggle",path:["children","todo","items","child"])) == nested.node)
        let reopened = try ModernSession.restore(a.save(),actorID:"a")
        try reopened.undo(); #expect(reopened.document == before)
        try reopened.redo(); #expect(reopened.document == a.document)
    }
}
