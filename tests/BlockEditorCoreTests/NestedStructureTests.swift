import BlockEditorCore
import Foundation
import Testing

private func paragraph(_ id: String, _ text: String) -> JSONValue {
    .object(["id": .string(id), "type": .string("paragraph"), "content": .array([textNode(text)]), "extension": .object(["keep": .bool(true)])])
}
private func toggle(_ id: String, _ children: [JSONValue] = []) throws -> Block {
    try Block(fields: ["id": .string(id), "type": .string("toggle"), "summary": .array([textNode(id)]), "children": .array(children)])
}
private func v2(_ actor: String, _ baseline: Document) throws -> EditorSession {
    try EditorSession(documentID: "nested", actorID: actor, document: baseline, collaborationVersion: 2)
}
private func exchange(_ sessions: [EditorSession]) throws {
    let batches = sessions.map { $0.changes() }
    for session in sessions { for batch in batches.reversed() { try session.receive(batch); try session.receive(batch) } }
    for session in sessions { #expect(try session.document == sessions[0].document) }
}

@Test func nestedReceiveHoldsPreserveCompositionAnchorsAndPreparationCallbacks() throws {
    let baseline = try Document(blocks: [toggle("left", [paragraph("p", "old")]), toggle("right")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let child = try a.node(at: NodeAddress("left", path: ["children", "p"]))
    let text = try a.textAddress(of: child)
    let caret = try a.position(at: text, offset: 0)
    let outer = a.deferRemoteChanges(), inner = a.deferRemoteChanges()
    try b.replaceText(at: text, range: 0..<0, with: "REMOTE")
    try b.moveNode(child, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    var preparations = 0, reentrantEditRejected = false
    a.onWillReceive = {
        preparations += 1
        #expect((try? a.address(of: child)) == NodeAddress("left", path: ["children", "p"]))
        do { try a.setText(at: text, to: "must not overwrite") }
        catch { reentrantEditRejected = (error as? EditorError) == .invalidChange }
    }
    try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    #expect(preparations == 0)
    try a.setText(at: text, to: "oldIME")
    let heldSave = try EditorSession.restore(a.save(), actorID: "a")
    #expect(try heldSave.text(at: text) == "oldIME")
    #expect(try heldSave.address(of: child) == NodeAddress("left", path: ["children", "p"]))
    try inner()
    #expect(preparations == 0)
    try outer()
    try outer() // A hold release is idempotent.
    #expect(preparations == 1)
    #expect(reentrantEditRejected)
    #expect(try a.text(at: text) == "REMOTEoldIME")
    #expect(try a.offset(of: caret) == 6)
    #expect(try a.address(of: child) == NodeAddress("right", path: ["children", "p"]))
    try b.receive(a.changes())
    #expect(try a.document == b.document)
    try a.undo()
    #expect(try a.text(at: text) == "REMOTEold")
    #expect(try a.address(of: child) == NodeAddress("right", path: ["children", "p"]))
}

@Test func heldProtocolFailureDoesNotStopLaterNestedChangesOrAcknowledgeTheFailure() throws {
    let baseline = try Document(blocks: [toggle("parent")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let old = try EditorSession(documentID: a.documentID, actorID: "legacy", document: baseline)
    try old.insert(.paragraph(id: "legacy", text: "wrong protocol"))
    try b.insertNode(paragraph("remote", "keep"), into: NodeCollection(owner: b.node(at: NodeAddress("parent")), field: "children"))
    let release = a.deferRemoteChanges()
    try a.receive(old.changes())
    try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    #expect(throws: EditorError.unsupportedVersion(1)) { try release() }
    #expect(try a.document == b.document)
    #expect(a.syncState.received == b.syncState.received)
    #expect(!a.syncState.received.contains(old.changes().changes[0].id))
    #expect(try EditorSession.restore(a.save(), actorID: "a").document == b.document)
}

// Rejected unions remain outside saved history and receipts until an explicit repair.
@Test func siblingInsertionConflictDoesNotAcknowledgeOrPersistRemoteChanges() throws {
    let baseline = try Document(blocks: [toggle("parent")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let collection = NodeCollection(owner: try a.node(at: NodeAddress("parent")), field: "children")
    try a.insertNode(paragraph("same", "author a"), into: collection)
    try b.insertNode(paragraph("same", "author b"), into: collection)
    let beforeA = try a.save(), beforeB = try b.save()
    let changesA = a.changes(), changesB = b.changes()
    #expect(throws: EditorError.self) { try a.receive(changesB) }
    #expect(throws: EditorError.self) { try b.receive(changesA) }
    #expect(a.mergeRecovery?.reason == .identityConflict)
    #expect(a.mergeRecovery == b.mergeRecovery)
    #expect(try a.save() == beforeA)
    #expect(try b.save() == beforeB)
    #expect(a.syncState.received == Set(changesA.changes.map(\.id)))
    #expect(b.syncState.received == Set(changesB.changes.map(\.id)))
}

@Test func nestedMovesRetainScopedIdentityTextMarksReferencesAndSelections() throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("e"), "entityType": .string("note"), "label": .string("Ref")])
    var child = paragraph("shared", "café 😀")
    var fields = child.object!; fields["content"] = .array([textNode("café 😀"), reference]); child = .object(fields)
    let baseline = try Document(blocks: [toggle("left", [child]), toggle("right", [paragraph("shared", "other")]), toggle("destination")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let node = try a.node(at: NodeAddress("left", path: ["children", "shared"]))
    let text = try a.textAddress(of: node), selection = try a.position(at: text, offset: 5)
    let destination = try a.node(at: NodeAddress("destination"))
    try a.moveNode(node, into: NodeCollection(owner: destination, field: "children"))
    try a.format(at: text, range: 0..<4, markType: "bold", mark: .object(["type": .string("bold")]))
    try b.replaceText(at: TextAddress("left", path: ["children", "shared", "content"]), range: 0..<0, with: "Remote ")
    try exchange([a, b])
    #expect(try a.address(of: node) == NodeAddress("destination", path: ["children", "shared"]))
    #expect(try a.text(at: text) == "Remote café 😀Ref")
    #expect(try a.offset(of: selection) == 12)
    #expect(try a.text(at: TextAddress("right", path: ["children", "shared", "content"])) == "other")
    let moved = try a.document.blocks.first { $0.id == "destination" }?.fields["children"]?.array?.first
    #expect(moved?["extension"] == .object(["keep": .bool(true)]))
    #expect(moved?["content"]?.array?.contains(reference) == true)
    #expect(moved?["content"]?.array?.contains { $0["marks"]?.array?.contains(.object(["type": .string("bold")])) == true } == true)
    let restored = try EditorSession.restore(a.save(), actorID: "a")
    #expect(try restored.document == a.document)
    try restored.undo(); try restored.undo()
    #expect(try restored.address(of: node) == NodeAddress("left", path: ["children", "shared"]))
    #expect(try restored.text(at: text) == "Remote café 😀Ref")
    try restored.redo(); try restored.redo()
    #expect(try restored.document == a.document)
}

@Test func concurrentCyclesAndCollidingMovesFallBackWithoutChangingIDs() throws {
    let baseline = try Document(blocks: [toggle("x", [paragraph("same", "x")]), toggle("y", [paragraph("same", "y")]), toggle("z")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let x = try a.node(at: NodeAddress("x")), y = try a.node(at: NodeAddress("y"))
    try a.moveNode(x, into: NodeCollection(owner: y, field: "children"))
    try b.moveNode(y, into: NodeCollection(owner: x, field: "children"))
    try exchange([a, b])
    #expect(try a.address(of: x) == NodeAddress("x"))
    #expect(try a.address(of: y) == NodeAddress("x", path: ["children", "y"]))
    let c = try v2("a", baseline), d = try v2("b", baseline)
    let first = try c.node(at: NodeAddress("x", path: ["children", "same"]))
    let second = try c.node(at: NodeAddress("y", path: ["children", "same"]))
    let z = try c.node(at: NodeAddress("z")), target = NodeCollection(owner: z, field: "children")
    try c.moveNode(first, into: target); try d.moveNode(second, into: target)
    try exchange([c, d])
    #expect(try c.address(of: first) == NodeAddress("x", path: ["children", "same"]))
    #expect(try c.address(of: second) == NodeAddress("z", path: ["children", "same"]))
}

@Test func undoInsertionPreservesRemoteContentAndConcurrentDescendantsSurviveDelete() throws {
    let baseline = try Document(blocks: [toggle("existing")])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let parent = try a.insertNode(.object(try toggle("new").fields), into: .root)
    try b.receive(a.changes())
    let child = try b.insertNode(paragraph("child", "remote"), into: NodeCollection(owner: parent, field: "children"))
    try a.undo(); try exchange([a, b])
    #expect(try a.address(of: child) == NodeAddress("new", path: ["children", "child"]))
    #expect(try a.text(at: a.textAddress(of: child)) == "remote")
    let restored = try EditorSession.restore(a.save(), actorID: "a")
    #expect(try restored.document == a.document)
    try restored.redo()
    #expect(try restored.text(at: restored.textAddress(of: child)) == "remote")
    let c = try v2("c", baseline), d = try v2("d", baseline)
    let existing = try c.node(at: NodeAddress("existing"))
    try c.deleteNode(existing)
    let concurrent = try d.insertNode(paragraph("concurrent", "survives"), into: NodeCollection(owner: existing, field: "children"))
    try exchange([c, d])
    #expect(try c.address(of: concurrent) == NodeAddress("existing", path: ["children", "concurrent"]))
    try c.undo(); try exchange([c, d])
    #expect(try c.text(at: c.textAddress(of: concurrent)) == "survives")
}

@Test func undoNodeInsertionRemovesItsTextButRetainsRemoteAtoms() throws {
    let baseline = try Document(blocks: [])
    let a = try v2("a", baseline), b = try v2("b", baseline)
    let inserted = try a.insertNode(paragraph("new", "local"), into: .root)
    try b.receive(a.changes())
    let address = try b.textAddress(of: inserted)
    try b.replaceText(at: address, range: 5..<5, with: "REMOTE")
    try a.undo(); try exchange([a, b])
    #expect(try a.text(at: address) == "REMOTE")
    #expect(try a.document.blocks.first?.text == "REMOTE")
    try a.redo(); try exchange([a, b])
    #expect(try a.text(at: address) == "localREMOTE")
}

@Test func nestedListIndentOutdentAndTableCollectionsUseSharedCommands() throws {
    let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([
        .object(["id": .string("a"), "content": .array([textNode("a")]), "checked": .bool(false)]),
        .object(["id": .string("b"), "content": .array([textNode("b")]), "checked": .bool(true)])])])
    let table = try Block(fields: ["id": .string("table"), "type": .string("table"), "rows": .array([
        .object(["id": .string("r1"), "cells": .array([.object(["id": .string("c1"), "content": .array([textNode("one")]), "header": .bool(true)])])]),
        .object(["id": .string("r2"), "cells": .array([.object(["id": .string("c2"), "content": .array([textNode("two")])])])])])])
    let baseline = try Document(blocks: [list, table]), a = try v2("a", baseline), b = try v2("b", baseline)
    let item = try a.node(at: NodeAddress("list", path: ["items", "b"]))
    try a.indent(item)
    #expect(try a.address(of: item) == NodeAddress("list", path: ["items", "a", "children", "b"]))
    try a.setField(blockID: "list", path: ["items", "a", "children", "b", "checked"], value: .bool(false))
    try a.outdent(item)
    #expect(try a.address(of: item) == NodeAddress("list", path: ["items", "b"]))
    let cell = try a.node(at: NodeAddress("table", path: ["rows", "r1", "cells", "c1"]))
    let row = try a.node(at: NodeAddress("table", path: ["rows", "r2"]))
    try a.moveNode(cell, into: NodeCollection(owner: row, field: "cells"))
    try b.setText(at: TextAddress("table", path: ["rows", "r1", "cells", "c1", "content"]), to: "remote cell")
    try exchange([a, b])
    #expect(try a.address(of: cell) == NodeAddress("table", path: ["rows", "r2", "cells", "c1"]))
    #expect(try a.text(at: a.textAddress(of: cell)) == "remote cell")
    #expect(try a.document.blocks[1].fields["rows"]?.array?.last?["cells"]?.array?.first?["header"] == .bool(true))
}

@Test func protocolCutoverPreservesDocumentAndRejectsMixedVersionsAtomically() throws {
    let baseline = try Document(blocks: [toggle("t", [paragraph("p", "keep")])])
    let old = try EditorSession(documentID: "old", actorID: "a", document: baseline)
    try old.setText(at: TextAddress("t", path: ["children", "p", "content"]), to: "café 😀")
    let upgraded = try ProtocolMigration.cutoverToV2(old.save(), newDocumentID: "new", actorID: "a")
    #expect(upgraded.collaborationVersion == 2)
    #expect(try upgraded.document == old.document)
    #expect(!upgraded.canUndo)
    let before = try upgraded.save()
    #expect(throws: EditorError.unsupportedVersion(1)) { try upgraded.receive(old.changes()) }
    #expect(try upgraded.save() == before)
    #expect(throws: EditorError.unsupportedVersion(2)) { try old.receive(upgraded.changes()) }
    #expect(throws: EditorError.self) { try ProtocolMigration.cutoverToV2(old.save(), newDocumentID: "old", actorID: "a") }
    #expect(throws: EditorError.self) { try old.node(at: NodeAddress("t")) }
    try upgraded.setText(at: TextAddress("t", path: ["children", "p", "content"]), to: "new epoch")
    // Both epochs can contain author a's counter 1. Old receipts must not hide it.
    #expect(upgraded.changes(since: old.syncState).changes.count == 1)
    #expect(upgraded.changes(since: SyncState(received: upgraded.syncState.received)).changes.count == 1)
    #expect(upgraded.changes(since: SyncState(received: upgraded.syncState.received, documentID: "other", version: 2)).changes.count == 1)
    #expect(upgraded.changes(since: upgraded.syncState).changes.isEmpty)
}

@Test func invalidNestedOperationsRejectAtomicallyAndDoNotRewriteIDs() throws {
    let baseline = try Document(blocks: [toggle("left", [paragraph("p", "keep")]), toggle("right", [paragraph("p", "other")])])
    let session = try v2("a", baseline)
    let left = try session.node(at: NodeAddress("left")), right = try session.node(at: NodeAddress("right"))
    let child = try session.node(at: NodeAddress("left", path: ["children", "p"]))
    let before = try session.save()
    #expect(throws: EditorError.self) { try session.moveNode(child, into: NodeCollection(owner: right, field: "children")) }
    #expect(throws: EditorError.self) { try session.moveNode(left, into: NodeCollection(owner: left, field: "children")) }
    #expect(throws: EditorError.self) { try session.setNodeField(child, path: ["id"], value: .string("rewrite")) }
    #expect(throws: EditorError.self) { try session.setNodeField(left, path: ["children"], value: .array([])) }
    #expect(try session.save() == before)
    let id = ChangeID(counter: 10, actor: "remote")
    let mutation = Mutation.moveNode(identity: child, collection: NodeCollection(owner: right, field: "children"),
        placement: ElementID(change: id, index: 0), after: .initial(child))
    #expect(throws: EditorError.self) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
            changes: [Change(id: id, body: .edit([mutation]))], version: 2))
    }
    #expect(try session.save() == before)
    let legacyMutation = Mutation.deleteBlock(blockID: "left")
    #expect(throws: EditorError.invalidChange) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
            changes: [Change(id: id, body: .edit([legacyMutation]))], version: 2))
    }
    #expect(try session.save() == before)
    session.allowedBlockTypes = ["paragraph", "toggle"]
    #expect(throws: EditorError.restrictedBlock("image")) {
        _ = try session.insertNode(.object(try toggle("restricted", [.object(["id": .string("image"), "type": .string("image"), "src": .string("host-asset")])]).fields), into: .root)
    }
    #expect(try session.save() == before)
}
