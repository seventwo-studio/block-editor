import Foundation
import Testing
@testable import BlockEditorCore

struct ModernBatchInteractionTests {
    @Test func markerConversionIsOneUndoAndLiteralCodeKeepsWhitespace() throws {
        let s = try ModernSession(documentID: "shortcuts", actorID: "a", epoch: "e", document: ModernDocument(documentID: "shortcuts", blocks: [.paragraph(id: "p", text: "- ")]))
        let field = try s.field(node: s.node(at: NodeAddress("p"))), range = try s.captureTextRange(in: field, start: 2, end: 2)
        let result = try s.typingShortcut(in: range)
        #expect(s.document.blocks[0].fields["type"] == .string("list"))
        guard case .text(let caret) = result.focus else { Issue.record("Missing list input focus"); return }
        #expect(try s.text(in: caret.field).isEmpty)
        try s.undo(); #expect(s.document.blocks[0].text == "- " && s.document.blocks[0].fields["type"] == .string("paragraph"))
        try s.redo(); #expect(s.document.blocks[0].fields["type"] == .string("list"))
        let code = try ModernInsertionCatalog.block("code", id: "c")
        let inserted = try s.insertBlock(code, at: s.captureBoundary(after: s.nodes().last))
        guard case .text(let codeCaret) = inserted.focus else { Issue.record("Missing code focus"); return }
        try s.replaceText(in: codeCaret.field, range: 0..<0, with: "\t# literal\n😀  \n")
        _ = try s.typingShortcut(in: s.captureTextRange(in: codeCaret.field, start: 4, end: 4))
        #expect(try s.text(in: codeCaret.field) == "\t# literal\n😀  \n")
        _ = try s.codeProperties(s.captureCodeTarget(codeCaret.field.node), language: "swift")
        let reopen = try ModernSession.restore(s.save(), actorID: "a")
        #expect(reopen.document.blocks.last?.fields["language"] == .string("swift"))
        try reopen.undo(); #expect(reopen.document.blocks.last?.fields["language"] == nil)
        #expect(try reopen.text(in: codeCaret.field) == "\t# literal\n😀  \n")
    }
    @Test func inlineDelimiterFormattingPreservesUnicodeAndRestoresOriginalSelection() throws {
        let s = try ModernSession(documentID: "inline", actorID: "a", epoch: "e", document: ModernDocument(documentID: "inline", blocks: [.paragraph(id: "p", text: "**😀é**")]))
        let f = try s.field(node: s.node(at: NodeAddress("p"))), length = try s.text(in: f).utf16.count
        _ = try s.typingShortcut(in: s.captureTextRange(in: f, start: length, end: length))
        #expect(try s.text(in: f) == "😀é")
        #expect(try s.markState(in: s.captureTextRange(in: f, start: 0, end: 4), type: "bold") == .on)
        try s.undo(); #expect(try s.text(in: f) == "**😀é**")
        guard case .text(let original) = s.localSelection?.selection else { Issue.record("No original caret"); return }
        #expect(try s.resolve(original.end).offset == length)
    }
    @Test func mediaPropertyUndoKeepsPeerCaptionAndRejectsOldSource() throws {
        let image = try Block(fields: ["id": .string("i"), "type": .string("image"), "src": .string("asset://original"), "caption": .array([]), "vendor": .object(["retain": .bool(true)])])
        let doc = try ModernDocument(documentID: "media", blocks: [image]), a = try ModernSession(documentID: "media", actorID: "a", epoch: "e", document: doc), b = try ModernSession(documentID: "media", actorID: "b", epoch: "e", document: doc)
        let node = try a.node(at: NodeAddress("i")), original = try a.captureMediaTarget(node)
        _ = try a.mediaProperties(original, metadata: ["width": .number(320), "height": .number(160)])
        let caption = try b.field(node: node, name: "caption"); try b.replaceText(in: caption, range: 0..<0, with: "Peer caption")
        try a.receive(b.changes()); try a.undo()
        #expect(try a.text(in: caption) == "Peer caption")
        #expect(a.document.blocks[0].fields["width"] == nil && a.document.blocks[0].fields["vendor"] == image.fields["vendor"])
        _ = try a.mediaProperties(a.captureMediaTarget(node), metadata: ["src": .string("asset://replacement")])
        let before = try a.save()
        #expect(throws: (any Error).self) { try a.mediaProperties(original, metadata: ["alt": .string("stale")]) }
        #expect(try a.save() == before)
    }
    @Test func navigationAndDirectedSpanFollowLogicalColumnsWithoutWriting() throws {
        let layout: JSONValue = try .object(["id": .string("cols"), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array([
            .object(["id": .string("left"), "children": .array([.object(Block.paragraph(id: "a", text: "AB😀").fields)])]),
            .object(["id": .string("right"), "children": .array([.object(Block.paragraph(id: "b", text: "CD").fields)])])])])
        let s = try ModernSession(documentID: "navigation", actorID: "a", epoch: "e", document: ModernDocument(documentID: "navigation", blocks: [Block(fields: layout.object!)])), before = try s.save()
        let fields = try s.logicalFields(includingTitle: false)
        #expect(fields.count == 2)
        let ranges = try s.captureTextSpan(from: s.position(in: fields[1], offset: 1), to: s.position(in: fields[0], offset: 1))
        #expect(ranges.count == 2 && s.syncState.received.isEmpty)
        #expect(try s.save() == before)
        #expect(try s.resolve(ranges[0].start).offset == 4 && s.resolve(ranges[0].end).offset == 1)
        _ = try s.delete(ModernDeleteTarget(ranges: ranges))
        #expect(try s.text(in: fields[0]) == "A" && s.text(in: fields[1]) == "D")
        try s.undo(); #expect(try s.text(in: fields[0]) == "AB😀" && s.text(in: fields[1]) == "CD")
    }
    @Test func directedSpanFormattingIsAtomicAndKeepsLaterPeerText() throws {
        let doc = try ModernDocument(documentID: "span", blocks: [.paragraph(id: "p", text: "A😀B"), .paragraph(id: "q", text: "CDé")])
        let a = try ModernSession(documentID: "span", actorID: "a", epoch: "e", document: doc), b = try ModernSession(documentID: "span", actorID: "b", epoch: "e", document: doc)
        let fields = try a.logicalFields(includingTitle: false)
        let ranges = try a.captureTextSpan(from: a.position(in: fields[1], offset: 2), to: a.position(in: fields[0], offset: 1))
        try b.replaceText(in: fields[0], range: 4..<4, with: "peer")
        try a.receive(b.changes())
        _ = try a.format(in: ranges, markType: "bold", mark: .object(["type": .string("bold")]))
        #expect(try a.markState(in: ranges, type: "bold") == .on)
        #expect(try a.markState(in: a.captureTextRange(in: fields[0], start: 4, end: 8), type: "bold") == .off)
        let restored = try ModernSession.restore(a.save(), actorID: "a")
        try restored.restoreHistorySelection(a.exportHistorySelection())
        try restored.undo()
        #expect(try restored.markState(in: ranges, type: "bold") == .off)
        #expect(try restored.text(in: fields[0]) == "A😀Bpeer")
        guard case .mixed(let original) = restored.localSelection?.selection else { Issue.record("Missing span selection after Undo"); return }
        #expect(original.ranges.count == 2)
        #expect(try restored.resolve(original.ranges[0].start).offset == 4 && restored.resolve(original.ranges[0].end).offset == 1)
        #expect(try restored.resolve(original.ranges[1].start).offset == 2 && restored.resolve(original.ranges[1].end).offset == 0)
        let saved = try restored.save()
        #expect(throws: (any Error).self) { try restored.format(in: [ranges[0], ranges[0]], markType: "bold", mark: nil) }
        #expect(try restored.save() == saved)
    }

