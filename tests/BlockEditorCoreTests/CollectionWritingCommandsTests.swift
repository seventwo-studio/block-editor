import BlockEditorCore
import Foundation
import Testing

private let collectionReference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("external"), "label": .string("世界😀")])
private func collectionSession(_ actor: String, _ blocks: [Block], version: Int = 4) throws -> WritingSession {
    try WritingSession(documentID: "collections", actorID: actor, epoch: "collections-v4", document: Document(blocks: blocks), protocolVersion: version)
}
private func collectionCell(_ id: String) -> JSONValue {
    .object(["id": .string(id), "content": .array([textNode("A", marks: [.object(["type": .string("bold")])]), collectionReference]), "consumer": .object(["id": .string("preserve")])])
}
private func collectionRow(_ id: String) -> JSONValue { .object(["id": .string(id), "cells": .array([collectionCell("same-cell")]), "extension": .string("row")]) }

@Test func collectionInsertAfterMiddleExitKeepsRoleAnchorAcrossRemoteUndo() throws {
    let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "host": .string("owner"), "items": .array([
        .object(["id": .string("first"), "content": .array([textNode("before")])]),
        .object(["id": .string("empty"), "content": .array([]), "checked": .bool(true), "host": .string("item")]),
        .object(["id": .string("last"), "content": .array([textNode("after")])])
    ])])
    let a = try collectionSession("a", [list]), b = try collectionSession("b", [list])
    let item = try a.node(at: NodeAddress("list", path: ["items", "empty"]))
    let field = TextAddress("list", path: ["items", "empty", "content"])
    _ = try a.enterListItem(at: field, range: 0..<0, newItemID: "tail")
    let inserted = try a.insertCollectionNodes([.object(["id": .string("pasted"), "type": .string("paragraph"), "content": .array([collectionReference]), "host": .string("paste")])], into: .root, after: item)
    try b.replaceText(at: field, range: 0..<0, with: "R")
    try a.receive(b.changes()); try b.receive(a.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["list", "empty", "pasted", "tail"])
    #expect(try a.node(at: NodeAddress("empty")) == item)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks.map(\.id) == ["list", "empty", "tail"])
    #expect(try reopened.text(at: reopened.textAddress(of: item)) == "R")
    try reopened.undo()
    #expect(reopened.document.blocks.map(\.id) == ["list"])
    #expect(try reopened.node(at: NodeAddress("list", path: ["items", "empty"])) == item)
    #expect(try reopened.text(at: field) == "R")
    try reopened.redo(); try reopened.redo()
    #expect(reopened.document == accepted)
    #expect(try reopened.node(at: NodeAddress("pasted")) == inserted.nodes[0])
}

