@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct StructuralReadTests {
    private let a = NodeID.baseline(blockID: "A", path: [])
    private let b = NodeID.baseline(blockID: "B", path: [])
    private func seed() throws -> StructuralState {
        StructuralState.seed(try Document(blocks: [Block.paragraph(id: "A", text: "Alpha 😀"), Block.paragraph(id: "B", text: "Beta")]))
    }

    @Test func independentCopiesKeepOriginalOriginsAndOrderAfterNestedMutation() throws {
        let original = try seed()
        #expect(try original.visibleOrder(in: .root) == [a, b])
        #expect(try original.node(at: NodeAddress("A")) == a)
        var renamed = original
        renamed.nodes[a]!.fields["id"] = .string("Renamed")
        #expect(try renamed.node(at: NodeAddress("Renamed")) == a)
        #expect(throws: EditorError.self) { try renamed.node(at: NodeAddress("A")) }
        #expect(try renamed.address(of: a) == NodeAddress("Renamed"))
        #expect(try original.node(at: NodeAddress("A")) == a)
        #expect(try original.address(of: a) == NodeAddress("A"))

        var moved = original
        moved.placements[.initial(b)] = .init(id: .initial(b), after: nil, node: b, collection: .root, active: true)
        #expect(try moved.visibleOrder(in: .root) == [b, a])
        #expect(try original.visibleOrder(in: .root) == [a, b])
        var deleted = original
        deleted.deleted.insert(b)
        #expect(try deleted.visibleOrder(in: .root) == [a])
        #expect(throws: EditorError.self) { try deleted.address(of: b) }
        #expect(try original.node(at: NodeAddress("B")) == b)
    }

    @Test func untouchedBirthBecomesVisibleWithoutChangingTheEarlierCopy() throws {
        var hidden = try seed()
        let node = hidden.nodes[b]!
        hidden.nodes[b] = .init(identity: b, kind: node.kind, birthKind: node.birthKind,
            fields: node.fields, collections: node.collections, birthActive: false)
        #expect(try hidden.visibleOrder(in: .root) == [a])
        #expect(throws: EditorError.self) { try hidden.node(at: NodeAddress("B")) }
        var peerTouched = hidden
        peerTouched.touched.insert(b)
        #expect(try peerTouched.visibleOrder(in: .root) == [a, b])
        #expect(try peerTouched.node(at: NodeAddress("B")) == b)
        #expect(try hidden.visibleOrder(in: .root) == [a])
    }

    @Test func collectionPlacementIndexRetainsInactiveAnchorsAndDetachesNestedMoves() throws {
        let childA = JSONValue.object(try Block.paragraph(id: "a", text: "A").fields)
        let childB = JSONValue.object(try Block.paragraph(id: "b", text: "B").fields)
        let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([textNode("Left")]), "children": .array([childA, childB])])
        let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([textNode("Right")]), "children": .array([])])
        let original = StructuralState.seed(try ModernDocument(documentID: "groups", blocks: [left, right]))
        let leftID = NodeID.baseline(blockID: "left", path: []), rightID = NodeID.baseline(blockID: "right", path: [])
        let a = NodeID.baseline(blockID: "left", path: ["children", "a"]), b = NodeID.baseline(blockID: "left", path: ["children", "b"])
        let source = NodeCollection(owner: leftID, field: "children"), destination = NodeCollection(owner: rightID, field: "children")
        #expect(try original.visibleOrder(in: source) == [a, b])
        #expect(try original.visibleOrder(in: destination) == [])
        var moved = original
        let old = moved.placements[.initial(a)]!
        moved.placements[.initial(a)] = .init(id: old.id, after: old.after, node: a, collection: source, active: false)
        let placement = NodePlacementID.edit(ElementID(change: ChangeID(counter: 1, actor: "peer"), index: 0))
        moved.placements[placement] = .init(id: placement, after: nil, node: a, collection: destination, active: true)
        #expect(try moved.visibleOrder(in: source) == [b])
        #expect(try moved.visibleOrder(in: destination) == [a])
        #expect(try moved.address(of: b) == NodeAddress("left", path: ["children", "b"]))
        #expect(try moved.address(of: a) == NodeAddress("right", path: ["children", "a"]))
        #expect(try original.visibleOrder(in: source) == [a, b])
        #expect(try original.visibleOrder(in: destination) == [])
    }

    @Test func movedColumnDescendantsResolveTheirOriginalIdentitiesThroughUndoAndReopen() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents/columns-7000.json")
        let document = try ModernDocument(json: Data(contentsOf: path))
        let session = try ModernSession(documentID: document.documentID, actorID: "reader", epoch: "read-1", document: document)
        let originalAddress = NodeAddress("layout", path: ["columns", "first-column", "children", "A"])
        let origin = try session.node(at: originalAddress), field = try session.field(node: origin)
        for _ in 0..<3 { #expect(try session.node(at: originalAddress) == origin); #expect(try session.text(in: field) == "ABC") }
        let second = try session.node(at: NodeAddress("layout", path: ["columns", "second-column"]))
        let after = try session.node(at: NodeAddress("layout", path: ["columns", "second-column", "children", "C"]))
        let target = try session.captureNodes([origin])
        _ = try session.move(ModernMoveTarget(selection: target, boundary: session.captureBoundary(in: NodeCollection(owner: second, field: "children"), after: after)))
        let movedAddress = NodeAddress("layout", path: ["columns", "second-column", "children", "A"])
        #expect(try session.node(at: movedAddress) == origin)
        #expect(throws: EditorError.self) { try session.node(at: originalAddress) }
        #expect(try session.text(in: field) == "ABC")
        try session.undo()
        #expect(session.document == document)
        #expect(try session.node(at: originalAddress) == origin)
        let reopened = try ModernSession.restore(session.save(), actorID: "reader")
        try reopened.redo()
        #expect(try reopened.node(at: movedAddress) == origin)
        #expect(try reopened.text(in: field) == "ABC")
    }
}
