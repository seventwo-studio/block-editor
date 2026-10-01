import BlockEditorCore
import Foundation
import Testing

private func deferredParagraph(_ id: String) throws -> Block {
    try Block(fields: ["id": .string(id), "type": .string("paragraph"), "content": .array([textNode(id)])])
}

@Test(arguments: [false, true])
func dependentPlacementChainsPreserveExistingContentUntilTheirAnchorArrives(nested: Bool) throws {
    let paragraphs = try ["A", "B", "C"].map(deferredParagraph)
    let baseline = try Document(blocks: nested ? [Block(fields: ["id": .string("group"), "type": .string("toggle"),
        "summary": .array([textNode("group")]), "children": .array(paragraphs.map { .object($0.fields) })])] : paragraphs)
    let writer = try EditorSession(documentID: "deferred-chain", actorID: "writer", document: baseline, collaborationVersion: 2)
    let owner = nested ? try writer.node(at: NodeAddress("group")) : nil
    let collection = owner.map { NodeCollection(owner: $0, field: "children") } ?? .root
    let nodes = try ["A", "B", "C"].map { try writer.node(at: nested ? NodeAddress("group", path: ["children", $0]) : NodeAddress($0)) }
    try writer.moveNode(nodes[2], into: collection, after: nodes[0])
    try writer.moveNode(nodes[1], into: collection, after: nodes[2])
    try writer.moveNode(nodes[0], into: collection, after: nodes[1])
    let full = writer.changes()
    for partial in [Array(full.changes.dropFirst()), Array(full.changes.dropFirst().reversed()) + [full.changes[2]]] {
        var peer = try EditorSession(documentID: writer.documentID, actorID: "peer", document: baseline, collaborationVersion: 2)
        let address = try peer.textAddress(of: nodes[0]), caret = try peer.position(at: address, offset: 1)
        try peer.receive(ChangeBatch(documentID: writer.documentID, baseline: baseline, changes: partial, version: 2))
        #expect(try peer.document == baseline)
        #expect(try peer.offset(of: caret) == 1)
        peer = try EditorSession.restore(peer.save(), actorID: peer.actorID)
        #expect(try peer.document == baseline)
        try peer.replaceText(at: address, range: 1..<1, with: "<peer>")
        try peer.receive(full)
        let control = try EditorSession(documentID: writer.documentID, actorID: "control", document: baseline, collaborationVersion: 2)
        try control.receive(peer.changes())
        #expect(try peer.document == control.document)
        #expect(try peer.text(at: address) == "A<peer>")
        try peer.undo()
        #expect(try peer.document == writer.document)
        try peer.redo()
        #expect(try peer.text(at: address) == "A<peer>")
        #expect(try EditorSession.restore(peer.save(), actorID: peer.actorID).document == peer.document)
    }
    // Inactive placements remain ordering anchors after a local-author undo.
    let undo = Change(id: ChangeID(counter: 4, actor: writer.actorID), body: .setActive(target: full.changes[0].id, active: false))
    let peer = try EditorSession(documentID: writer.documentID, actorID: "peer", document: baseline, collaborationVersion: 2)
    try peer.receive(ChangeBatch(documentID: writer.documentID, baseline: baseline, changes: full.changes + [undo], version: 2))
    #expect(Set(try peer.nodes(in: collection)) == Set(nodes))
}