@Test func collectionTableConcurrentRowsCellsReorderRemoveAndReopenedUndo() throws {
    let table = try Block(fields: ["id": .string("t"), "type": .string("table"), "columnWidths": .array([.number(120)]), "rows": .array([collectionRow("base")]), "extension": .string("table")])
    let a = try collectionSession("a", [table]), b = try collectionSession("b", [table])
    let root = try a.node(at: NodeAddress("t")), rows = NodeCollection(owner: root, field: "rows")
    let base = try #require(a.collectionNodes(in: rows).first)
    let created = try a.insertCollectionNodes([collectionRow("a1"), collectionRow("a2")], into: rows, after: base)
    let remote = try b.insertCollectionNodes([collectionRow("b1")], into: rows, after: base)
    try a.receive(b.changes()); try b.receive(a.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.collectionNodes(in: rows).count == 4)
    let cells = NodeCollection(owner: created.nodes[0], field: "cells")
    let oldCell = try #require(a.collectionNodes(in: cells).first)
    let added = try a.insertCollectionNodes([collectionCell("other")], into: cells, after: oldCell)
    #expect(try a.copy(added).nodes == [collectionCell("other")])
    try a.move(WritingSelection(nodes: [created.nodes[0]]), into: rows, after: remote.nodes[0])
    #expect(try a.collectionNodes(in: rows).firstIndex(of: created.nodes[0])! > a.collectionNodes(in: rows).firstIndex(of: remote.nodes[0])!)
    #expect(try a.address(of: added.nodes[0]) == NodeAddress("t", path: ["rows", "a1", "cells", "other"]))
    try b.replaceText(at: TextAddress("t", path: ["rows", "base", "cells", "same-cell", "content"]), range: 0..<0, with: "R")
    try a.receive(b.changes())
    try a.delete(WritingSelection(nodes: [base]))
    #expect(try a.collectionNodes(in: rows).count == 3)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(try reopened.collectionNodes(in: rows).count == 4)
    #expect(try reopened.text(at: TextAddress("t", path: ["rows", "base", "cells", "same-cell", "content"])) == "RA世界😀")
    #expect(reopened.document.blocks[0].fields["columnWidths"] == table.fields["columnWidths"])
    #expect(reopened.document.blocks[0].fields["extension"] == .string("table"))
    try reopened.redo(); #expect(reopened.document == a.document)
    let all = reopened.changes()
    let reordered = WritingBatch(documentID: all.documentID, epoch: all.epoch, baseline: all.baseline,
        changes: Array(all.changes.reversed()) + all.changes, version: all.version)
    try b.receive(reordered); try b.receive(reordered)
    #expect(b.document == reopened.document)
}

@Test func collectionToggleCreationUndoRedoRetainsRemoteDescendants() throws {
    let base = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([collectionReference]), "extension": .string("keep")])
    let a = try collectionSession("a", [base]), b = try collectionSession("b", [base])
    let root = try a.node(at: NodeAddress("t")), children = NodeCollection(owner: root, field: "children")
    let branch: JSONValue = .object(["id": .string("branch"), "type": .string("toggle"), "summary": .array([textNode("branch")])])
    let inserted = try a.insertCollectionNodes([branch], into: children)
    try b.receive(a.changes())
    let grandChildren = NodeCollection(owner: inserted.nodes[0], field: "children")
    let remote = try b.insertCollectionNodes([.object(Block.paragraph(id: "peer", text: "remote 😀").fields)], into: grandChildren)
    try a.receive(b.changes())
    try a.undo()
    // Undo removes this author's payload; the container remains to preserve
    // the independently created remote descendant.
    #expect(try a.collectionNodes(in: children) == inserted.nodes)
    #expect(try a.collectionNodes(in: grandChildren) == remote.nodes)
    #expect(try a.copy(inserted).nodes[0]["summary"] == .array([]))
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.redo()
    #expect(try reopened.collectionNodes(in: grandChildren) == remote.nodes)
    #expect(try reopened.text(at: reopened.textAddress(of: remote.nodes[0])) == "remote 😀")
    #expect(reopened.document.blocks[0].fields["summary"] == base.fields["summary"])
    #expect(reopened.document.blocks[0].fields["extension"] == .string("keep"))
    #expect(!reopened.canRedo)
}

