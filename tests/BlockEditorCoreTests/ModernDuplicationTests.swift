import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernDuplicationTests {
    private func fixture(_ name: String = "mixed") throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func session(_ actor: String = "a", document: ModernDocument? = nil) throws -> ModernSession {
        let d = try document ?? fixture()
        return try ModernSession(documentID: d.documentID, actorID: actor, epoch: "copy", document: d)
    }
    private func node(_ s: ModernSession, _ id: String, path: [String] = []) throws -> NodeID { try s.node(at: NodeAddress(id, path: path)) }
    private func target(_ s: ModernSession, _ ids: [String] = ["A"], after: String? = "A", collection: NodeCollection = .root) throws -> ModernDuplicateTarget {
        try ModernDuplicateTarget(selection: s.captureNodes(ids.map { try node(s, $0) }), boundary: s.captureBoundary(in: collection, after: after.map { try node(s, $0) }))
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let aa = try a.changes(), bb = try b.changes(); try a.receive(bb); try b.receive(aa); try a.receive(bb); try b.receive(aa)
    }
    private func reject(_ s: ModernSession, _ action: () throws -> Void) throws {
        let before = try s.save(), state = s.syncState
        do { try action(); Issue.record("Expected unchanged rejection") } catch {}
        #expect(try s.save() == before && s.syncState == state && s.mergeRecovery == nil)
    }
    private func schemaIDs(_ value: JSONValue, kind: NodeKind = .block) -> [String] {
        [value["id"]!.string!] + StructuralState.collectionFields(kind, value.object!, modern: true).sorted(by: { $0.key < $1.key }).flatMap { field, kind in
            (value[field]?.array ?? []).flatMap { schemaIDs($0, kind: kind) }
        }
    }

    @Test func acceptedDuplicateLiteralSelectsCopyAndFocusesItsFirstInputOneStep() throws {
        let s = try session(), before = s.document, result = try s.duplicate(target(s), newBlockIDs: ["copy-A"])
        #expect(s.document == (try fixture("mixed-duplicated"))) // Independent ACC-12 fixture, unchanged.
        let copied = try node(s, "copy-A"), selected = try s.captureNodes([copied])
        #expect(result.selection == .nodes(selected))
        guard case .text(let caret) = result.focus else { Issue.record("Expected copied input focus"); return }
        #expect(try s.resolve(caret).offset == 0 && caret.field == s.field(node: copied))
        #expect(try s.changes().changes.count == 1)
        let restored = try ModernSession.restore(s.save(), actorID: "a")
        try restored.undo(); #expect(restored.document == before && !restored.canUndo)
        try restored.redo(); #expect(restored.document == s.document)
    }
    @Test func admissionCopiesObservedTextButLaterOriginalPeerEditsAndUndoRemainIndependent() throws {
        let a = try session(), b = try session("b"), captured = try target(a)
        let field = try b.field(node: node(b, "A"))
        try b.replaceText(in: field, range: 0..<0, with: "observed "); try a.receive(b.changes())
        _ = try a.duplicate(captured, newBlockIDs: ["copy-A"])
        let copy = try a.field(node: node(a, "copy-A")), text = try a.text(in: copy)
        #expect(text.hasPrefix("observed "))
        try b.replaceText(in: field, range: 0..<0, with: "later "); try exchange(a, b)
        #expect(try a.document == b.document && a.text(in: copy) == text)
        try a.undo(); try exchange(a, b)
        #expect(!a.document.blocks.contains { $0.id == "copy-A" })
        #expect(try a.text(in: a.field(node: node(a, "A"))).hasPrefix("later observed "))
        try a.redo(); try exchange(a, b); #expect(try a.document == b.document && a.text(in: copy) == text)
    }
    @Test func nestedListsTablesColumnsFreshenOnlySchemaIDsAndRetainLiteralRichAndOpaqueFields() throws {
        var fields = try fixture().fields
        let paragraph = JSONValue.object(["id": .string("inside"), "type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("世界😀"), "marks": .array([.object(["type": .string("semantic-color"), "value": .string("green")])])])]), "consumer": .object(["id": .string("inside"), "items": .array([.object(["id": .string("opaque-child")])])])])
        fields["blocks"] = .array(fields["blocks"]!.array! + [
            .object(["id": .string("table"), "type": .string("table"), "rows": .array([.object(["id": .string("r"), "cells": .array([.object(["id": .string("c"), "content": .array([]), "consumer": .object(["id": .string("c")])])])])])]),
            .object(["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(6500), "columns": .array([
                .object(["id": .string("left"), "children": .array([paragraph])]), .object(["id": .string("right"), "children": .array([])])])])])
        let s = try session(document: ModernDocument(fields: fields))
        _ = try s.duplicate(target(s, ["toggle", "list", "table", "layout"], after: "layout"), newBlockIDs: ["copy-toggle", "copy-list", "copy-table", "copy-layout"])
        let original = s.document.blocks.filter { ["toggle", "list", "table", "layout"].contains($0.id) }
        let copies = s.document.blocks.filter { $0.id.hasPrefix("copy-") }
        let originalIDs = original.flatMap { schemaIDs(.object($0.fields)) }, copiedIDs = copies.flatMap { schemaIDs(.object($0.fields)) }
        #expect(originalIDs.count == copiedIDs.count && Set(originalIDs).isDisjoint(with: copiedIDs) && Set(copiedIDs).count == copiedIDs.count)
        let layout = copies.last!.fields, child = layout["columns"]!.array![0]["children"]!.array![0]
        #expect(layout["splitBasisPoints"] == .number(6500) && child["content"] == paragraph["content"] && child["consumer"] == paragraph["consumer"])
        let table = copies[2].fields
        #expect(table["rows"]!.array![0]["cells"]!.array![0]["consumer"] == .object(["id": .string("c")]))
        let restored = try ModernSession.restore(s.save(), actorID: "a"); #expect(restored.document == s.document)
        try restored.undo(); #expect(restored.document == (try ModernDocument(fields: fields)))
        try restored.redo(); #expect(restored.document == s.document)
    }
    @Test func opaqueBlockIsCopiedVerbatimWithItsOnlyKnownSchemaIDFreshened() throws {
        let s = try session(), original = s.document.blocks.last!.fields
        _ = try s.duplicate(target(s, ["opaque"], after: "opaque"), newBlockIDs: ["copy-opaque"])
        var expected = original; expected["id"] = .string("copy-opaque")
        #expect(s.document.blocks.last!.fields == expected)
        // Duplication does not enable generic unknown-type authoring.
        try reject(s) { _ = try s.insertBlock(Block(fields: expected), at: s.captureBoundary()) }
    }
    @Test func capturedOrderSurvivesPeerMovesAndHistoricalDeletedBoundaryRemainsUsable() throws {
        let a = try session(), b = try session("b"), capture = try target(a, ["A", "toggle"], after: "media")
        _ = try b.move(ModernMoveTarget(selection: b.captureNodes([node(b, "toggle")]), boundary: b.captureBoundary(after: node(b, "opaque"))))
        _ = try b.delete(ModernDeleteTarget(nodes: b.captureNodes([node(b, "media")]))); try a.receive(b.changes())
        _ = try a.duplicate(capture, newBlockIDs: ["copy-A", "copy-toggle"]); try exchange(a, b)
        #expect(a.document == b.document)
        let ids = a.document.blocks.map(\.id), index = try #require(ids.firstIndex(of: "copy-A"))
        #expect(ids[index + 1] == "copy-toggle" && !ids.contains("media"))
    }
    @Test func copiedChildPeersRemainRecoverableAcrossAuthorUndoRedoAndReopen() throws {
        let a = try session(), b = try session("b")
        _ = try a.duplicate(target(a, ["toggle"], after: "toggle"), newBlockIDs: ["copy-toggle"]); try b.receive(a.changes())
        let child = b.document.blocks.first { $0.id == "copy-toggle" }!.fields["children"]!.array![0]["id"]!.string!
        let node = try self.node(b, "copy-toggle", path: ["children", child]), field = try b.field(node: node)
        try b.replaceText(in: field, range: 0..<0, with: "peer "); let late = try b.changes()
        try a.undo(); try a.receive(late)
        // Retained-origin Undo removes the author's copied seeds while keeping
        // active peer work in its minimal surviving container.
        #expect(try a.text(in: field) == "peer ")
        #expect(a.document.blocks.first { $0.id == "copy-toggle" }!.fields["summary"] == .array([]))
        let restored = try ModernSession.restore(a.save(), actorID: "a"); try restored.redo()
        #expect(try restored.text(in: field).hasPrefix("peer "))
        try a.redo(); #expect(a.document == restored.document)
        try exchange(a, b); #expect(a.document == b.document)
    }
    @Test func deletedSourceAndOwnerReusedLabelsScopeAndPolicyRejectUnchanged() throws {
        let s = try session(), captured = try target(s)
        s.allowedCommands = ["replaceTitle"]; try reject(s) { _ = try s.duplicate(captured, newBlockIDs: ["copy-A"]) }
        s.allowedCommands = nil; s.isComposing = true; try reject(s) { _ = try s.duplicate(captured, newBlockIDs: ["copy-A"]) }
        s.isComposing = false
        for ids in [["A"], [""], ["x", "y"]] { try reject(s) { _ = try s.duplicate(captured, newBlockIDs: ids) } }
        _ = try s.delete(ModernDeleteTarget(nodes: s.captureNodes([node(s, "A")])))
        _ = try s.insertBlock(.paragraph(id: "A", text: "replacement"), at: s.captureBoundary())
        try reject(s) { _ = try s.duplicate(captured, newBlockIDs: ["copy-A"]) }
        let replacement = try target(s)
        let wrong = ModernDuplicateTarget(selection: ModernNodeSelection(documentID: s.documentID, epoch: "other", nodes: replacement.selection.nodes, observed: replacement.selection.observed), boundary: replacement.boundary)
        try reject(s) { _ = try s.duplicate(wrong, newBlockIDs: ["copy-A"]) }
    }
    @Test func columnDestinationAdmitsOrdinaryCopiesAndRejectsNestedLayoutOrDeletedOwner() throws {
        let s = try session()
        let layout: JSONValue = .object(["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array([.object(["id": .string("left"), "children": .array([])]), .object(["id": .string("right"), "children": .array([])])])])
        _ = try s.createColumns(ModernCreateColumnsTarget(boundary: s.captureBoundary()), layout: layout)
        let column = try node(s, "layout", path: ["columns", "left"]), collection = NodeCollection(owner: column, field: "children")
        let boundary = try s.captureBoundary(in: collection), captured = try s.captureNodes([node(s, "A")])
        _ = try s.duplicate(ModernDuplicateTarget(selection: captured, boundary: boundary), newBlockIDs: ["copy-A"])
        #expect(try s.node(at: NodeAddress("layout", path: ["columns", "left", "children", "copy-A"])) != node(s, "A"))
        try reject(s) { _ = try s.duplicate(target(s, ["layout"], after: nil, collection: collection), newBlockIDs: ["copy-layout"]) }
        _ = try s.removeColumns(ModernColumnTarget(layout: node(s, "layout")))
        try reject(s) { _ = try s.duplicate(ModernDuplicateTarget(selection: captured, boundary: boundary), newBlockIDs: ["copy-second"]) }
    }
    @Test func duplicateFromPeerSplitCopiesOnlyCurrentVisibleContentNotBirthPayload() throws {
        let a = try session(), b = try session("b"), target = try self.target(a), field = try b.field(node: node(b, "A"))
        _ = try b.splitBlock(in: b.captureTextRange(in: field, start: 5, end: 5), newBlockID: "tail"); try a.receive(b.changes())
        _ = try a.duplicate(target, newBlockIDs: ["copy-A"])
        #expect(try a.text(in: a.field(node: node(a, "copy-A"))) == "Bold ")
        #expect(a.document.blocks.first { $0.id == "copy-A" }!.fields["content"] == a.document.blocks.first { $0.id == "A" }!.fields["content"])
        try exchange(a, b); #expect(a.document == b.document)
    }
    @Test func copiedExposedPeerParagraphAndFollowingAnchorSurviveOriginalListRedo() throws {
        let d = try ModernDocument(documentID: "roles", title: "", blocks: [.paragraph(id: "A", text: "ABC")])
        let a = try session(document: d), b = try session("b", document: d), field = try a.field(node: node(a, "A"))
        _ = try a.convertBlock(in: a.captureTextRange(in: field, start: 1, end: 1), to: WritingBlockTarget(type: "list"))
        try b.receive(a.changes())
        let item = try b.field(node: node(b, "A", path: ["items", "A-item"]))
        _ = try b.splitBlock(in: b.captureTextRange(in: item, start: 1, end: 1), newBlockID: "retained")
        try a.undo(); try exchange(a, b)
        _ = try b.duplicate(target(b, ["retained"], after: "retained"), newBlockIDs: ["copy-retained"])
        try a.receive(b.changes()); let copied = try a.field(node: node(a, "copy-retained"))
        #expect(try a.text(in: copied) == "BC")
        try a.redo(); try exchange(a, b)
        #expect(a.document == b.document && a.document.blocks.map(\.id) == ["A", "retained", "copy-retained"])
        #expect(try a.text(in: copied) == "BC")
        let restored = try ModernSession.restore(b.save(), actorID: "b"); try restored.undo()
        #expect(!restored.document.blocks.contains { $0.id == "copy-retained" })
        try restored.redo(); #expect(restored.document == b.document)
    }
    @Test func forgedCopyPayloadAndInvisibleMalformedPacketsRejectAtomically() throws {
        let s = try session(); _ = try s.duplicate(target(s), newBlockIDs: ["copy-A"])
        let batch = try s.changes(), change = batch.changes[0]
        guard case .edit(let edits) = change.body, case .duplicateBlocks(let copy) = edits[0],
              case .insertNode(let value, let identity, let collection, let placement, let after) = copy.operations[0] else { Issue.record("Missing copied plan"); return }
        var altered = value.object!; altered["consumer"] = .object(["opaque": .string("forged")])
        let forged = ModernDuplication(target: copy.target, newBlockIDs: copy.newBlockIDs, operations: [.insertNode(value: .object(altered), identity: identity, collection: collection, placement: placement, after: after)])
        let id = ChangeID(counter: 2, actor: "a")
        let disabled = ModernChange(id: id, observed: [change.id], body: .setActive(targets: [change.id], active: false))
        for hidden in [false, true] {
            let target = try session("receiver"), bad = ModernChange(id: change.id, observed: change.observed, body: .edit([.duplicateBlocks(forged)]))
            try reject(target) { try target.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [bad] + (hidden ? [disabled] : []))) }
        }
        let target = try session("receiver")
        let mixed = ModernChange(id: change.id, observed: [], body: .edit([.duplicateBlocks(copy), .setAppearance(field: "fontSize", value: "large")]))
        try reject(target) { try target.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [mixed, disabled])) }
    }
}
