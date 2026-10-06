import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernClipboardTests {
    private func fixture(_ name: String = "mixed") throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func session(_ actor: String = "a", document: ModernDocument? = nil) throws -> ModernSession {
        let d = try document ?? fixture()
        return try ModernSession(documentID: d.documentID, actorID: actor, epoch: "clipboard", document: d)
    }
    private func node(_ s: ModernSession, _ id: String, path: [String] = []) throws -> NodeID { try s.node(at: NodeAddress(id, path: path)) }
    private func copy(_ s: ModernSession, _ ids: [String]) throws -> ModernClipboard {
        try s.copyClipboard(ModernDeleteTarget(nodes: s.captureNodes(ids.map { try node(s, $0) })))
    }
    private func reject(_ s: ModernSession, _ action: () throws -> Void) throws {
        let before = try s.save(), state = s.syncState
        do { try action(); Issue.record("Expected unchanged rejection") } catch {}
        #expect(try s.save() == before && s.syncState == state && s.mergeRecovery == nil)
    }

    @Test func mixedWholeAndBackwardPartialCopyHasLiteralOrderAndLeavesHistoryFocusUntouched() throws {
        let s = try session(), a = try s.field(node: node(s, "A")), selected = try s.captureTextRange(in: a, start: 5, end: 0)
        let target = try ModernDeleteTarget(nodes: s.captureNodes([node(s, "toggle")]), ranges: [selected])
        let before = try s.save(), state = s.syncState, value = try s.copyClipboard(target)
        #expect(value.version == 2 && value.collaborationVersion == 7 && value.parts.count == 2)
        #expect(value.plainText == "Bold \nDetails\nNested paragraph\nCheck this\nNested task")
        guard case .inline(let rich) = value.parts[0], case .node(let whole, let kind) = value.parts[1] else { Issue.record("Expected ordered mixed copy"); return }
        #expect(BlockEditorCore.plainText(rich) == "Bold " && rich.allSatisfy { $0["marks"] == .array([.object(["type": .string("bold")])]) })
        #expect(kind == "block" && whole == .object(s.document.blocks[1].fields))
        #expect(try s.save() == before && s.syncState == state && !s.canUndo && !s.canRedo)
        #expect(try ModernClipboard(json: value.json()) == value)
    }
    @Test func hiddenToggleAndTwoColumnsCopyAllContentSplitAndOpaqueMetadataInLogicalOrder() throws {
        var fields = try fixture().fields
        let p: JSONValue = .object(["id": .string("same"), "type": .string("paragraph"), "content": .array([textNode("右😀")]), "consumer": .object(["id": .string("opaque"), "children": .array([.object(["id": .string("do-not-traverse")])])])])
        let layout: JSONValue = .object(["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(6200), "consumer": .object(["closed": .bool(true)]), "columns": .array([
            .object(["id": .string("left"), "consumer": .string("column metadata"), "children": .array([.object(["id": .string("same"), "type": .string("paragraph"), "content": .array([textNode("左")])])])]),
            .object(["id": .string("right"), "children": .array([p])])])])
        fields["blocks"] = .array(fields["blocks"]!.array! + [layout])
        let s = try session(document: ModernDocument(fields: fields)), value = try copy(s, ["toggle", "layout"])
        #expect(value.plainText == "Details\nNested paragraph\nCheck this\nNested task\n左\n右😀")
        #expect(value.parts[1] == .node(value: layout, kind: "block"))
        try value.validateForPaste()
        do { try value.validateForPaste(policy: WritingPastePolicy(allowedBlockTypes: ["paragraph", "toggle", "list"])); Issue.record("Columns need explicit policy availability") } catch {}
    }
    @Test func capturedAtomsFollowPeerSplitsWhileUnobservedPeerTextAndOverlappingRangesDoNotDuplicate() throws {
        let d = try ModernDocument(documentID: "clipboard", blocks: [Block.paragraph(id: "p", text: "abcd")])
        let a = try session(document: d), b = try session("b", document: d), f = try a.field(node: node(a, "p"))
        let range = try a.captureTextRange(in: f, start: 4, end: 0)
        let bf = try b.field(node: node(b, "p")); _ = try b.splitBlock(in: b.captureTextRange(in: bf, start: 2, end: 2), newBlockID: "tail")
        let tail = try b.field(node: node(b, "tail")); try b.replaceText(in: tail, range: 0..<0, with: "peer "); try a.receive(b.changes())
        let before = try a.save(), value = try a.copyClipboard(ModernDeleteTarget(ranges: [range, range]))
        #expect(value.plainText == "ab\ncd" && value.parts.count == 2 && !value.plainText.contains("peer"))
        #expect(try a.save() == before)
        _ = try b.delete(ModernDeleteTarget(nodes: b.captureNodes([node(b, "tail")]))); try a.receive(b.changes())
        // A stale endpoint now fails instead of resolving through a reused label.
        try reject(a) { _ = try a.copyClipboard(ModernDeleteTarget(ranges: [range])) }
    }
    @Test func sameFieldPeerInsertionDoesNotInventAParagraphBreakInCapturedCopy() throws {
        let d = try ModernDocument(documentID: "clipboard", blocks: [Block.paragraph(id: "p", text: "abcd")])
        let a = try session(document: d), b = try session("b", document: d), f = try a.field(node: node(a, "p"))
        let range = try a.captureTextRange(in: f, start: 1, end: 3)
        try b.replaceText(in: b.field(node: node(b, "p")), range: 2..<2, with: "X"); try a.receive(b.changes())
        let value = try a.copyClipboard(ModernDeleteTarget(ranges: [range]))
        #expect(value.plainText == "bc" && value.parts.count == 1)
    }
    @Test func wholeSubtreeCopySuppressesRedundantPartialRangesAndTracksCurrentMaterialization() throws {
        let a = try session(), b = try session("b"), selected = try a.captureNodes([node(a, "toggle")])
        let child = try a.field(node: node(a, "toggle", path: ["children", "child"])), range = try a.captureTextRange(in: child, start: 0, end: 6)
        try b.replaceText(in: b.field(node: node(b, "toggle", path: ["children", "child"])), range: 0..<0, with: "peer "); try a.receive(b.changes())
        let value = try a.copyClipboard(ModernDeleteTarget(nodes: selected, ranges: [range]))
        #expect(value.parts.count == 1 && value.plainText == "Details\npeer Nested paragraph\nCheck this\nNested task")
        try b.replaceText(in: b.field(node: node(b, "toggle", path: ["children", "child"])), range: 0..<0, with: "later "); try a.receive(b.changes())
        let later = try a.copyClipboard(ModernDeleteTarget(nodes: selected))
        #expect(!value.plainText.contains("later") && value != later)
    }
    @Test func modernMarksReferencesAndOpaqueNodeDataRemainExactWithSeparatePastePolicy() throws {
        let role: JSONValue = .object(["type": .string("semantic-color"), "value": .string("green")])
        let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("consumer:ID"), "entityType": .string("page"), "label": .string("世界😀"), "marks": .array([.object(["type": .string("consumer-mark")])]), "consumer": .object(["id": .string("keep")])])
        let clipboard = try ModernClipboard(parts: [.inline([textNode("A", marks: [role]), reference])])
        #expect(clipboard.plainText == "A世界😀")
        try clipboard.validateForPaste(); #expect(try ModernClipboard(json: clipboard.json()) == clipboard)
        do { try clipboard.validateForPaste(policy: WritingPastePolicy(allowedMarkTypes: ["bold"])); Issue.record("Expected explicit mark policy rejection") } catch {}
        let opaque = try copy(session(), ["opaque"])
        #expect(opaque.plainText == "")
        do { try opaque.validateForPaste(); Issue.record("Copy must not implicitly authorize unknown blocks") } catch {}
        #expect(try ModernClipboard(json: opaque.json()) == opaque)
    }
    @Test func modernItemRowCellPayloadsValidateSemanticMarksWithoutLegacyAdmission() throws {
        let role: JSONValue = .object(["type": .string("semantic-background"), "value": .string("amber")])
        let content: JSONValue = .array([textNode("row😀", marks: [role])])
        let cell: JSONValue = .object(["id": .string("c"), "content": content, "consumer": .string("keep")])
        let row: JSONValue = .object(["id": .string("r"), "cells": .array([cell, .object(["id": .string("empty"), "content": .array([])])])])
        let item: JSONValue = .object(["id": .string("i"), "content": content, "children": .array([.object(["id": .string("n"), "content": .array([textNode("nested")])])])])
        let value = try ModernClipboard(parts: [.node(value: item, kind: "item"), .node(value: row, kind: "row"), .node(value: cell, kind: "cell")])
        #expect(value.plainText == "row😀\nnested\nrow😀\t\nrow😀")
        try value.validateForPaste(); #expect(try ModernClipboard(json: value.json()) == value)
    }
    @Test func copiedFilesAndPreviewsRemainInertAndRequireExplicitSafeMetadataPermission() throws {
        let file: JSONValue = .object(["id": .string("f"), "type": .string("file"), "src": .string("asset://consumer/doc.pdf"), "name": .string("資料😀.pdf"), "size": .number(12), "consumer": .object(["pending": .bool(true)])])
        let embed: JSONValue = .object(["id": .string("e"), "type": .string("embed"), "url": .string("https://example.org/a"), "thumbnail": .string("asset://consumer/thumb"), "title": .string("Preview")])
        let value = try ModernClipboard(parts: [.node(value: file, kind: "block"), .node(value: embed, kind: "block")])
        #expect(value.plainText == "資料😀.pdf\nhttps://example.org/a")
        do { try value.validateForPaste(); Issue.record("Expected denied asset metadata") } catch {}
        try value.validateForPaste(policy: WritingPastePolicy(allowAssetMetadata: true))
        var bad = file.object!; bad["src"] = .string("javascript:alert(1)")
        let unsafe = try ModernClipboard(parts: [.node(value: .object(bad), kind: "block")])
        do { try unsafe.validateForPaste(policy: WritingPastePolicy(allowAssetMetadata: true)); Issue.record("Expected unsafe asset rejection") } catch {}
        #expect(value.parts[0] == .node(value: file, kind: "block"))
    }
    @Test func readOnlyCopyWorksUnderCompositionAndAuthoringPolicyButTitleCannotMixWithBody() throws {
        let s = try session(), title = try s.captureTextRange(in: s.titleField, start: 0, end: 5)
        s.allowedCommands = []; s.isComposing = true
        let before = try s.save(), value = try s.copyClipboard(ModernDeleteTarget(ranges: [title]))
        #expect(value.plainText == "Field")
        #expect(try s.save() == before)
        #expect(try copy(s, ["A"]).plainText == "Bold italic世界😀 link")
        try reject(s) { _ = try s.copyClipboard(ModernDeleteTarget(nodes: s.captureNodes([node(s, "A")]), ranges: [title])) }
        let empty = try s.captureTextRange(in: s.titleField, start: 0, end: 0)
        #expect(try s.copyClipboard(ModernDeleteTarget(ranges: [empty])).parts == [.inline([])])
    }
    @Test func versionUnknownFieldsDuplicateKeysFallbackMismatchAndNestedLayoutReject() throws {
        let value = try ModernClipboard.multiline("a\r\n\r\n")
        #expect(value.plainText == "a\n\n" && value.parts.count == 3)
        #expect(try ModernClipboard.plain("a\rb").plainText == "a\nb")
        var wire = try JSONDecoder().decode(JSONValue.self, from: value.json()).object!
        for (key, replacement) in [("version", JSONValue.number(1)), ("collaborationVersion", .number(6)), ("plainText", .string("forged")), ("unknown", .bool(true))] {
            var invalid = wire; invalid[key] = replacement
            do { _ = try ModernClipboard(json: canonicalEncoder().encode(invalid)); Issue.record("Expected invalid clipboard rejection") } catch {}
        }
        let raw = String(decoding: try value.json(), as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"version\":2")
        do { _ = try ModernClipboard(json: Data(raw.utf8)); Issue.record("Expected duplicate-key rejection") } catch {}
        // A decoded modern payload cannot pass the legacy clipboard validator.
        let legacy = try JSONDecoder().decode(WritingClipboard.self, from: value.json())
        do { try legacy.validate(policy: WritingPastePolicy(), hostBlockTypes: nil); Issue.record("Expected modern/legacy separation") } catch {}
        wire["parts"] = .array([])
        do { _ = try ModernClipboard(json: canonicalEncoder().encode(wire)); Issue.record("Expected empty fragment rejection") } catch {}
        let columns: JSONValue = .object(["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array([.object(["id": .string("a"), "children": .array([])]), .object(["id": .string("b"), "children": .array([])])])])
        var outer = columns.object!; outer["columns"] = .array([.object(["id": .string("a"), "children": .array([columns])]), .object(["id": .string("b"), "children": .array([])])])
        do { _ = try ModernClipboard(parts: [.node(value: .object(outer), kind: "block")]); Issue.record("Expected nested-layout rejection") } catch {}
    }
    @Test func malformedNodeKindsDepthAndFutureScopeRejectWithoutHistoryMutation() throws {
        let s = try session(), field = try s.field(node: node(s, "A")), range = try s.captureTextRange(in: field, start: 0, end: 4)
        let foreign = ModernTextRange(start: WritingPosition(documentID: "foreign", epoch: range.start.epoch, field: field, anchor: range.start.anchor, affinity: range.start.affinity), end: range.end, observed: [])
        try reject(s) { _ = try s.copyClipboard(ModernDeleteTarget(ranges: [foreign])) }
        let future = ModernTextRange(start: range.start, end: range.end, observed: [ChangeID(counter: 50, actor: "missing")])
        try reject(s) { _ = try s.copyClipboard(ModernDeleteTarget(ranges: [future])) }
        for kind in ["document", "column", "unknown"] {
            do { _ = try ModernClipboard(parts: [.node(value: .object(["id": .string("x")]), kind: kind)]); Issue.record("Expected nonfragment owner rejection") } catch {}
        }
        var nested: JSONValue = .object(["id": .string("x"), "type": .string("opaque")])
        for _ in 0..<102 { nested = .object(["id": .string("x"), "type": .string("opaque"), "consumer": nested]) }
        do { _ = try ModernClipboard(parts: [.node(value: nested, kind: "block")]); Issue.record("Expected bounded metadata rejection") } catch {}
    }
}