@Test func collectionNestedChecklistMovesPreserveReferencesCheckedAndScopedLabels() throws {
    let item: JSONValue = .object(["id": .string("same"), "content": .array([collectionReference]), "checked": .bool(true), "extension": .object(["id": .string("external")])])
    let left = try Block(fields: ["id": .string("left"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let a = try collectionSession("a", [left, right]), b = try collectionSession("b", [left, right])
    let parent = try a.node(at: NodeAddress("left", path: ["items", "same"]))
    let nested = try a.insertCollectionNodes([item], into: NodeCollection(owner: parent, field: "children"))
    let rightParent = try a.node(at: NodeAddress("right", path: ["items", "same"]))
    let destination = NodeCollection(owner: rightParent, field: "children")
    try a.move(nested, into: destination)
    #expect(try a.collectionNodes(in: destination) == nested.nodes)
    #expect(try a.copy(nested).nodes == [item])
    try b.receive(a.changes())
    try b.replaceText(at: b.textAddress(of: nested.nodes[0]), range: 0..<0, with: "R")
    try a.receive(b.changes()); try a.undo()
    #expect(try a.address(of: nested.nodes[0]) == NodeAddress("left", path: ["items", "same", "children", "same"]))
    #expect(try a.text(at: a.textAddress(of: nested.nodes[0])) == "R世界😀")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.redo(); #expect(try reopened.address(of: nested.nodes[0]).blockID == "right")
    #expect(try reopened.copy(nested).nodes[0]["checked"] == .bool(true))
    #expect(try reopened.copy(nested).nodes[0]["extension"] == item["extension"])
}

@Test func collectionCreationRejectsInvalidScopePolicyCompositionAndLegacyAtomically() throws {
    let t = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([])])
    let a = try collectionSession("a", [t]), root = try a.node(at: NodeAddress("t"))
    let children = NodeCollection(owner: root, field: "children")
    let table: JSONValue = .object(["id": .string("table"), "type": .string("table"), "rows": .array([collectionRow("row")])])
    a.allowedBlockTypes = ["toggle", "paragraph"]
    let before = try a.save()
    #expect(throws: EditorError.restrictedBlock("table")) { try a.insertCollectionNodes([table], into: children) }
    #expect(throws: EditorError.self) { try a.collectionNodes(in: NodeCollection(owner: root, field: "bogus")) }
    let value = JSONValue.object(try Block.paragraph(id: "p", text: "plain").fields)
    #expect(throws: EditorError.self) { try a.insertCollectionNodes([value, value], into: children) }
    #expect(throws: EditorError.self) { try a.insertCollectionNodes([value], into: children, after: root) }
    a.isComposing = true
    #expect(throws: WritingSessionError.compositionActive) { try a.insertCollectionNodes([value], into: children) }
    #expect(try a.save() == before)
    let legacy = try collectionSession("legacy", [t], version: 3), legacyBefore = try legacy.save()
    #expect(throws: EditorError.unsupportedVersion(3)) { try legacy.insertCollectionNodes([value], into: .root) }
    #expect(try legacy.save() == legacyBefore)
}

@Test(arguments: [false, true]) func collectionInsertAfterProjectedPeerRetainsRoleProofAndUndo(baseline: Bool) throws {
    let original = try Block.paragraph(id: "p", text: baseline ? "root" : "abcd")
    let item: JSONValue = .object(["id": .string("peer"), "content": .array([textNode("cd")]), "extension": .string("keep")])
    let foreign = try Block(fields: ["id": .string("foreign"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let blocks = baseline ? [original, foreign] : [original]
    let a = try collectionSession("a", blocks), b = try collectionSession("b", blocks)
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "todo"))
    try b.receive(a.changes())
    let peer: NodeID
    if baseline {
        peer = try b.node(at: NodeAddress("foreign", path: ["items", "peer"]))
        try b.move(WritingSelection(nodes: [peer]), into: NodeCollection(owner: b.node(at: NodeAddress("p")), field: "items"))
    } else {
        try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 2..<2, newItemID: "peer")
        peer = try b.node(at: NodeAddress("p", path: ["items", "peer"]))
    }
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    let before = b.document
    let inserted = try b.insertCollectionNodes([.object(Block.paragraph(id: "after-peer", text: "new 😀").fields)], into: .root, after: peer)
    let order = b.document.blocks.map(\.id)
    #expect(order.firstIndex(of: "after-peer") == order.firstIndex(of: "peer").map { $0 + 1 })
    #expect(try b.node(at: NodeAddress("peer")) == peer)
    try a.receive(b.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(b.save(), actorID: "b")
    try reopened.undo(); #expect(reopened.document == before)
    try reopened.redo()
    #expect(try reopened.node(at: NodeAddress("after-peer")) == inserted.nodes[0])
    #expect(try reopened.text(at: reopened.textAddress(of: peer)) == "cd")
}