@Test func aMoveIntoAnUnanchoredCausalOwnerKeepsItsPreviousPlacement() throws {
    let baseline = try Document(blocks: [deferredParagraph("A"), deferredParagraph("B")])
    let writer = try EditorSession(documentID: "deferred-owner", actorID: "writer", document: baseline, collaborationVersion: 2)
    let a = try writer.node(at: NodeAddress("A"))
    let w = try writer.insertNode(.object(["id": .string("W"), "type": .string("toggle"), "summary": .array([textNode("W")]), "children": .array([])]), into: .root, after: a)
    let p = try writer.insertNode(.object(["id": .string("P"), "type": .string("toggle"), "summary": .array([textNode("P")]), "children": .array([])]), into: .root, after: w)
    try writer.moveNode(a, into: NodeCollection(owner: p, field: "children"))
    let full = writer.changes()
    let peer = try EditorSession(documentID: writer.documentID, actorID: "peer", document: baseline, collaborationVersion: 2)
    let address = try peer.textAddress(of: a), caret = try peer.position(at: address, offset: 1)
    try peer.receive(ChangeBatch(documentID: writer.documentID, baseline: baseline, changes: Array(full.changes.dropFirst()), version: 2))
    #expect(try peer.document == baseline)
    #expect(try peer.offset(of: caret) == 1)
    #expect(try EditorSession.restore(peer.save(), actorID: peer.actorID).document == baseline)
    try peer.receive(full)
    #expect(try peer.document == writer.document)
    #expect(try peer.offset(of: caret) == 1)
    #expect(try peer.address(of: a) == NodeAddress("P", path: ["children", "A"]))
}

@Test(arguments: [false, true])
func inactiveMovesStillRejectKnownAnchorsFromAnotherCollection(editedAnchor: Bool) throws {
    let baseline = try Document(blocks: [deferredParagraph("A"), deferredParagraph("B"),
        Block(fields: ["id": .string("T"), "type": .string("toggle"), "summary": .array([textNode("T")]),
                       "children": .array([.object(deferredParagraph("X").fields)])])])
    let a = NodeID.baseline(blockID: "A", path: []), t = NodeID.baseline(blockID: "T", path: [])
    let x = NodeID.baseline(blockID: "T", path: ["children", "X"])
    let earlierID = ChangeID(counter: 1, actor: "writer"), badID = ChangeID(counter: 2, actor: "writer")
    let earlier = Change(id: earlierID, body: .edit([.moveNode(identity: x, collection: NodeCollection(owner: t, field: "children"),
        placement: ElementID(change: earlierID, index: 0), after: nil)]))
    let anchor = editedAnchor ? NodePlacementID.edit(ElementID(change: earlierID, index: 0)) : .initial(x)
    let bad = Change(id: badID, body: .edit([.moveNode(identity: a, collection: .root,
        placement: ElementID(change: badID, index: 0), after: anchor)]))
    let disabled = Change(id: ChangeID(counter: 3, actor: "writer"), body: .setActive(target: badID, active: false))
    let full = (editedAnchor ? [earlier] : []) + [bad, disabled]
    for pending in [false, true] {
        for delayed in [false, true] {
            let peer = try EditorSession(documentID: "inactive-collection", actorID: "local", document: baseline, collaborationVersion: 2)
            if pending {
                let collider = try EditorSession(documentID: peer.documentID, actorID: "collider", document: baseline, collaborationVersion: 2)
                try peer.insert(deferredParagraph("collision")); try collider.insert(deferredParagraph("collision"))
                #expect(throws: EditorError.self) { try peer.receive(collider.changes()) }
                #expect(peer.mergeRecovery != nil)
            }
            if editedAnchor && delayed {
                // Unknown earlier anchors remain deferred; their arrival supplies
                // enough information to reject the malformed later placement.
                let partial = ChangeBatch(documentID: peer.documentID, baseline: baseline, changes: [disabled, bad], version: 2)
                if pending { #expect(throws: EditorError.self) { try peer.receive(partial) } }
                else { try peer.receive(partial) }
            }
            let saved = try peer.save(), receipts = peer.syncState, recovery = peer.mergeRecovery, document = try peer.document
            var prepared = false; peer.onWillReceive = { prepared = true }
            let delivered = delayed ? Array(full.reversed()) + [disabled, bad] : full
            #expect(throws: EditorError.invalidChange) {
                try peer.receive(ChangeBatch(documentID: peer.documentID, baseline: baseline, changes: delivered, version: 2))
            }
            #expect(try peer.save() == saved); #expect(peer.syncState == receipts)
            #expect(peer.mergeRecovery == recovery); #expect(try peer.document == document); #expect(!prepared)
        }
    }
}
