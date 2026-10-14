@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernNodeBindingTests {
    @Test func bindingsContainOnlyLiveSchemaOriginsAndRetainSameValueReplacementThroughUndo() throws {
        let child = try Block.paragraph(id: "same", text: "A😀")
        let layout = try Block(fields: ["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(5000),
            "columns": .array([.object(["id": .string("left"), "children": .array([.object(child.fields)])]),
                .object(["id": .string("right"), "children": .array([])])]),
            "consumer": .object(["rows": .array([.object(["id": .string("opaque"), "type": .string("heading")])])])])
        let document = try ModernDocument(documentID: "bindings", blocks: [layout])
        let session = try ModernSession(documentID: document.documentID, actorID: "writer", epoch: "epoch", document: document)
        let saved = try session.save(), initial = try session.nodeBindings()
        #expect(initial.map(\.kind) == ["block", "column", "block", "column"])
        #expect(initial.map(\.address) == [NodeAddress("layout"), NodeAddress("layout", path: ["columns", "left"]),
            NodeAddress("layout", path: ["columns", "left", "children", "same"]), NodeAddress("layout", path: ["columns", "right"])])
        for binding in initial {
            #expect(try session.node(at: binding.address) == binding.node)
            for (name, field) in binding.fields { #expect(try session.field(node: binding.node, name: name) == field) }
        }
        #expect(initial[2].fields.keys.sorted() == ["content"])
        #expect(initial[0].fields.isEmpty && initial[1].fields.isEmpty)
        #expect(try session.save() == saved)
        let origin = initial[2].node, left = initial[1].node
        let peer = try ModernSession(documentID: document.documentID, actorID: "peer", epoch: "epoch", document: document)
        _ = try peer.delete(ModernDeleteTarget(nodes: peer.captureNodes([origin])))
        _ = try peer.insertBlock(child, at: peer.captureBoundary(in: NodeCollection(owner: left, field: "children")))
        try session.receive(peer.changes())
        #expect(try session.document.json() == document.json())
        let replacement = try #require(session.nodeBindings().first { $0.address == initial[2].address })
        #expect(replacement.node != origin)
        let field = try session.field(node: replacement.node)
        _ = try session.replaceText(in: session.captureTextRange(in: field, start: 0, end: 1), with: "X")
        try session.undo()
        #expect(try session.document.json() == document.json())
        #expect(try session.nodeBindings().first { $0.address == replacement.address }?.node == replacement.node)
        let reopened = try ModernSession.restore(session.save(), actorID: "writer")
        #expect(try reopened.nodeBindings().first { $0.address == replacement.address }?.node == replacement.node)
    }
}
