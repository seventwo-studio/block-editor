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
