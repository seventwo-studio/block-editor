import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernPasteTests {
    private func fixture(_ name: String) throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func session(_ actor: String = "a", document: ModernDocument) throws -> ModernSession {
        try ModernSession(documentID: document.documentID, actorID: actor, epoch: "paste", document: document)
    }
    private func node(_ s: ModernSession, _ id: String, path: [String] = []) throws -> NodeID { try s.node(at: NodeAddress(id, path: path)) }
    private func schemaIDs(_ value: JSONValue, kind: NodeKind = .block) -> [String] {
        [value["id"]!.string!] + StructuralState.collectionFields(kind, value.object!, modern: true).sorted(by: { $0.key < $1.key }).flatMap { name, kind in
            (value[name]?.array ?? []).flatMap { schemaIDs($0, kind: kind) }
        }
    }
    private func reject(_ s: ModernSession, _ action: () throws -> Void) throws {
        let before = try s.save(), state = s.syncState
        do { try action(); Issue.record("Expected unchanged rejection") } catch {}
        #expect(try s.save() == before && s.syncState == state && s.mergeRecovery == nil)
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let aa = try a.changes(), bb = try b.changes(); try a.receive(bb); try b.receive(aa); try a.receive(bb); try b.receive(aa)
    }
    @Test func catalogInsertionFocusIsStoredWithAuthorHistoryWhileOrdinaryPasteKeepsItsCaret() throws {
        let document = try ModernDocument(json: Data(#"{"format":"seventwo.block-editor.document","formatVersion":1,"documentID":"catalog-focus","title":"Help","appearance":{"fontFamily":"sans","fontSize":"default","pageWidth":"readable"},"blocks":[{"id":"query","type":"paragraph","content":[{"type":"text","text":"/code"}]}]}"#.utf8))
        let clipboard = try ModernClipboard(parts: [.node(value: .object(["id": .string("code"), "type": .string("code"), "code": .string("")]), kind: "block")])
        for catalog in [false, true] {
            let s = try session(document: document), field = try s.field(node: node(s, "query"))
            let target = ModernPasteTarget(range: try s.captureTextRange(in: field, start: 0, end: 5))
            let result = try s.paste(clipboard, at: target, focusInserted: catalog)
            guard case .text(let caret) = result.focus else { Issue.record("Expected text focus"); continue }
            #expect(caret.field.name == (catalog ? "code" : "content"))
            #expect(try s.resolve(caret).offset == 0)
            try s.undo(); #expect(try s.text(in: field) == "/code")
            try s.redo(); #expect(s.localSelection?.focus == result.focus)
            let restored = try ModernSession.restore(s.save(), actorID: "a")
            try restored.restoreHistorySelection(s.exportHistorySelection())
            #expect(restored.localSelection?.focus == result.focus)
        }
    }
    @Test func catalogFromTableCellAndListItemCapturesContainingBlockAndRestoresQuery() throws {
        let table = try ModernInsertionCatalog.block("table", id: "table", childIDs: ["r1", "c1", "c2", "r2", "c3", "c4"])
        let list = try ModernInsertionCatalog.block("todo", id: "list", childIDs: ["item"])
        let document = try ModernDocument(documentID: "nested-catalog", blocks: [table, list])
        for address in [NodeAddress("table", path: ["rows", "r1", "cells", "c1"]), NodeAddress("list", path: ["items", "item"])] {
            let s = try session(document: document), field = try s.field(node: s.node(at: address))
            try s.replaceText(in: field, range: 0..<0, with: "/code")
            let before = s.document, range = try s.captureTextRange(in: field, start: 0, end: 5), boundary = try s.captureInsertionBoundary(after: field)
            #expect(boundary.collection == .root)
            let clipboard = try ModernClipboard(parts: [.node(value: .object(["id": .string("fresh"), "type": .string("code"), "code": .string("")]), kind: "block")])
            let result = try s.paste(clipboard, at: .init(boundary: boundary, selection: ModernDeleteTarget(ranges: [range])), focusInserted: true)
            #expect(s.document.blocks.map(\.type) == (address.blockID == "table" ? ["table", "code", "list"] : ["table", "list", "code"]))
            #expect(try s.text(in: field) == "")
            guard case .text(let focus) = result.focus else { Issue.record("Expected inserted code focus"); continue }
            #expect(focus.field.name == "code")
            try s.undo(); #expect(s.document == before)
            try s.redo(); #expect(try s.text(in: field) == "")
        }
    }
    @Test func acceptedRootLayoutPasteMatchesFullIndependentSnapshotAndFreshensOnlySchemaIDs() throws {
        let d = try fixture("columns-3000"), expected = try fixture("columns-root-copy"), s = try session(document: d)
        let layout = try node(s, "layout"), clipboard = try s.copyClipboard(ModernDeleteTarget(nodes: s.captureNodes([layout])))
        let target = try ModernPasteTarget(boundary: s.capturePasteBoundary(after: layout))
        let copied = try #require(expected.blocks.first { $0.id == "copy-layout" })
        let result = try s.paste(clipboard, at: target, newIDs: schemaIDs(.object(copied.fields)))
        #expect(s.document == expected)
        #expect(try s.changes().changes.count == 1)
        guard case .nodes(let selected)? = result.selection, case .text(let caret) = result.focus else { Issue.record("Expected copied layout selection/input"); return }
        let copiedNode = try node(s, "copy-layout"), resolved = try s.resolve(caret)
        let copiedInput = try node(s, "copy-layout", path: ["columns", "copy-first-column", "children", "copy-A"])
        #expect(selected.nodes == [copiedNode] && resolved.address.identity == copiedInput)
        #expect(try s.resolve(caret).offset == 0)
        let reopened = try ModernSession.restore(s.save(), actorID: "a")
        try reopened.undo(); #expect(reopened.document == d && !reopened.canUndo)
        try reopened.redo(); #expect(reopened.document == expected)
    }
    @Test func explicitFlattenedFallbackMatchesAcceptedColumnContentAndRichNestedPasteRejects() throws {
        let d = try fixture("columns-3000"), expected = try fixture("columns-flattened-paste"), s = try session(document: d)
        let layout = try node(s, "layout"), clipboard = try s.copyClipboard(ModernDeleteTarget(nodes: s.captureNodes([layout])))
        let collection = try NodeCollection(owner: node(s, "layout", path: ["columns", "first-column"]), field: "children")
        let target = try ModernPasteTarget(boundary: s.capturePasteBoundary(in: collection, after: node(s, "layout", path: ["columns", "first-column", "children", "B"])))
        try reject(s) { _ = try s.paste(clipboard, at: target) }
        let children = expected.blocks[0].fields["columns"]!.array![0]["children"]!.array!.filter { $0["id"]!.string!.hasPrefix("copy-") }
        let result = try s.paste(clipboard, at: target, mode: .flattenedColumns, newIDs: children.flatMap { schemaIDs($0) })
        #expect(s.document == expected)
        guard case .nodes(let selection)? = result.selection else { Issue.record("Expected copied content selection"); return }
        #expect(selection.nodes.count == 3)
        let saved = try s.save(), reopened = try ModernSession.restore(saved, actorID: "a")
        try reopened.undo(); #expect(reopened.document == d)
        try reopened.redo(); #expect(reopened.document == expected && clipboard.parts.count == 1)
    }
    @Test func acceptedBlankPlainMultilinePreservesFourLiteralLinesAndLastInputCaret() throws {
        let d = try fixture("blank"), expected = try fixture("blank-plain-paste"), s = try session(document: d)
        let clipboard = try ModernClipboard.plain("\nHello\n\n")
        let result = try s.paste(clipboard, at: ModernPasteTarget(boundary: s.capturePasteBoundary()), mode: .plainText, newIDs: ["paste-0", "paste-1", "paste-2", "paste-3"])
        #expect(s.document == expected)
        #expect(try s.changes().changes.count == 1)
        guard case .text(let caret) = result.focus else { Issue.record("Expected last empty input"); return }
        let resolved = try s.resolve(caret), finalInput = try node(s, "paste-3")
        #expect(resolved.address.identity == finalInput && resolved.offset == 0)
        try s.undo(); #expect(s.document == d && !s.canUndo)
        try s.redo(); #expect(s.document == expected)
    }
    @Test func capturedRichReplacementKeepsAtomicReferenceMetadataAndPeerTextThroughUndoAndReopen() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "ABC")])
        let a = try session(document: d), b = try session("b", document: d), field = try a.field(node: node(a, "p"))
        let target = try ModernPasteTarget(range: a.captureTextRange(in: field, start: 2, end: 1))
        try b.replaceText(in: b.field(node: node(b, "p")), range: 3..<3, with: " peer"); try a.receive(b.changes())
        let role: JSONValue = .object(["type": .string("semantic-color"), "value": .string("blue")])
        let ref: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("page"), "entityId": .string("consumer:opaque"), "label": .string("Ref"), "consumer": .object(["id": .string("keep")])])
        let clipboard = try ModernClipboard(parts: [.inline([textNode("東京😀", marks: [role]), ref])])
        let result = try a.paste(clipboard, at: target); #expect(a.document.blocks[0].text == "A東京😀RefC peer")
        #expect(a.document.blocks[0].fields["content"]!.array!.contains(ref))
        guard case .text(let caret) = result.focus else { Issue.record("Expected paste caret"); return }
        #expect(try a.resolve(caret).offset == "A東京😀Ref".utf16.count)
        try exchange(a, b); #expect(a.document == b.document)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); #expect(reopened.document.blocks[0].text == "ABC peer")
        try reopened.redo(); #expect(reopened.document == a.document)
    }
    @Test func sameFieldBlockReplacementHasOneRetainedCutAndKeepsPeerInsertion() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "ABCD")])
        let a = try session(document: d), b = try session("b", document: d), field = try a.field(node: node(a, "p"))
        let target = try ModernPasteTarget(range: a.captureTextRange(in: field, start: 1, end: 3))
        try b.replaceText(in: b.field(node: node(b, "p")), range: 2..<2, with: "X"); try a.receive(b.changes())
        let clipboard = try ModernClipboard.multiline("N")
        _ = try a.paste(clipboard, at: target, newIDs: ["imported", "tail"])
        #expect(a.document.blocks.contains { $0.id == "imported" && $0.text == "N" })
        #expect(a.document.blocks.map(\.text).joined().contains("X") && !a.document.blocks.map(\.text).joined().contains("B"))
        try exchange(a, b); #expect(a.document == b.document)
        let result = a.document; try a.undo(); try exchange(a, b)
        #expect(a.document.blocks[0].text == "ABXCD")
        try a.redo(); try exchange(a, b); #expect(a.document == result && a.document == b.document)
    }
    @Test func titleAndCodeUseExplicitPlainFallbackWithoutRichMarkOrBlockCoercion() throws {
        let code = try Block(fields: ["id": .string("code"), "type": .string("code"), "code": .string("AB"), "language": .string("swift")])
        let d = try ModernDocument(documentID: "paste", title: "Title", blocks: [code]), s = try session(document: d)
        let rich = try ModernClipboard.multiline("a\n\nb\n")
        let title = try ModernPasteTarget(range: s.captureTextRange(in: s.titleField, start: 0, end: 5))
        try reject(s) { _ = try s.paste(rich, at: title) }
        _ = try s.paste(rich, at: title, mode: .plainText); #expect(s.document.title == "a  b ")
        let field = try s.field(node: node(s, "code"), name: "code"), target = try ModernPasteTarget(range: s.captureTextRange(in: field, start: 1, end: 1))
        _ = try s.paste(rich, at: target, mode: .plainText); #expect(s.document.blocks[0].fields["code"] == .string("Aa\n\nb\nB"))
        try s.undo(); #expect(s.document.blocks[0] == code)
        try s.undo(); #expect(s.document == d)
    }
    @Test func copiedRowAndConvertedListItemCollectionBirthsKeepModernSemanticAdmission() throws {
        let role: JSONValue = .object(["type": .string("semantic-background"), "value": .string("green")])
        let paragraph = try Block.paragraph(id: "p", text: "one")
        let s = try session(document: ModernDocument(documentID: "paste", blocks: [paragraph]))
        let f = try s.field(node: node(s, "p"))
        _ = try s.convertBlock(in: s.captureTextRange(in: f, start: 0, end: 0), to: WritingBlockTarget(type: "list", style: "unordered"))
        let owner = try node(s, "p"), collection = NodeCollection(owner: owner, field: "items")
        let item: JSONValue = .object(["id": .string("item"), "content": .array([textNode("新", marks: [role])]), "consumer": .object(["id": .string("opaque")])])
        let clipboard = try ModernClipboard(parts: [.node(value: item, kind: "item")])
        _ = try s.paste(clipboard, at: ModernPasteTarget(boundary: s.capturePasteBoundary(in: collection)), newIDs: ["fresh-item"])
        #expect(s.document.blocks[0].fields["items"]!.array!.contains { $0["id"] == .string("fresh-item") && $0["content"] == item["content"] && $0["consumer"] == item["consumer"] })
        let reopened = try ModernSession.restore(s.save(), actorID: "a"); try reopened.undo(); try reopened.redo(); #expect(reopened.document == s.document)
    }
    @Test func localPolicyCompositionStaleScopeAndReusedLabelsRejectWithoutPartialReplacement() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "keep")]), s = try session(document: d)
        let target = try ModernPasteTarget(range: s.captureTextRange(in: s.field(node: node(s, "p")), start: 0, end: 4)), clipboard = try ModernClipboard.plain("replace")
        s.allowedCommands = []
        try reject(s) { _ = try s.paste(clipboard, at: target) }; s.allowedCommands = nil
        s.isComposing = true; try reject(s) { _ = try s.paste(clipboard, at: target) }; s.isComposing = false
        try reject(s) { _ = try s.paste(ModernClipboard.multiline("replace"), at: target, newIDs: ["p"]) }
        try reject(s) { _ = try s.paste(clipboard, at: target, newIDs: ["unused"], policy: WritingPastePolicy(allowedMarkTypes: [])) }
        let boundary = try s.capturePasteBoundary(), foreign = ModernBlockBoundary(documentID: "foreign", epoch: boundary.epoch, collection: boundary.collection, after: boundary.after, observed: boundary.observed)
        try reject(s) { _ = try s.paste(clipboard, at: ModernPasteTarget(boundary: foreign)) }
    }

    @Test func crossParagraphPastePreservesRetainedEndpointMetadataAndPeerRoutes() throws {
        var ending = try Block.paragraph(id: "end", text: "CDEF").fields
        ending["consumer"] = .object(["id": .string("keep"), "flag": .bool(true)])
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "start", text: "AB"), Block.paragraph(id: "middle", text: "remove"), Block(fields: ending), Block.paragraph(id: "next", text: "Next")])
        let a = try session(document: d), b = try session("b", document: d)
        let start = try a.field(node: node(a, "start")), end = try a.field(node: node(a, "end"))
        let target = ModernPasteTarget(range: ModernTextRange(start: try a.position(in: end, offset: 2), end: try a.position(in: start, offset: 1), observed: a.modernObserved))
        try b.replaceText(in: b.field(node: node(b, "start")), range: 2..<2, with: "X")
        try b.replaceText(in: b.field(node: node(b, "end")), range: 4..<4, with: "Y")
        try a.receive(b.changes())
        let clipboard = try ModernClipboard(parts: [.inline([textNode("H")]), .node(value: .object(Block.paragraph(id: "n", text: "N").fields), kind: "block"), .inline([textNode("T")])])
        let result = try a.paste(clipboard, at: target, newIDs: ["imported"])
        #expect(a.document.blocks.map(\.id) == ["start", "imported", "end", "next"])
        #expect(a.document.blocks.map(\.text) == ["AH", "N", "TXEFY", "Next"])
        #expect(a.document.blocks[2].fields["consumer"] == ending["consumer"])
        guard case .text(let caret) = result.focus else { Issue.record("Expected retained endpoint caret"); return }
        #expect(try a.resolve(caret).address.identity == end.node)
        try exchange(a, b); #expect(a.document == b.document)
        let pasted = a.document, reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["ABX", "remove", "CDEFY", "Next"])
        try reopened.redo(); #expect(reopened.document == pasted)
    }
    @Test func hierarchicalFieldsPreserveOwnerMetadataAndUseCompatibleChildCollection() throws {
        let child = try Block.paragraph(id: "child", text: "AB")
        let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([textNode("Head")]), "children": .array([.object(child.fields)]), "consumer": .object(["id": .string("opaque")])])
        let d = try ModernDocument(documentID: "paste", blocks: [toggle]), s = try session(document: d)
        let owner = try node(s, "toggle"), childNode = try node(s, "toggle", path: ["children", "child"])
        let start = try s.field(node: owner, name: "summary"), end = try s.field(node: childNode)
        let target = ModernPasteTarget(range: ModernTextRange(start: try s.position(in: start, offset: 2), end: try s.position(in: end, offset: 1), observed: s.modernObserved))
        _ = try s.paste(ModernClipboard.multiline("New"), at: target, newIDs: ["imported"])
        #expect(s.document.blocks[0].fields["summary"] == .array([textNode("He")]))
        #expect(s.document.blocks[0].fields["children"]?.array?.map { $0["id"]!.string! } == ["imported", "child"])
        #expect(s.document.blocks[0].fields["children"]?.array?.last?["content"] == .array([textNode("B")]))
        #expect(s.document.blocks[0].fields["consumer"] == toggle.fields["consumer"])
        let result = s.document; try s.undo(); #expect(s.document == d); try s.redo(); #expect(s.document == result)
    }
    @Test func pastedLayoutPeerEditSurvivesAuthorUndoAndReopenWithoutDuplication() throws {
        let d = try fixture("columns-3000"), a = try session(document: d), b = try session("b", document: d)
        let layout = try node(a, "layout"), clipboard = try a.copyClipboard(ModernDeleteTarget(nodes: a.captureNodes([layout])))
        _ = try a.paste(clipboard, at: ModernPasteTarget(boundary: a.capturePasteBoundary(after: layout)))
        try b.receive(a.changes())
        let copied = b.document.blocks[1], column = copied.fields["columns"]!.array![0]
        let input = try b.field(node: node(b, copied.id, path: ["columns", column["id"]!.string!, "children", column["children"]!.array![0]["id"]!.string!]))
        try b.replaceText(in: input, range: 3..<3, with: "!"); try a.receive(b.changes())
        let pasted = a.document; try a.undo(); try exchange(a, b)
        var retained = copied.fields, retainedColumns = retained["columns"]!.array!
        for index in retainedColumns.indices {
            var fields = retainedColumns[index].object!
            if index == 0 {
                var input = fields["children"]!.array![0].object!
                input["content"] = .array([textNode("!", marks: [.object(["type": .string("bold")])])])
                fields["children"] = .array([.object(input)])
            } else { fields["children"] = .array([]) }
            retainedColumns[index] = .object(fields)
        }
        retained["columns"] = .array(retainedColumns)
        let expected = try ModernDocument(documentID: d.documentID, title: d.title, blocks: [d.blocks[0], Block(fields: retained), d.blocks[1]])
        #expect(a.document == b.document && a.document == expected)
        let reopened = try ModernSession.restore(a.save(), actorID: "a"); try reopened.redo(); #expect(reopened.document == pasted)
    }
    @Test func mixedReplacementAndEmptyClipboardAreSingleOrZeroHistorySteps() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "a", text: "ABC"), Block.paragraph(id: "b", text: "Remove")]), s = try session(document: d)
        let a = try node(s, "a"), b = try node(s, "b"), range = try s.captureTextRange(in: s.field(node: a), start: 1, end: 2)
        let target = try ModernPasteTarget(boundary: s.capturePasteBoundary(after: b), selection: ModernDeleteTarget(nodes: s.captureNodes([b]), ranges: [range]))
        let before = try s.save()
        _ = try s.paste(ModernClipboard(parts: [.inline([])]), at: target); #expect(try s.save() == before)
        _ = try s.paste(ModernClipboard.plain("New"), at: target, newIDs: ["new"])
        #expect(s.document.blocks.map(\.id) == ["a", "new"] && s.document.blocks.map(\.text) == ["AC", "New"])
        #expect(try s.changes().changes.count == 1)
        try s.undo(); #expect(s.document == d && !s.canUndo); try s.redo(); #expect(s.document.blocks.map(\.text) == ["AC", "New"])
    }
    @Test func pasteAfterCapturedCodeAliasUsesCurrentFieldAndRejectsForgedRelation() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "a", text: "ABC"), Block.paragraph(id: "b", text: "Other")]), s = try session(document: d)
        let f = try s.field(node: node(s, "a")), target = try ModernPasteTarget(range: s.captureTextRange(in: f, start: 1, end: 2))
        _ = try s.convertBlock(in: s.captureTextRange(in: f, start: 0, end: 0), to: WritingBlockTarget(type: "code"))
        _ = try s.paste(ModernClipboard.plain("X"), at: target, mode: .plainText)
        #expect(s.document.blocks[0].fields["code"] == .string("AXC"))
        let wrongField = try s.field(node: node(s, "b")), captured = target.range!
        let forged = ModernTextRange(start: WritingPosition(documentID: s.documentID, epoch: s.epoch, field: wrongField, anchor: captured.start.anchor), end: captured.end, observed: captured.observed)
        try reject(s) { _ = try s.paste(ModernClipboard.plain("Y"), at: ModernPasteTarget(range: forged)) }
        try s.undo(); #expect(s.document.blocks[0].fields["code"] == .string("ABC")); try s.redo(); #expect(s.document.blocks[0].fields["code"] == .string("AXC"))
    }
    @Test func inactiveForgedPlanRejectsAndMissingCaptureIsRetainedUntilItsCausalBirthArrives() throws {
        let d = try ModernDocument(documentID: "paste", blocks: []), a = try session(document: d), b = try session("b", document: d)
        _ = try a.insertBlock(Block.paragraph(id: "p", text: "ABC"), at: a.captureBoundary())
        let birth = try a.changes().changes[0]
        _ = try a.paste(ModernClipboard.plain("X"), at: ModernPasteTarget(range: a.captureTextRange(in: a.field(node: node(a, "p")), start: 1, end: 2)))
        let batch = try a.changes(), paste = batch.changes[1]
        #expect(throws: ModernSessionError.self) { try b.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [paste])) }
        #expect(b.document == d && b.mergeRecovery != nil)
        try b.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [birth]))
        #expect(b.document == a.document && b.mergeRecovery == nil)
        try a.undo()
        guard case .edit(let operations) = paste.body, case .paste(let command) = operations.last! else { Issue.record("Expected paste packet"); return }
        let forged = ModernPaste(target: command.target, clipboard: command.clipboard, mode: command.mode, newIDs: command.newIDs, birthKinds: command.birthKinds, operations: command.operations + [.text(.delete(keys: []))])
        let original = try a.changes(), altered = original.changes.map { $0.id == paste.id ? ModernChange(id: $0.id, observed: $0.observed, body: .edit([.paste(forged)])) : $0 }
        let fresh = try session("fresh", document: d), before = try fresh.save()
        #expect(throws: EditorError.self) { try fresh.receive(ModernBatch(documentID: original.documentID, epoch: original.epoch, baseline: original.baseline, changes: altered)) }
        #expect(try fresh.save() == before)
    }

    @Test func tableRowAndCellPasteKeepSemanticMetadataAndFreshNamespaces() throws {
        let cell: JSONValue = .object(["id": .string("cell"), "content": .array([textNode("A")]), "align": .string("left")])
        let row: JSONValue = .object(["id": .string("row"), "cells": .array([cell]), "consumer": .object(["id": .string("keep")])])
        let table = try Block(fields: ["id": .string("table"), "type": .string("table"), "rows": .array([row])])
        let d = try ModernDocument(documentID: "paste", blocks: [table]), s = try session(document: d)
        let owner = try node(s, "table"), rows = NodeCollection(owner: owner, field: "rows")
        var rich = row.object!, richCell = cell.object!
        richCell["content"] = .array([textNode("新", marks: [.object(["type": .string("semantic-color"), "value": .string("purple")])])]); rich["cells"] = .array([.object(richCell)])
        _ = try s.paste(ModernClipboard(parts: [.node(value: .object(rich), kind: "row")]), at: ModernPasteTarget(boundary: s.capturePasteBoundary(in: rows, after: node(s, "table", path: ["rows", "row"]))), newIDs: ["new-row", "new-cell"])
        let copiedRow = s.document.blocks[0].fields["rows"]!.array![1]
        #expect(copiedRow["consumer"] == row["consumer"] && copiedRow["cells"]!.array![0]["content"] == richCell["content"])
        let rowNode = try node(s, "table", path: ["rows", "new-row"]), cells = NodeCollection(owner: rowNode, field: "cells")
        _ = try s.paste(ModernClipboard(parts: [.node(value: .object(richCell), kind: "cell")]), at: ModernPasteTarget(boundary: s.capturePasteBoundary(in: cells)), newIDs: ["other-cell"])
        let expected = s.document, reopened = try ModernSession.restore(s.save(), actorID: "a")
        try reopened.undo(); try reopened.undo(); #expect(reopened.document == d)
        try reopened.redo(); try reopened.redo(); #expect(reopened.document == expected)
    }
    @Test func inertAssetPolicyAndNewTailAdmissionRejectWithoutChangingOriginalPayload() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "AB")]), s = try session(document: d)
        let file: JSONValue = .object(["id": .string("file"), "type": .string("file"), "src": .string("asset:opaque"), "name": .string("File"), "consumer": .object(["id": .string("unchanged")])])
        let clipboard = try ModernClipboard(parts: [.node(value: file, kind: "block")]), original = try clipboard.json()
        let target = try ModernPasteTarget(boundary: s.capturePasteBoundary())
        try reject(s) { _ = try s.paste(clipboard, at: target) }
        _ = try s.paste(clipboard, at: target, newIDs: ["new-file"], policy: WritingPastePolicy(allowAssetMetadata: true))
        #expect(s.document.blocks[0].fields["src"] == file["src"] && s.document.blocks[0].fields["consumer"] == file["consumer"])
        #expect(try clipboard.json() == original)
        let range = try ModernPasteTarget(range: s.captureTextRange(in: s.field(node: node(s, "p")), start: 1, end: 1))
        let heading = try Block(fields: ["id": .string("h"), "type": .string("heading"), "level": .number(1), "content": .array([textNode("Heading")])])
        try reject(s) { _ = try s.paste(ModernClipboard(parts: [.node(value: .object(heading.fields), kind: "block")]), at: range, policy: WritingPastePolicy(allowedBlockTypes: ["heading"])) }
    }

    @Test func explicitPlainRangeUsesNormalInlineAndMultilinePrefixSuffixSemantics() throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "AB")]), s = try session(document: d)
        let field = try s.field(node: node(s, "p")), range = try ModernPasteTarget(range: s.captureTextRange(in: field, start: 1, end: 1))
        _ = try s.paste(ModernClipboard.multiline("X"), at: range, mode: .plainText)
        #expect(s.document.blocks.map(\.text) == ["AXB"])
        try s.undo(); #expect(s.document == d)
        let result = try s.paste(ModernClipboard.plain("x\ny"), at: range, mode: .plainText, newIDs: ["tail"])
        #expect(s.document.blocks.map(\.id) == ["p", "tail"] && s.document.blocks.map(\.text) == ["Ax", "yB"])
        guard case .text(let caret) = result.focus else { Issue.record("Expected continuation caret"); return }
        #expect(try s.resolve(caret).offset == 1)
        try s.undo(); #expect(s.document == d); try s.redo(); #expect(s.document.blocks.map(\.text) == ["Ax", "yB"])
    }
}
