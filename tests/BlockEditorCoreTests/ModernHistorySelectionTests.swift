import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernHistorySelectionTests {
    private func document(title: String = "Title") throws -> ModernDocument {
        try ModernDocument(documentID: "history", title: title, blocks: [Block.paragraph(id: "p", text: "ABC"), Block.paragraph(id: "q", text: "Other")])
    }
    private func session(_ actor: String = "a", _ d: ModernDocument? = nil) throws -> ModernSession {
        try ModernSession(documentID: "history", actorID: actor, epoch: "history", document: d ?? document())
    }
    private func node(_ s: ModernSession, _ label: String, path: [String] = []) throws -> NodeID { try s.node(at: NodeAddress(label, path: path)) }
    private func field(_ s: ModernSession, _ label: String = "p", path: [String] = []) throws -> WritingField { try s.field(node: node(s, label, path: path)) }
    private func backward(_ s: ModernSession) throws -> ModernTextRange { try s.captureTextRange(in: field(s), start: 2, end: 1) }
    private func select(_ s: ModernSession, _ range: ModernTextRange) throws {
        try s.setLocalSelection(s.captureLocalSelection(focus: .text(range.end), selection: .text(WritingTextRange(start: range.start, end: range.end))))
    }
    private func expectText(_ s: ModernSession, _ label: String, start: Int, end: Int, path: [String] = []) throws {
        let local = try #require(s.localSelection)
        guard case .text(let selected) = local.selection, case .text(let focus) = local.focus else { Issue.record("Expected restored anchored text selection"); return }
        let ss = try s.resolve(selected.start), ee = try s.resolve(selected.end), ff = try s.resolve(focus)
        #expect(try ss.address.identity == node(s, label, path: path) && ee.address.identity == ss.address.identity && ff.address.identity == ee.address.identity)
        #expect(ss.offset == start && ee.offset == end && ff.offset == end)
    }
    private func reopen(_ s: ModernSession) throws -> ModernSession {
        let saved = try s.save(), local = try s.exportHistorySelection(), r = try ModernSession.restore(saved, actorID: s.actorID)
        try r.restoreHistorySelection(local); #expect(try r.save() == saved); #expect(try r.exportHistorySelection() == local)
        return r
    }
    @Test func backwardReplacementAndReopenedHistoryRestoreOriginalAnchorsAcrossPeerPrefix() throws {
        let a = try session(), b = try session("b"), range = try backward(a); try select(a, range)
        try a.replaceText(in: range, with: "X")
        try b.replaceText(in: field(b), range: 0..<0, with: "R"); try a.receive(b.changes())
        #expect(a.document.blocks.map(\.text) == ["RAXC", "Other"])
        let r = try reopen(a); try r.undo(); #expect(r.document.blocks[0].text == "RABC"); try expectText(r, "p", start: 3, end: 2)
        try r.redo(); #expect(r.document.blocks[0].text == "RAXC"); try expectText(r, "p", start: 3, end: 3)
        try b.receive(r.changes()); #expect(b.document == r.document)
    }
    @Test func typingGroupKeepsFirstSelectionAndLatestCaretWithoutBreakingForRefreshedPeerFrontier() throws {
        let a = try session(), b = try session("b"), caret = try a.captureTextRange(in: field(a), start: 3, end: 3)
        try select(a, caret); try a.replaceText(in: caret, with: "X", typingGroup: "typing")
        try b.replaceText(in: field(b), range: 0..<0, with: "R"); try a.receive(b.changes())
        let current = try #require(try a.resolvedLocalSelection()); try a.setLocalSelection(current)
        try a.replaceText(in: field(a), range: 5..<5, with: "Y", typingGroup: "typing")
        #expect(a.document.blocks[0].text == "RABCXY")
        let r = try reopen(a); try r.undo(); #expect(r.document.blocks[0].text == "RABC" && !r.canUndo); try expectText(r, "p", start: 4, end: 4)
        try r.redo(); #expect(r.document.blocks[0].text == "RABCXY"); try expectText(r, "p", start: 6, end: 6)
    }
    @Test func actualSelectionChangeEndsTypingGroupAndPreservesLifoSelectionAfterReopen() throws {
        let a = try session(); try a.replaceText(in: field(a), range: 1..<1, with: "X", typingGroup: "typing")
        let end = try a.captureTextRange(in: field(a), start: 4, end: 4); try select(a, end)
        try a.replaceText(in: end, with: "Y", typingGroup: "typing")
        let r = try reopen(a); try r.undo(); #expect(r.document.blocks[0].text == "AXBC" && r.canUndo); try expectText(r, "p", start: 4, end: 4)
        try r.undo(); #expect(r.document.blocks[0].text == "ABC" && !r.canUndo); try expectText(r, "p", start: 1, end: 1)
        try r.redo(); try expectText(r, "p", start: 2, end: 2); try r.redo(); try expectText(r, "p", start: 5, end: 5)
    }
    @Test func publicationCallbackSeesPairedHistoryAndItsLaterInputIsNotOverwritten() throws {
        let a = try session(), original = try backward(a); try select(a, original)
        var callbacks = 0
        a.onChange = { document, change in
            do {
                callbacks += 1
                #expect(document.blocks[0].text == "AXC" && change != nil && a.canUndo)
                try self.expectText(a, "p", start: 2, end: 2)
                let reopened = try self.reopen(a)
                try reopened.undo(); #expect(reopened.document.blocks[0].text == "ABC")
                try self.expectText(reopened, "p", start: 2, end: 1)
                let later = try a.captureTextRange(in: self.field(a, "q"), start: 3, end: 3)
                try self.select(a, later)
            } catch { Issue.record(error) }
        }
        try a.replaceText(in: original, with: "X"); a.onChange = nil
        #expect(callbacks == 1); try expectText(a, "q", start: 3, end: 3)
        try a.setAppearance(field: "fontSize", value: "large")
        let r = try reopen(a); try r.undo(); try expectText(r, "q", start: 3, end: 3)
        try r.undo(); try expectText(r, "p", start: 2, end: 1)
    }
    @Test func mixedDeleteUndoRestoresWholeOriginsAndBackwardPartialRangeWithoutSelectingNewPeerAtoms() throws {
        let a = try session(), b = try session("b"), range = try backward(a), q = try a.captureNodes([node(a, "q")])
        let target = ModernDeleteTarget(nodes: q, ranges: [range])
        try a.setLocalSelection(a.captureLocalSelection(focus: .text(range.end), selection: .mixed(target)))
        _ = try a.delete(target)
        try b.replaceText(in: field(b), range: 0..<0, with: "R"); try a.receive(b.changes())
        let r = try reopen(a); try r.undo(); #expect(r.document.blocks.map(\.text) == ["RABC", "Other"])
        guard case .mixed(let selected) = r.localSelection?.selection else { Issue.record("Expected restored mixed selection"); return }
        #expect(try selected.nodes?.nodes == [node(r, "q")] && selected.ranges.count == 1)
        #expect(try r.resolve(selected.ranges[0].start).offset == 3 && r.resolve(selected.ranges[0].end).offset == 2)
        try r.redo(); #expect(r.document.blocks.map(\.text) == ["RAC"]); try expectText(r, "p", start: 2, end: 2)
    }
    @Test func delayedCutUsesPreparedInputSnapshotInsteadOfLaterActiveInputAndFailedPublicationDoesNotChangeLocalHistory() throws {
        let a = try session(), range = try backward(a); try select(a, range)
        let prepared = try a.prepareCut(ModernDeleteTarget(ranges: [range]))
        let other = try a.captureTextRange(in: field(a, "q"), start: 3, end: 3); try select(a, other)
        let before = try a.exportHistorySelection(), saved = try a.save()
        #expect(a.finishCut(prepared, published: false).reason == "clipboardPublicationFailed")
        #expect(try a.exportHistorySelection() == before && a.save() == saved)
        #expect(a.finishCut(prepared, published: true).status == "applied")
        let r = try reopen(a); try r.undo(); try expectText(r, "p", start: 2, end: 1)
        try r.redo(); try expectText(r, "p", start: 1, end: 1)
    }
    @Test func deletedOriginFallsBackToOriginalNeighborsWithoutFocusingAReusedDisplayLabel() throws {
        let a = try session(), b = try session("b"), q = try a.captureNodes([node(a, "q")])
        try a.setLocalSelection(a.captureLocalSelection(focus: .nodes(q), selection: .nodes(q)))
        try a.setAppearance(field: "fontSize", value: "large")
        try b.delete(node(b, "q")); _ = try b.insertBlock(Block.paragraph(id: "q", text: "Replacement"), after: node(b, "p"))
        try a.receive(b.changes()); #expect(a.document.blocks.map(\.text) == ["ABC", "Replacement"])
        let resolved = try #require(try a.resolvedLocalSelection()); guard case .text(let fallback) = resolved.focus else { Issue.record("Expected surviving preceding input"); return }
        #expect(try a.resolve(fallback).address.identity == node(a, "p") && a.resolve(fallback).offset == 3)
        let r = try reopen(a); try r.undo(); try expectText(r, "p", start: 3, end: 3)
        try r.redo(); try expectText(r, "p", start: 3, end: 3); #expect(r.document.blocks.map(\.text) == ["ABC", "Replacement"])
    }
    @Test func wholeBodyUndoRestoresNodeSelectionAndRedoReturnsEmptyInsertionWithoutPlaceholder() throws {
        let a = try session(), all = try a.captureNodes([node(a, "p"), node(a, "q")])
        try a.setLocalSelection(a.captureLocalSelection(focus: .nodes(all), selection: .nodes(all)))
        _ = try a.delete(ModernDeleteTarget(nodes: all)); #expect(a.document.blocks.isEmpty)
        let r = try reopen(a); try r.undo(); guard case .nodes(let selected) = r.localSelection?.selection else { Issue.record("Expected whole original node selection"); return }
        #expect(try selected.nodes == [node(r, "p"), node(r, "q")])
        try r.redo(); #expect(r.document.blocks.isEmpty)
        guard case .insertion(let boundary) = r.localSelection?.focus else { Issue.record("Expected empty insertion"); return }
        #expect(boundary.collection == .root && boundary.after == nil && r.localSelection?.selection == nil)
    }
    @Test func crossFieldSelectionEndpointsFollowPeerSplitAndRemainBackwardAcrossAppearanceUndoReopen() throws {
        let a = try session(), b = try session("b")
        let start = try a.position(in: field(a, "q"), offset: 2), end = try a.position(in: field(a), offset: 2)
        try a.setLocalSelection(a.captureLocalSelection(focus: .text(end), selection: .text(WritingTextRange(start: start, end: end))))
        try a.setAppearance(field: "pageWidth", value: "wide")
        _ = try b.splitBlock(in: b.captureTextRange(in: field(b), start: 1, end: 1), newBlockID: "tail")
        try a.receive(b.changes()); let r = try reopen(a); try r.undo()
        guard case .text(let selected) = r.localSelection?.selection else { Issue.record("Expected cross-field range"); return }
        #expect(try r.resolve(selected.start).address.identity == node(r, "q") && r.resolve(selected.start).offset == 2)
        #expect(try r.resolve(selected.end).address.identity == node(r, "tail") && r.resolve(selected.end).offset == 1)
        try r.redo(); #expect(r.document.blocks.map(\.text) == ["A", "BC", "Other"])
    }
    @Test func unicodeTitleBackwardRangeRestoresSelectionAndPeerPrefixWithoutTouchingBody() throws {
        let d = try document(title: "研究😀"), a = try session("a", d), b = try session("b", d)
        let range = try a.captureTextRange(in: a.titleField, start: 4, end: 1); try select(a, range)
        try a.replaceText(in: range, with: "X"); try b.replaceTitle(range: 0..<0, with: "P"); try a.receive(b.changes())
        let r = try reopen(a); try r.undo(); #expect(r.document.title == "P研究😀" && r.document.blocks == d.blocks)
        guard case .text(let selected) = r.localSelection?.selection else { Issue.record("Expected title selection"); return }
        #expect(try r.resolve(selected.start).offset == 5 && r.resolve(selected.end).offset == 2)
        try r.redo(); #expect(r.document.title == "P研X"); guard case .text(let caret) = r.localSelection?.focus else { Issue.record("Expected title caret"); return }; #expect(try r.resolve(caret).offset == 3)
    }
    @Test(arguments: ["format", "link", "color", "convert", "softBreak", "split", "duplicate", "paste", "insert", "move", "delete", "columns", "merge"])
    func deliberateCommandFamiliesRestoreTheirInputAndReportedResultAcrossUndoRedoReopen(_ action: String) throws {
        let a = try session(), range = try backward(a); try select(a, range)
        let p = try node(a, "p"), q = try node(a, "q"), boundary = try a.captureBoundary(after: q)
        switch action {
        case "format": try a.format(in: range, markType: "bold", mark: .object(["type": .string("bold")]))
        case "link": _ = try a.setLink(in: range, href: "https://example.org")
        case "color": _ = try a.setSemanticColor(ModernSemanticTarget(range: range), kind: .ink, role: "blue")
        case "convert": _ = try a.convertBlock(in: a.captureTextRange(in: field(a), start: 1, end: 1), to: WritingBlockTarget(type: "heading", level: 2))
        case "softBreak": _ = try a.softBreak(in: range)
        case "split": _ = try a.splitBlock(in: a.captureTextRange(in: field(a), start: 1, end: 1), newBlockID: "tail")
        case "duplicate": _ = try a.duplicate(ModernDuplicateTarget(selection: a.captureNodes([q]), boundary: boundary), newBlockIDs: ["copy"])
        case "paste": _ = try a.paste(ModernClipboard.plain("X"), at: ModernPasteTarget(range: range))
        case "insert": _ = try a.insertBlock(Block.paragraph(id: "new", text: "New"), at: boundary)
        case "move": _ = try a.move(ModernMoveTarget(selection: a.captureNodes([q]), boundary: a.captureBoundary()))
        case "merge": _ = try a.mergeBlocks(a.captureNodes([p,q]))
        case "delete": _ = try a.delete(ModernDeleteTarget(nodes: a.captureNodes([q]), ranges: [range]))
        default:
            let layout = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"layout","type":"columns","splitBasisPoints":5000,"columns":[{"id":"first","children":[]},{"id":"second","children":[]}]}"#.utf8))
            _ = try a.createColumns(ModernCreateColumnsTarget(selection: a.captureNodes([p,q]), caret: range.end), layout: layout)
        }
        let changed = a.document, r = try reopen(a); try r.undo(); #expect(try r.document == document()); try expectText(r, "p", start: 2, end: 1)
        try r.redo(); #expect(r.document == changed)
        switch action {
        case "format", "link", "color": try expectText(r, "p", start: 2, end: 1)
        case "convert", "delete", "columns":
            guard case .text(let caret) = r.localSelection?.focus else { Issue.record("Expected original input focus"); return }; #expect(try r.resolve(caret).address.identity == p && r.resolve(caret).offset == 1)
        case "merge": try expectText(r, "p", start: 3, end: 3)
        case "softBreak", "paste": try expectText(r, "p", start: 2, end: 2)
        case "split": try expectText(r, "tail", start: 0, end: 0)
        case "insert": try expectText(r, "new", start: 0, end: 0)
        case "duplicate":
            guard case .nodes(let selected) = r.localSelection?.selection, case .text(let caret) = r.localSelection?.focus else { Issue.record("Expected copied nodes/input"); return }
            #expect(try selected.nodes == [node(r, "copy")] && r.resolve(caret).address.identity == node(r, "copy") && r.resolve(caret).offset == 0)
        default:
            guard case .nodes(let selected) = r.localSelection?.selection else { Issue.record("Expected moved node selection"); return }; #expect(try selected.nodes == [node(r, "q")])
        }
    }
    @Test func itemSelectionAndContainingListStateRemainScopedAfterHistoryArchiveImport() throws {
        let listFields = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"list","type":"list","style":"todo","items":[{"id":"one","checked":false,"content":[{"type":"text","text":"One"}]},{"id":"two","checked":false,"content":[{"type":"text","text":"Two"}]}]}"#.utf8))
        let list = try Block(fields: listFields.object!)
        let d = try ModernDocument(documentID: "history", blocks: [list]), a = try session("a", d)
        let ids = try [node(a, "list", path: ["items", "one"]), node(a, "list", path: ["items", "two"])], selected = try a.captureLocalNodes(ids)
        let caret = try a.position(in: a.field(node: ids[1]), offset: 1)
        try a.setLocalSelection(a.captureLocalSelection(focus: .text(caret), selection: .nodes(selected)))
        _ = try a.listStructure(ModernListTarget(selection: selected, caret: caret), action: .setChecked, checked: true)
        let r = try reopen(a); try r.undo(); #expect(r.document == d); try r.redo()
        guard case .nodes(let nodes) = r.localSelection?.selection, case .text(let restored) = r.localSelection?.focus else { Issue.record("Expected retained list items/input"); return }
        #expect(try nodes.nodes == ids && r.resolve(restored).address.identity == ids[1] && r.resolve(restored).offset == 1)
    }
    @Test(arguments: ["row", "cell"]) func hierarchicalPasteUndoRestoresTypedInsertionAndRedoRestoresImportedNodeInput(_ kind: String) throws {
        let cell: JSONValue = .object(["id": .string("cell"), "content": .array([textNode("A")])]), row: JSONValue = .object(["id": .string("row"), "cells": .array([cell])])
        let table = try Block(fields: ["id": .string("table"), "type": .string("table"), "rows": .array([row])])
        let d = try ModernDocument(documentID: "history", blocks: [table]), a = try session("a", d), tableID = try node(a, "table"), rowID = try node(a, "table", path: ["rows", "row"])
        let collection = NodeCollection(owner: kind == "row" ? tableID : rowID, field: kind == "row" ? "rows" : "cells")
        let boundary = try a.capturePasteBoundary(in: collection)
        let importedCell: JSONValue = .object(["id": .string("old-cell"), "content": .array([textNode("B")])])
        let imported: JSONValue = kind == "row" ? .object(["id": .string("old-row"), "cells": .array([importedCell])]) : importedCell
        _ = try a.paste(ModernClipboard(parts: [.node(value: imported, kind: kind)]), at: ModernPasteTarget(boundary: boundary), newIDs: kind == "row" ? ["new-row", "new-cell"] : ["new-cell"])
        let r = try reopen(a); try r.undo(); #expect(r.document == d)
        guard case .insertion(let restored) = r.localSelection?.focus else { Issue.record("Expected original typed insertion"); return }; #expect(restored.collection == collection)
        try r.redo(); guard case .nodes(let selected) = r.localSelection?.selection, case .text(let caret) = r.localSelection?.focus else { Issue.record("Expected pasted schema node/input"); return }
        #expect(try selected.nodes.count == 1 && r.resolve(caret).offset == 0)
        let selectedValue = r.structure.nodes[selected.nodes[0]]!; #expect(selectedValue.label == (kind == "row" ? "new-row" : "new-cell"))
    }
    @Test func atomicReferenceInteriorSelectionSurvivesPeerTextAndAppearanceHistoryWithoutSplittingTheReference() throws {
        let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("page"), "entityId": .string("opaque"), "label": .string("Ref😀"), "consumer": .object(["id": .string("keep")])])
        let p = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A"), reference, textNode("Z")])])
        let d = try ModernDocument(documentID: "history", blocks: [p]), a = try session("a", d), b = try session("b", d)
        let range = try a.captureTextRange(in: field(a), start: 3, end: 2); try select(a, range)
        #expect(range.start.intraAtomOffset == 2 && range.end.intraAtomOffset == 1)
        #expect(throws: EditorError.invalidRange) { _ = try a.position(in: field(a), offset: 5) }
        try a.setAppearance(field: "fontSize", value: "large")
        try b.replaceText(in: field(b), range: 0..<0, with: "X"); try a.receive(b.changes())
        let r = try reopen(a); try r.undo(); try expectText(r, "p", start: 4, end: 3)
        try r.redo(); try expectText(r, "p", start: 4, end: 3)
        #expect(r.document.blocks[0].fields["content"]?.array?.contains(reference) == true)
    }
    @Test func explicitExternalFocusAndUnavailableOrNoopActionsNeverFabricateInputFocusOrConsumeHistory() throws {
        let a = try session(), range = try backward(a)
        try a.setLocalSelection(a.captureLocalSelection(focus: nil, selection: .text(WritingTextRange(start: range.start, end: range.end))))
        try a.setAppearance(field: "fontSize", value: "large")
        let r = try reopen(a); try r.undo(); #expect(r.localSelection?.focus == nil && r.localSelection?.selection != nil)
        try r.redo(); #expect(r.localSelection?.focus == nil && r.localSelection?.selection != nil)
        let saved = try r.save(), local = try r.exportHistorySelection()
        try r.setAppearance(field: "fontSize", value: "large")
        #expect(try r.save() == saved && r.exportHistorySelection() == local)
        r.allowedCommands = []; #expect(throws: ModernSessionError.self) { try r.replaceText(in: range, with: "bad") }; r.allowedCommands = nil
        r.isComposing = true; #expect(throws: ModernSessionError.compositionActive) { try r.undo() }; r.isComposing = false
        #expect(try r.save() == saved && r.exportHistorySelection() == local)
    }
    @Test(arguments: ["version", "scope", "actor", "duplicate", "unknown", "futureBefore", "missingCapture", "foreignEdit"])
    func malformedHistorySelectionArchivesRejectAtomicallyWithoutChangingAcceptedStateOrFreshRegistry(_ fault: String) throws {
        let a = try session(); try a.replaceText(in: field(a), range: 1..<1, with: "X"); try a.setAppearance(field: "pageWidth", value: "wide")
        let saved = try a.save(), local = try a.exportHistorySelection()
        var wire = try #require(JSONDecoder().decode(JSONValue.self, from: local).object)
        var records = try #require(wire["records"]?.array), record = try #require(records[0].object)
        switch fault {
        case "version": wire["version"] = .number(2)
        case "scope": wire["epoch"] = .string("other")
        case "actor": wire["actorID"] = .string("b")
        case "duplicate": records.append(records[0]); wire["records"] = .array(records)
        case "unknown": wire["extra"] = .bool(true)
        case "foreignEdit": record["edits"] = .array([.object(["counter": .number(1), "actor": .string("b")])]); records[0] = .object(record); wire["records"] = .array(records)
        default:
            var before = try #require(record["before"]?.object)
            before["observed"] = .array([.object(["counter": .number(fault == "futureBefore" ? 2 : 999), "actor": .string("a")])])
            record["before"] = .object(before); records[0] = .object(record); wire["records"] = .array(records)
        }
        let r = try ModernSession.restore(saved, actorID: "a"), empty = try r.exportHistorySelection(), state = r.syncState
        #expect(throws: (any Error).self) { try r.restoreHistorySelection(JSONEncoder().encode(JSONValue.object(wire))) }
        #expect(try r.save() == saved && r.exportHistorySelection() == empty && r.syncState == state && r.localSelection == nil)
        try r.restoreHistorySelection(local); #expect(try r.exportHistorySelection() == local)
    }
    @Test func localSelectionAndPlannedHistoryCapacityRejectBeforeDocumentPublicationAndPreserveRedoAndWholePayload() throws {
        let d = try document(), a = try session("a", d); var changes: [ModernChange] = []
        for index in 0..<100 {
            let peer = try session(String(repeating: "p", count: 80) + String(index), d)
            try peer.replaceText(in: field(peer), range: 0..<0, with: "r"); changes += try peer.changes().changes
        }
        try a.receive(ModernBatch(documentID: "history", epoch: "history", baseline: d, changes: changes))
        try select(a, a.captureTextRange(in: field(a), start: 100, end: 101)); try a.setAppearance(field: "fontSize", value: "large"); try a.undo()
        let range = try a.captureTextRange(in: field(a), start: 100, end: 101)
        let current = ModernLocalSelection(documentID: "history", epoch: "history", observed: a.modernObserved, focus: .text(range.end), selection: .mixed(ModernDeleteTarget(ranges: Array(repeating: range, count: 512))))
        let bytes = try JSONEncoder().encode(current).count; #expect(bytes > 5_400_000 && bytes < 7_500_000)
        try a.setLocalSelection(current); let saved = try a.save(), local = try a.exportHistorySelection(), receipt = a.syncState
        #expect(a.canRedo && !a.canUndo)
        #expect(throws: EditorError.recoveryCapacityExceeded) { try a.setAppearance(field: "pageWidth", value: "wide") }
        #expect(try a.save() == saved && a.exportHistorySelection() == local && a.syncState == receipt && a.canRedo)
        let oversized = ModernLocalSelection(documentID: "history", epoch: "history", observed: a.modernObserved, focus: .text(range.end), selection: .mixed(ModernDeleteTarget(ranges: Array(repeating: range, count: 4096))))
        #expect(throws: EditorError.recoveryCapacityExceeded) { try a.setLocalSelection(oversized) }
        #expect(try a.save() == saved && a.exportHistorySelection() == local && a.syncState == receipt)
    }
    @Test func freshAuthorEditClearsOnlyRedoSelectionRecordsAndOlderArchivesNeverInventInputState() throws {
        let a = try session(); try a.replaceText(in: field(a), range: 1..<1, with: "X"); try a.undo()
        let q = try a.captureTextRange(in: field(a, "q"), start: 1, end: 1); try select(a, q); try a.replaceText(in: q, with: "Y")
        let data = try a.exportHistorySelection(), wire = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(wire["records"]?.array?.count == 1 && !a.canRedo)
        let saved = try a.save(), legacy = try ModernSession.restore(saved, actorID: "a")
        #expect(legacy.localSelection == nil); try legacy.undo(); #expect(legacy.localSelection == nil)
        let r = try reopen(a); try r.undo(); try expectText(r, "q", start: 1, end: 1)
        try r.redo(); try expectText(r, "q", start: 2, end: 2)
        let other = try ModernSession.restore(saved, actorID: "other")
        #expect(throws: EditorError.invalidChange) { try other.restoreHistorySelection(data) }
        #expect(other.localSelection == nil && !other.canUndo)
    }

    @Test func asyncMetadataCompletionKeepsInputSelectionAndPeerTextThroughPairedRequestHistoryReopen() throws {
        let image = try Block(fields: ["id": .string("image"), "type": .string("image"), "src": .string("asset://pending")])
        let d = try ModernDocument(documentID: "history", blocks: [Block.paragraph(id: "p", text: "ABC"), image]), a = try session("a", d), b = try session("b", d)
        let selected = try backward(a); try select(a, selected)
        let request = try a.beginAsyncBlock(node(a, "image"), requestID: "inert")
        #expect(try a.completeAsyncBlock(request, metadata: ["src": .string("asset://done")]).status == "applied")
        try b.replaceText(in: field(b), range: 0..<0, with: "R"); try a.receive(b.changes())
        let requests = try a.exportAsyncRequests(), r = try reopen(a); try r.restoreAsyncRequests(requests)
        try r.undo(); #expect(r.document.blocks[1].fields["src"] == .string("asset://pending")); try expectText(r, "p", start: 3, end: 2)
        try r.redo(); #expect(r.document.blocks[1].fields["src"] == .string("asset://done")); try expectText(r, "p", start: 3, end: 2)
    }
    @Test func authorRepairRebasesLocalInputWithoutDroppingConflictingPeerHistoryOrPromotingFailedRedo() throws {
        let a = try session(), b = try session("b")
        let own = try a.insertBlock(Block.paragraph(id: "shared", text: "Own")), ownedChange = try #require(a.changes().changes.first?.id)
        _ = try b.insertBlock(Block.paragraph(id: "shared", text: "Peer"))
        #expect(throws: ModernSessionError.self) { try a.receive(b.changes()) }
        #expect(a.mergeRecovery != nil && a.document.blocks.contains(where: { $0.text == "Own" }))
        try a.repairUndo([ownedChange]); #expect(a.mergeRecovery == nil && a.document.blocks.contains(where: { $0.text == "Peer" }))
        guard case .insertion(let boundary) = a.localSelection?.focus else { Issue.record("Expected original insertion target after repair"); return }; #expect(boundary.collection == .root && boundary.after == nil)
        #expect(throws: EditorError.invalidPath) { _ = try a.address(of: own) }
        let saved = try a.save(), local = try a.exportHistorySelection()
        #expect(throws: ModernSessionError.self) { try a.redo() }
        #expect(try a.save() == saved && a.exportHistorySelection() == local && a.mergeRecovery != nil)
    }

}
