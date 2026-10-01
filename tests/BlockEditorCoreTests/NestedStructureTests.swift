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

@Test func sameChangePlacementCyclesAreRejectedWithoutAcknowledgmentOrContentLoss() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Keep me")])
    let session = try EditorSession(documentID: "placement-cycle", actorID: "local", document: baseline, collaborationVersion: 2)
    let id = ChangeID(counter: 1, actor: "remote")
    let first = ElementID(change: id, index: 0), second = ElementID(change: id, index: 1)
    let mutations: [Mutation] = [
        .insertNode(value: .object(try Block.paragraph(id: "first", text: "Alice").fields),
            identity: .inserted(creation: first, path: []), collection: .root, placement: first, after: .edit(second)),
        .insertNode(value: .object(try Block.paragraph(id: "second", text: "Bob").fields),
            identity: .inserted(creation: second, path: []), collection: .root, placement: second, after: .edit(first)),
    ]
    let before = try session.save(), receipts = session.syncState
    var prepared = false
    session.onWillReceive = { prepared = true }
    #expect(throws: EditorError.invalidChange) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
            changes: [Change(id: id, body: .edit(mutations))], version: 2))
    }
    #expect(try session.save() == before)
    #expect(session.syncState == receipts)
    #expect(session.mergeRecovery == nil)
    #expect(!prepared)
    // A correctly ordered multi-insert under the same ID is accepted after rejection.
    let valid: [Mutation] = [
        .insertNode(value: .object(try Block.paragraph(id: "first", text: "Alice").fields),
            identity: .inserted(creation: first, path: []), collection: .root, placement: first, after: nil),
        .insertNode(value: .object(try Block.paragraph(id: "second", text: "Bob").fields),
            identity: .inserted(creation: second, path: []), collection: .root, placement: second, after: .edit(first)),
    ]
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
        changes: [Change(id: id, body: .edit(valid))], version: 2))
    #expect(try session.document.blocks.map(\.id) == ["first", "second", "p"])
    #expect(session.syncState.received.contains(id))
    #expect(try EditorSession.restore(session.save(), actorID: "local").document == session.document)
}

@Test(arguments: [1, 2]) func sameChangeMovesCannotHideExistingContentInAnAnchorCycle(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Alice"), .paragraph(id: "q", text: "Bob")])
    let session = try EditorSession(documentID: "move-cycle", actorID: "local", document: baseline, collaborationVersion: version)
    let id = ChangeID(counter: 1, actor: "remote")
    let first = ElementID(change: id, index: 0), second = ElementID(change: id, index: 1)
    let mutations: [Mutation]
    if version == 1 {
        mutations = [.moveBlock(blockID: "p", placement: first, after: second),
                     .moveBlock(blockID: "q", placement: second, after: first)]
    } else {
        mutations = [.moveNode(identity: .baseline(blockID: "p", path: []), collection: .root, placement: first, after: .edit(second)),
                     .moveNode(identity: .baseline(blockID: "q", path: []), collection: .root, placement: second, after: .edit(first))]
    }
    let before = try session.save()
    #expect(throws: EditorError.invalidChange) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
            changes: [Change(id: id, body: .edit(mutations))], version: version))
    }
    #expect(try session.save() == before)
    #expect(try session.document == baseline)
    #expect(session.syncState.received.isEmpty)
}

@Test(arguments: [1, 2]) func sameChangeTextAnchorsCannotNamePlacementsOrAnotherField(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Alice"), .paragraph(id: "q", text: "Bob")])
    let session = try EditorSession(documentID: "text-anchor-kind", actorID: "local", document: baseline, collaborationVersion: version)
    let p = try session.textAddressForTest("p", version: version)
    let q = try session.textAddressForTest("q", version: version)
    let id = ChangeID(counter: 1, actor: "remote")
    let first = ElementID(change: id, index: 0), second = ElementID(change: id, index: 1)
    let node = JSONValue.object(["type": .string("text"), "text": .string("X"), "marks": .array([])])
    let move: Mutation = version == 1 ? .moveBlock(blockID: "p", placement: first, after: nil)
        : .moveNode(identity: .baseline(blockID: "p", path: []), collection: .root, placement: first, after: nil)
    for prefix in [move, .insertText(address: q, atoms: [TextAtom(id: first, after: nil, node: node)])] {
        let session = try EditorSession(documentID: "text-anchor-kind", actorID: "local", document: baseline, collaborationVersion: version)
        let before = try session.save()
        let mutations: [Mutation] = [prefix, .insertText(address: p, atoms: [TextAtom(id: second, after: first, node: node)])]
        #expect(throws: EditorError.invalidChange) {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
                changes: [Change(id: id, body: .edit(mutations))], version: version))
        }
        #expect(try session.save() == before)
        #expect(session.syncState.received.isEmpty)
    }
}

