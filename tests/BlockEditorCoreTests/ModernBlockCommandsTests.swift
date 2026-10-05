@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernBlockCommandsTests {
    private func fixture(_ name: String) throws -> ModernDocument {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/acceptance/modern-editor/documents/" + name + ".json")
        return try ModernDocument(json: Data(contentsOf: path))
    }
    private func session(_ actor: String, name: String = "unicode", document: ModernDocument? = nil) throws -> ModernSession {
        let doc = try document ?? fixture(name)
        return try ModernSession(documentID: doc.documentID, actorID: actor, epoch: "modern-1", document: doc)
    }
    private func aField(_ a: ModernSession) throws -> WritingField { try a.field(node: a.node(at: NodeAddress("A"))) }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }
    @Test func sameContentConversionMatchesIndependentConcurrentSuffixFixturesThroughUndoReopenAndDuplicatePackets() throws {
        for peerFirst in [false, true] {
            let a = try session("a"), b = try session("b"), field = try aField(a)
            let captured = try a.captureTextRange(in: field, start: 3, end: 3)
            try b.replaceText(in: field, range: 3..<3, with: " remote")
            if peerFirst { try a.receive(b.changes()) }
            let outcome = try a.convertBlock(in: captured, to: WritingBlockTarget(type: "heading", level: 2))
            #expect(outcome.focus == .text(captured.start))
            try exchange(a, b); #expect(a.document == (try fixture("unicode-peer-heading")) && a.document == b.document)
            #expect(try a.resolve(captured.start).offset == 3)
            let reopened = try ModernSession.restore(a.save(), actorID: "a")
            #expect(try reopened.resolve(captured.start).offset == 3)
            try reopened.undo(); #expect(reopened.document == (try fixture("unicode-peer-suffix")))
            try reopened.redo(); #expect(reopened.document == (try fixture("unicode-peer-heading")))
            let saved = try reopened.save(); try reopened.receive(b.changes()); #expect(try reopened.save() == saved)
        }
    }
    @Test func conversionPreservesRichReferenceOpaqueFieldsAndCaretInsideAtomicLabel() throws {
        let a = try session("a", name: "mixed"), original = a.document.blocks[0].fields, field = try aField(a)
        let caret = try a.captureTextRange(in: field, start: 13, end: 13) // Inside 世界😀 after its two CJK scalars.
        let outcome = try a.convertBlock(in: caret, to: WritingBlockTarget(type: "callout", variant: "warning"))
        #expect(outcome.focus == .text(caret.start))
        #expect(try a.resolve(caret.start).offset == 13)
        #expect(a.document.blocks[0].fields["content"] == original["content"] && a.document.blocks[0].fields["consumer"] == original["consumer"])
        #expect(a.document.blocks[0].type == "callout")
        try a.undo(); #expect(a.document == (try fixture("mixed")))
    }
    @Test func listStyleConversionKeepsNestedChecklistOriginsStateAndFieldCaret() throws {
        let a = try session("a", name: "nested"), original = a.document.blocks[1].fields
        let item = try a.node(at: NodeAddress("list", path: ["items", "same", "children", "child"]))
        let field = try a.field(node: item), target = try a.captureTextRange(in: field, start: 0, end: 0)
        _ = try a.convertBlock(in: target, to: WritingBlockTarget(type: "list", style: "todo"))
        #expect(try a.node(at: NodeAddress("list", path: ["items", "same", "children", "child"])) == item)
        #expect(a.document.blocks[1].fields["items"] == original["items"] && a.document.blocks[1].fields["style"] == .string("todo"))
        try a.undo(); #expect(a.document == (try fixture("nested")))
    }
    @Test func concurrentHeadingRegisterUndoRevealsPeerValueInsteadOfOverwritingIt() throws {
        let a = try session("a"), b = try session("b"), field = try aField(a)
        _ = try a.convertBlock(in: a.captureTextRange(in: field, start: 1, end: 1), to: WritingBlockTarget(type: "heading", level: 1))
        _ = try b.convertBlock(in: b.captureTextRange(in: field, start: 1, end: 1), to: WritingBlockTarget(type: "heading", level: 3))
        try exchange(a, b); #expect(a.document.blocks[0].fields["level"] == .number(3) && a.document == b.document)
        try b.undo(); try exchange(a, b); #expect(a.document.blocks[0].fields["level"] == .number(1))
        try a.undo(); try exchange(a, b); #expect(a.document == (try fixture("unicode")) && a.document == b.document)
    }
    @Test func unchangedConversionAndLossyOrInvalidTargetsDoNotChangeSavedHistory() throws {
        var fields = try fixture("unicode").fields
        var block = fields["blocks"]!.array![0].object!; block["level"] = .string("consumer-owned")
        var blocks = fields["blocks"]!.array!; blocks[0] = .object(block); fields["blocks"] = .array(blocks)
        let a = try session("a", document: ModernDocument(fields: fields)), field = try aField(a), target = try a.captureTextRange(in: field, start: 0, end: 0), saved = try a.save()
        _ = try a.convertBlock(in: target, to: WritingBlockTarget(type: "paragraph")); #expect(try a.save() == saved)
        #expect(throws: EditorError.self) { try a.convertBlock(in: target, to: WritingBlockTarget(type: "heading", level: 2)) }
        #expect(throws: EditorError.self) { try a.convertBlock(in: target, to: WritingBlockTarget(type: "paragraph", style: "todo")) }
        #expect(throws: EditorError.self) { try a.convertBlock(in: a.captureTextRange(in: field, start: 0, end: 1), to: WritingBlockTarget(type: "quote")) }
        #expect(throws: ModernSessionError.unavailable("schemaConversionPending")) { try a.convertBlock(in: target, to: WritingBlockTarget(type: "code")) }
        #expect(try a.save() == saved)
    }
    @Test func softBreakMatchesIndependentFixtureAndSharesOneUndoWithPeerSafeCapturedReplacement() throws {
        let a = try session("a"), b = try session("b"), field = try aField(a)
        let caret = try a.softBreak(in: a.captureTextRange(in: field, start: 1, end: 1))
        #expect(a.document == (try fixture("unicode-soft-break")) && a.syncState.received.count == 1)
        #expect(try a.resolve(caret).offset == 2)
        try a.undo(); #expect(a.document == (try fixture("unicode")))
        let range = try a.captureTextRange(in: field, start: 1, end: 3)
        try b.replaceText(in: field, range: 2..<2, with: " peer ")
        try a.receive(b.changes()); _ = try a.softBreak(in: range)
        #expect(try a.text(in: field).contains(" peer "))
        #expect(try a.text(in: field).contains("\n"))
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); #expect(try reopened.text(in: field) == "AB peer C")
    }
    @Test func distinctCommandPolicyCompositionAndTitleRejectWithoutMutatingHistory() throws {
        let a = try session("a"), field = try aField(a), target = try a.captureTextRange(in: field, start: 1, end: 1)
        a.allowedCommands = ["softBreak", "undo", "redo"]
        _ = try a.softBreak(in: target); try a.undo()
        let saved = try a.save()
        #expect(throws: ModernSessionError.unavailable("hostPolicy")) { try a.convertBlock(in: target, to: WritingBlockTarget(type: "heading")) }
        a.isComposing = true
        #expect(throws: ModernSessionError.compositionActive) { try a.softBreak(in: target) }
        a.isComposing = false
        #expect(throws: EditorError.self) { try a.softBreak(in: a.captureTextRange(in: a.titleField, start: 0, end: 0)) }
        #expect(try a.save() == saved)
    }
    @Test func malformedInactiveConversionRejectsBeforeMissingCausalRecovery() throws {
        let a = try session("a"), bad = ChangeID(counter: 2, actor: "peer"), absent = ChangeID(counter: 1, actor: "peer")
        let malformed = ModernChange(id: bad, observed: [absent], body: .edit([.convertBlock(node: .baseline(blockID: "A", path: []), type: "heading", attributes: ["level": .number(4)])]))
        let disabled = ModernChange(id: ChangeID(counter: 3, actor: "peer"), observed: [bad], body: .setActive(targets: [bad], active: false))
        let saved = try a.save(), receipt = a.syncState
        #expect(throws: EditorError.self) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [malformed, disabled])) }
        #expect(try a.save() == saved); #expect(a.syncState == receipt && a.mergeRecovery == nil)
    }
}