    @Test func authorRestrictionsPreserveAdmittedMarksAndPeerBlocks() throws {
        let rich = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Rich"), "marks": .array([.object(["type": .string("bold")])])])])])
        let doc = try ModernDocument(documentID: "policy", blocks: [rich]), a = try ModernSession(documentID: "policy", actorID: "a", epoch: "e", document: doc), b = try ModernSession(documentID: "policy", actorID: "b", epoch: "e", document: doc)
        a.allowedBlockTypes = ["paragraph"]; a.allowedMarkTypes = ["italic"]
        let field = try a.logicalFields(includingTitle: false)[0]
        try a.replaceText(in: field, range: 4..<4, with: "er")
        #expect(try a.markState(in: a.captureTextRange(in: field, start: 0, end: 6), type: "bold") == .on)
        let before = try a.save()
        #expect(throws: (any Error).self) { try a.insertBlock(ModernInsertionCatalog.block("table", id: "denied", childIDs: ["r1", "r2", "c1", "c2", "c3", "c4"]), at: a.captureBoundary()) }
        #expect(try a.save() == before)
        #expect(throws: (any Error).self) { try a.format(in: a.captureTextRange(in: field, start: 0, end: 6), markType: "bold", mark: .object(["type": .string("bold")])) }
        _ = try b.insertBlock(ModernInsertionCatalog.block("heading1", id: "peer"), at: b.captureBoundary())
        try a.receive(b.changes())
        #expect(a.document.blocks.contains { $0.fields["type"] == .string("heading") })
        try a.undo(); #expect(try a.text(in: field) == "Rich")
        #expect(a.document.blocks.contains { $0.fields["type"] == .string("heading") })
    }

}