private extension EditorSession {
    func textAddressForTest(_ blockID: String, version: Int) throws -> TextAddress {
        if version == 1 { return TextAddress(blockID) }
        return try textAddress(of: node(at: NodeAddress(blockID)))
    }
}

@Test(arguments: [false, true])
func impossibleSameChangeNodePathsAndInitialAnchorsRejectAtomically(deferredParent: Bool) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Keep me")])
    let id = ChangeID(counter: 2, actor: "remote")
    let creation = ElementID(change: id, index: 0), next = ElementID(change: id, index: 1)
    let root = NodeID.inserted(creation: creation, path: [])
    let missing = NodeID.inserted(creation: creation, path: ["children", "missing"])
    let collection = deferredParent ? NodeCollection(owner: .inserted(creation: ElementID(change: ChangeID(counter: 1, actor: "remote"), index: 0), path: []), field: "children") : .root
    let prefix = Mutation.insertNode(value: .object(try toggle("new", [paragraph("child", "Existing child")]).fields),
        identity: root, collection: collection, placement: creation, after: nil)
    let suffixes: [Mutation] = [
        // Inserted roots only have edit placements; this initial anchor never exists.
        .insertNode(value: paragraph("lost", "Must not disappear"), identity: .inserted(creation: next, path: []),
            collection: .root, placement: next, after: .initial(root)),
        // The complete creation payload never introduced this descendant.
        .insertNode(value: paragraph("lost", "Must not disappear"), identity: .inserted(creation: next, path: []),
            collection: NodeCollection(owner: missing, field: "children"), placement: next, after: nil),
        .moveNode(identity: .baseline(blockID: "p", path: []), collection: NodeCollection(owner: missing, field: "children"),
            placement: next, after: nil),
        .insertText(address: missing.textAddressForTest(), atoms: [TextAtom(id: next, after: nil, node: textNode("X"))]),
    ]
    for suffix in suffixes {
        let session = try EditorSession(documentID: "impossible-reference", actorID: "local", document: baseline, collaborationVersion: 2)
        let saved = try session.save(), receipts = session.syncState
        var prepared = false
        session.onWillReceive = { prepared = true }
        #expect(throws: EditorError.self) {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
                changes: [Change(id: id, body: .edit([prefix, suffix]))], version: 2))
        }
        #expect(try session.save() == saved)
        #expect(try session.document == baseline)
        #expect(session.syncState == receipts)
        #expect(session.mergeRecovery == nil)
        #expect(!prepared)
    }
}

private extension NodeID {
    func textAddressForTest() -> TextAddress {
        switch self {
        case .baseline(let blockID, let path): return TextAddress(blockID, path: path + ["content"], identity: self)
        case .inserted(let creation, let path): return TextAddress("@\(creation.change.actor)/\(creation.change.counter)/\(creation.index)", path: path + ["content"], identity: self)
        }
    }
}

