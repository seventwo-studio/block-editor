@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernProjectionTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
    }

    @Test func allIndependentModernSnapshotsKeepExactJSONThroughSharedProjection() throws {
        var count = 0
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            let expected = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard expected["format"] == .string("seventwo.block-editor.document") else { continue }
            let baseline = try ModernDocument(json: bytes)
            #expect(try ModernProjectionSeed(baseline).document().fields == baseline.fields)
            count += 1
        }
        #expect(count == 55)
    }

    @Test func documentTitleHasAnExplicitOriginOutsideBodyAndConsumerIDs() throws {
        let body = try Block.paragraph(id: "same", text: "body")
        let document = try ModernDocument(documentID: "same", title: "a🧑🏽‍💻é", blocks: [body])
        let seed = ModernProjectionSeed(document)
        let title = seed.title, bodyNode = NodeID.baseline(blockID: "same", path: [])
        #expect(title.node != bodyNode)
        #expect(seed.structure.nodes[title.node]?.kind == .document)
        #expect(try seed.structure.visibleOrder(in: .root) == [bodyNode])
        #expect(seed.atoms.filter { $0.key.origin == title }.count == document.title.unicodeScalars.count)
        #expect(Set(seed.atoms.map(\.key)).count == seed.atoms.count)
        #expect(try JSONDecoder().decode(NodeID.self, from: JSONEncoder().encode(title.node)) == title.node)
        #expect(try seed.document() == document)
    }

    @Test func twoColumnsKeepScopedChildOriginsAndLogicalAddressOrder() throws {
        let child = JSONValue.object(try Block.paragraph(id: "same", text: "preserve").fields)
        let layout = try Block(fields: ["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(7000),
            "columns": .array([.object(["id": .string("first"), "children": .array([child])]),
                .object(["id": .string("second"), "children": .array([child])])])])
        let document = try ModernDocument(documentID: "columns", blocks: [layout]), seed = ModernProjectionSeed(document)
        let layoutID = NodeID.baseline(blockID: "layout", path: [])
        let first = NodeID.baseline(blockID: "layout", path: ["columns", "first"])
        let second = NodeID.baseline(blockID: "layout", path: ["columns", "second"])
        let children = ["first", "second"].map { NodeID.baseline(blockID: "layout", path: ["columns", $0, "children", "same"]) }
        #expect(try seed.structure.visibleOrder(in: NodeCollection(owner: layoutID, field: "columns")) == [first, second])
        #expect(try seed.structure.kind(in: NodeCollection(owner: first, field: "children")) == .block)
        for (index, column) in [first, second].enumerated() {
            #expect(seed.structure.nodes[column]?.kind == .column)
            #expect(try seed.structure.visibleOrder(in: NodeCollection(owner: column, field: "children")) == [children[index]])
            let address = try seed.structure.address(of: children[index])
            #expect(try seed.structure.node(at: address) == children[index])
        }
        #expect(children[0] != children[1])
        #expect(seed.fields.contains(WritingField(node: children[0], name: "content")))
        #expect(seed.fields.contains(WritingField(node: children[1], name: "content")))
        #expect(try seed.document() == document)

        // Legacy columns retain their opaque payload instead of gaining typed children.
        let legacy = StructuralState.seed(try Document(blocks: [layout]))
        #expect(legacy.nodes.count == 1)
        #expect(throws: (any Error).self) { try legacy.kind(in: NodeCollection(owner: layoutID, field: "columns")) }
        #expect(try legacy.document(text: [:]).blocks == [layout])
    }

    @Test func titleReplayAndAuthorDeactivationKeepPeerTextAndBodyIndependent() throws {
        let body = try Block.paragraph(id: "body", text: "unchanged")
        let baseline = try ModernDocument(documentID: "shared", title: "A", blocks: [body]), seed = ModernProjectionSeed(baseline)
        let original = try #require(seed.atoms.first { $0.key.origin == seed.title })
        func append(_ actor: String, _ text: String, after key: WritingAtomKey) -> WritingEdit {
            let id = ChangeID(counter: 1, actor: actor)
            let atom = WritingAtomSeed(key: WritingAtomKey(origin: seed.title, element: ElementID(change: id, index: 0)),
                node: textNode(text), edge: .after(key), route: .follow(key))
            return WritingEdit(id: id, mutations: [.insert(atom)])
        }
        let author = append("author", "B", after: original.key)
        let authorKey = WritingAtomKey(origin: seed.title, element: ElementID(change: author.id, index: 0))
        let peer = append("peer", "🧑", after: authorKey)
        func projected(_ edits: [WritingEdit], active: [ChangeID: Bool] = [:]) throws -> ModernDocument {
            try seed.document(projecting: WritingProjection(seeds: seed.atoms, edits: edits, active: active, emptyFields: seed.fields))
        }
        #expect(try projected([author, peer]) == projected([peer, author]))
        #expect(try projected([author, peer]).title == "AB🧑")
        let undone = try projected([peer, author], active: [author.id: false])
        #expect(undone.title == "A🧑" && undone.blocks == baseline.blocks && undone.appearance == baseline.appearance)
        #expect(try projected([peer, author], active: [author.id: true]).title == "AB🧑")
        let newline = append("newline", "\n", after: original.key)
        #expect(throws: (any Error).self) { try projected([newline]) }
        #expect(try seed.document() == baseline)
    }

    @Test(arguments: [3, 4, 5, 6])
    func legacyWritingProtocolsRejectDocumentOriginsWithoutAcknowledging(_ version: Int) throws {
        let baseline = try Document(blocks: [Block.paragraph(id: "same", text: "unchanged")])
        let session = try WritingSession(documentID: "same", actorID: "local", epoch: "legacy", document: baseline, protocolVersion: version)
        let saved = try session.save(), receipt = session.syncState
        let id = ChangeID(counter: 1, actor: "remote"), field = WritingField(node: .document(documentID: "same"), name: "title")
        let atom = WritingAtomSeed(key: WritingAtomKey(origin: field, element: ElementID(change: id, index: 0)),
            node: textNode("X"), edge: .start, route: .field(field))
        let change = WritingChange(id: id, body: .edit([.text(.insert(atom))]), observed: version == 3 ? nil : [])
        #expect(throws: (any Error).self) { try session.receive(WritingBatch(documentID: "same", epoch: "legacy", baseline: baseline, changes: [change], version: version)) }
        #expect(try session.save() == saved && session.syncState == receipt && session.document == baseline)
        #expect(!session.canUndo && !session.canRedo)
    }

    @Test func legacyStructuralProtocolRejectsDocumentOriginMutationAtomically() throws {
        let baseline = try Document(blocks: [Block.paragraph(id: "same", text: "unchanged")])
        let session = try EditorSession(documentID: "same", actorID: "local", document: baseline, collaborationVersion: 2)
        let saved = try session.save(), receipt = session.syncState
        let change = Change(id: ChangeID(counter: 1, actor: "remote"), body: .edit([
            .setNodeField(identity: .document(documentID: "same"), path: ["title"], value: .string("X"))]))
        #expect(throws: (any Error).self) { try session.receive(ChangeBatch(documentID: "same", baseline: baseline, changes: [change], version: 2)) }
        #expect(try session.save() == saved && session.syncState == receipt && session.document == baseline)
    }
}