struct ModernRangeConversionTests {
    @Test func rangeConversionHasUniqueBirthsAndOneUndoPreservingPeerText() throws {
        let doc = try ModernDocument(documentID: "cohort", blocks: [.paragraph(id: "a", text: "Alpha"), .paragraph(id: "b", text: "Beta")])
        let a = try ModernSession(documentID: "cohort", actorID: "a", epoch: "e", document: doc)
        let b = try ModernSession(documentID: "cohort", actorID: "b", epoch: "e", document: doc)
        let selected = try a.captureNodes(a.nodes())
        _ = try a.convertBlocks(selected, to: WritingBlockTarget(type: "list", style: "todo"))
        #expect(a.document.blocks.allSatisfy { $0.fields["type"] == .string("list") })
        let fields = try a.logicalFields(includingTitle: false)
        #expect(fields.count == 2 && fields[0].node != fields[1].node)
        #expect(try a.text(in: fields[0]) == "Alpha" && a.text(in: fields[1]) == "Beta")
        try b.receive(a.changes()); try b.replaceText(in: fields[1], range: 4..<4, with: " peer")
        try a.receive(b.changes()); try a.undo()
        #expect(a.document.blocks.map(\.text) == ["Alpha", "Beta peer"])
        #expect(a.document.blocks.allSatisfy { $0.fields["type"] == .string("paragraph") })
        try a.redo(); #expect(try a.text(in: fields[1]) == "Beta peer")
        #expect(try ModernSession.restore(a.save(), actorID: "a").document == a.document)
    }
    @Test func oneLossyMemberRejectsCompleteRangeWithoutWriting() throws {
        let rich = try Block(fields: ["id": .string("rich"), "type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Keep"), "marks": .array([.object(["type": .string("bold")])])])])])
        let s = try ModernSession(documentID: "lossless", actorID: "a", epoch: "e", document: ModernDocument(documentID: "lossless", blocks: [.paragraph(id: "plain", text: "Literal"), rich]))
        let before = try s.save()
        #expect(throws: (any Error).self) { try s.convertBlocks(s.captureNodes(s.nodes()), to: WritingBlockTarget(type: "code")) }
        #expect(try s.save() == before && !s.canUndo)
    }
}