@Test(arguments: [0, 1, 2])
func impossiblePriorCreationPathsRejectAtomically(delivery: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Keep me")])
    let prior = ChangeID(counter: 2, actor: "remote"), later = ChangeID(counter: 3, actor: "remote")
    let creation = ElementID(change: prior, index: 0), next = ElementID(change: later, index: 0)
    let missing = NodeID.inserted(creation: creation, path: ["children", "missing"])
    let owner = NodeID.inserted(creation: ElementID(change: ChangeID(counter: 1, actor: "remote"), index: 0), path: [])
    let prefix = Change(id: prior, body: .edit([
        .insertNode(value: .object(try toggle("new", [paragraph("child", "Original")]).fields),
            identity: .inserted(creation: creation, path: []), collection: delivery == 2 ? NodeCollection(owner: owner, field: "children") : .root,
            placement: creation, after: nil),
    ]))
    let invalid: [Mutation] = [
        .insertNode(value: paragraph("lost", "Must not disappear"), identity: .inserted(creation: next, path: []),
            collection: NodeCollection(owner: missing, field: "children"), placement: next, after: nil),
        .moveNode(identity: .baseline(blockID: "p", path: []), collection: NodeCollection(owner: missing, field: "children"), placement: next, after: nil),
        .insertText(address: missing.textAddressForTest(), atoms: [TextAtom(id: next, after: nil, node: textNode("X"))]),
        .deleteNodes(identities: [missing]),
        .setNodeField(identity: missing, path: ["hostFlag"], value: .bool(true)),
        .insertNode(value: paragraph("lost", "Must not disappear"), identity: .inserted(creation: next, path: []),
            collection: .root, placement: next, after: .initial(missing)),
    ]
    for mutation in invalid {
        let session = try EditorSession(documentID: "prior-created-paths", actorID: "local", document: baseline, collaborationVersion: 2)
        if delivery != 1 { try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [prefix], version: 2)) }
        let saved = try session.save(), receipts = session.syncState, accepted = try session.document
        var prepared = false
        session.onWillReceive = { prepared = true }
        let bad = Change(id: later, body: .edit([mutation]))
        #expect(throws: EditorError.invalidChange) {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
                changes: delivery == 1 ? [bad, prefix] : [bad], version: 2))
        }
        #expect(try session.save() == saved)
        #expect(try session.document == accepted)
        #expect(session.syncState == receipts)
        #expect(session.mergeRecovery == nil)
        #expect(!prepared)
    }
}

@Test func knownPriorElementsMustHaveTheReferencedKindAndField() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "P"), .paragraph(id: "q", text: "Q")])
    let p = NodeID.baseline(blockID: "p", path: []), q = NodeID.baseline(blockID: "q", path: [])
    let prior = ChangeID(counter: 1, actor: "remote"), later = ChangeID(counter: 2, actor: "remote")
    let textP = ElementID(change: prior, index: 0), textQ = ElementID(change: prior, index: 1)
    let missing = ElementID(change: prior, index: 99), next = ElementID(change: later, index: 0)
    let prefix = Change(id: prior, body: .edit([
        .insertText(address: p.textAddressForTest(), atoms: [TextAtom(id: textP, after: nil, node: textNode("A"))]),
        .insertText(address: q.textAddressForTest(), atoms: [TextAtom(id: textQ, after: nil, node: textNode("B"))]),
    ]))
    let invalid: [Mutation] = [
        .moveNode(identity: p, collection: .root, placement: next, after: .edit(textP)),
        .deleteNodes(identities: [.inserted(creation: textP, path: [])]),
        .insertText(address: p.textAddressForTest(), atoms: [TextAtom(id: next, after: textQ, node: textNode("X"))]),
        .deleteText(address: p.textAddressForTest(), ids: [textQ]),
        .formatText(address: p.textAddressForTest(), ids: [textQ], markType: "bold", mark: .object(["type": .string("bold")])),
        .insertText(address: p.textAddressForTest(), atoms: [TextAtom(id: next, after: missing, node: textNode("X"))]),
        .deleteNodes(identities: [.baseline(blockID: "p", path: ["children", "missing"])]),
    ]
    for mutation in invalid {
        let session = try EditorSession(documentID: "prior-element-types", actorID: "local", document: baseline, collaborationVersion: 2)
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [prefix], version: 2))
        let saved = try session.save(), receipts = session.syncState
        var prepared = false
        session.onWillReceive = { prepared = true }
        #expect(throws: EditorError.invalidChange) {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
                changes: [Change(id: later, body: .edit([mutation]))], version: 2))
        }
        #expect(try session.save() == saved)
        #expect(session.syncState == receipts)
        #expect(!prepared)
    }
}

