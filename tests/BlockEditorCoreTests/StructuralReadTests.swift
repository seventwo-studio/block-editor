@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct StructuralReadTests {
    private let a = NodeID.baseline(blockID: "A", path: [])
    private let b = NodeID.baseline(blockID: "B", path: [])
    private func seed() throws -> StructuralState {
        StructuralState.seed(try Document(blocks: [Block.paragraph(id: "A", text: "Alpha 😀"), Block.paragraph(id: "B", text: "Beta")]))
    }
    @Test func columnMetadataDetachesPresentationButMatchesFullMutationAndProjection() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents/columns-rich.json")
        let document = try ModernDocument(json: Data(contentsOf: path)), seed = ModernProjectionSeed(document)
        let data = seed.retainedAtoms(seed.births), layout = NodeID.baseline(blockID: document.blocks[0].id, path: [])
        let indexed = try WritingProjection(seeds: data.atoms, edits: [], emptyFields: seed.fields, hiddenSeeds: data.hidden, seedIndex: data.index)
        let full = try WritingProjection(seeds: data.atoms, edits: [], emptyFields: seed.fields, hiddenSeeds: data.hidden)
        for hiddenBirth in [false, true] {
            var original = seed.structure
            if hiddenBirth {
                let node = original.nodes[layout]!
                original.nodes[layout] = .init(identity: node.identity, kind: node.kind, birthKind: node.birthKind,
                    fields: node.fields, collections: node.collections, birthActive: false)
            }
            let oldOrder = try original.visibleOrder(in: .root)
            _ = try original.cutoverAddresses(); _ = original.retainedWritingBirths()
            _ = original.checkedWritingValueBasis(try #require(data.valueOrigins))
            let oldLease = original.renderingReadLease
            var fast = original, ordinary = Materialized(); ordinary.structure = original
            try fast.setModernColumnSplit(layout, to: 1000)
            try apply([.setNodeField(identity: layout, path: ["splitBasisPoints"], value: .number(1000))], enabled: true, to: &ordinary)
            #expect(fast.renderingReadLease !== oldLease)
            var slow = try #require(ordinary.structure)
            let a = try projectedWritingValues(structure: &fast, projection: indexed, seeds: data.atoms,
                fields: seed.fields, births: seed.births, retainedOrigins: true, valueOrigins: data.valueOrigins)
            let b = try projectedWritingValues(structure: &slow, projection: full, seeds: data.atoms,
                fields: seed.fields, births: seed.births, retainedOrigins: true)
            var expected = document.fields, blocks = document.blocks.map { JSONValue.object($0.fields) }, first = blocks[0].object!
            first["splitBasisPoints"] = .number(1000); blocks[0] = .object(first); expected["blocks"] = .array(blocks)
            #expect(try fast.document(documentID: document.documentID, text: a) == ModernDocument(fields: expected))
            #expect(try fast.document(documentID: document.documentID, text: a) == slow.document(documentID: document.documentID, text: b))
            #expect(fast.touched == slow.touched)
            #expect(try fast.cutoverAddresses() == slow.cutoverAddresses())
            #expect(try original.visibleOrder(in: .root) == oldOrder)
            #expect(original.nodes[layout]?.fields["splitBasisPoints"] == document.blocks[0].fields["splitBasisPoints"])
        }
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

    @Test func writingActivityPreservesActiveViewsButRevealsInactiveBirthsAndKeepsCopiesIndependent() throws {
        var original = try seed()
        let node = original.nodes[b]!
        original.nodes[b] = .init(identity: b, kind: node.kind, birthKind: node.birthKind,
            fields: node.fields, collections: node.collections, birthActive: false)
        #expect(try original.visibleOrder(in: .root) == [a])
        #expect(try original.address(of: a) == NodeAddress("A"))
        var retained = original
        retained.retainWritingActivity(of: a)
        #expect(retained.touched.contains(a))
        #expect(!original.touched.contains(a))
        #expect(try retained.visibleOrder(in: .root) == [a])
        retained.retainWritingActivity(of: a)
        retained.retainWritingActivity(of: b)
        #expect(try retained.visibleOrder(in: .root) == [a, b])
        #expect(try retained.address(of: b) == NodeAddress("B"))
        #expect(try original.visibleOrder(in: .root) == [a])
        #expect(throws: EditorError.self) { try original.address(of: b) }
        retained.nodes[a]!.fields["id"] = .string("Renamed")
        #expect(try retained.address(of: a) == NodeAddress("Renamed"))
        #expect(try original.address(of: a) == NodeAddress("A"))
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