@Test func insertedDescendantInitialPlacementsAndCausalReorderingRemainValid() throws {
    let baseline = try Document(blocks: [])
    let source = try EditorSession(documentID: "valid-created-paths", actorID: "remote", document: baseline, collaborationVersion: 2)
    let root = try source.insertNode(.object(try toggle("root", [paragraph("embedded", "Original")]).fields), into: .root)
    let child = try source.node(at: NodeAddress("root", path: ["children", "embedded"]))
    _ = try source.insertNode(paragraph("later", "Later"), into: NodeCollection(owner: root, field: "children"), after: child)
    let changes = source.changes().changes
    let peer = try EditorSession(documentID: source.documentID, actorID: "peer", document: baseline, collaborationVersion: 2)
    try peer.receive(ChangeBatch(documentID: source.documentID, baseline: baseline, changes: [changes[1]], version: 2))
    #expect(try peer.document.blocks.isEmpty)
    try peer.receive(ChangeBatch(documentID: source.documentID, baseline: baseline, changes: [changes[0]], version: 2))
    #expect(try peer.document == source.document)

    let id = ChangeID(counter: 1, actor: "transaction")
    let creation = ElementID(change: id, index: 0), next = ElementID(change: id, index: 1)
    let owner = NodeID.inserted(creation: creation, path: [])
    let embedded = NodeID.inserted(creation: creation, path: ["children", "embedded"])
    let mutations: [Mutation] = [
        .insertNode(value: .object(try toggle("root", [paragraph("embedded", "Original")]).fields), identity: owner,
            collection: .root, placement: creation, after: nil),
        .insertNode(value: paragraph("later", "Later"), identity: .inserted(creation: next, path: []),
            collection: NodeCollection(owner: owner, field: "children"), placement: next, after: .initial(embedded)),
    ]
    let together = try EditorSession(documentID: source.documentID, actorID: "together", document: baseline, collaborationVersion: 2)
    try together.receive(ChangeBatch(documentID: source.documentID, baseline: baseline, changes: [Change(id: id, body: .edit(mutations))], version: 2))
    #expect(try together.document == source.document)
    #expect(try EditorSession.restore(together.save(), actorID: "together").document == source.document)
}

@Test(arguments: ["host-metadata", "math", "toggle"])
func createdListDescendantsRetainOpaqueTypeMetadata(metadataType: String) throws {
    let item: JSONValue = .object(["id": .string("parent"), "content": .array([textNode("Parent")]), "children": .array([])])
    let baseline = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"),
        "style": .string("unordered"), "items": .array([item])])])
    let id = ChangeID(counter: 1, actor: "remote")
    let creation = ElementID(change: id, index: 0), text = ElementID(change: id, index: 1)
    let root = NodeID.inserted(creation: creation, path: [])
    let descendant = NodeID.inserted(creation: creation, path: ["children", "embedded"])
    let payload: JSONValue = .object(["id": .string("new"), "type": .string(metadataType),
        "content": .array([textNode("New")]), "children": .array([
            .object(["id": .string("embedded"), "content": .array([textNode("Child")])])])])
    let session = try EditorSession(documentID: "metadata-list", actorID: "local", document: baseline, collaborationVersion: 2)
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [Change(id: id, body: .edit([
        .insertNode(value: payload, identity: root,
            collection: NodeCollection(owner: .baseline(blockID: "list", path: ["items", "parent"]), field: "children"),
            placement: creation, after: nil),
        .insertText(address: descendant.textAddressForTest(), atoms: [TextAtom(id: text, after: nil, node: textNode("X"))]),
    ]))], version: 2))
    #expect(try session.text(at: session.textAddress(of: descendant)) == "XChild")
    #expect(try session.document.blocks[0].fields["items"]?.array?[0]["children"]?.array?[0]["type"] == .string(metadataType))

    let prior = ChangeID(counter: 1, actor: "parent"), later = ChangeID(counter: 2, actor: "remote")
    let parentCreation = ElementID(change: prior, index: 0), childCreation = ElementID(change: later, index: 0)
    let empty = try Document(blocks: [])
    let deferred = try EditorSession(documentID: "metadata-deferred", actorID: "local", document: empty, collaborationVersion: 2)
    let nested = NodeID.inserted(creation: childCreation, path: ["children", "embedded"])
    let parentID = NodeID.inserted(creation: parentCreation, path: ["items", "parent"])
    try deferred.receive(ChangeBatch(documentID: deferred.documentID, baseline: empty, changes: [Change(id: later, body: .edit([
        .insertNode(value: payload, identity: .inserted(creation: childCreation, path: []),
            collection: NodeCollection(owner: parentID, field: "children"), placement: childCreation, after: nil),
        .insertText(address: nested.textAddressForTest(), atoms: [TextAtom(id: ElementID(change: later, index: 1), after: nil, node: textNode("X"))]),
    ]))], version: 2))
    #expect(try deferred.document.blocks.isEmpty)
    try deferred.receive(ChangeBatch(documentID: deferred.documentID, baseline: empty, changes: [Change(id: prior, body: .edit([
        .insertNode(value: .object(baseline.blocks[0].fields), identity: .inserted(creation: parentCreation, path: []),
            collection: .root, placement: parentCreation, after: nil),
    ]))], version: 2))
    #expect(try deferred.document == session.document)
    #expect(try EditorSession.restore(deferred.save(), actorID: "local").document == session.document)
}
