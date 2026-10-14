@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct WritingValueBasisTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
    }

    @Test func checkedBasisMatchesFullProjectionAfterWholeFieldDeletionPeerFormattingAndDeactivation() throws {
        for name in ["columns-rich", "nested-moved", "mixed-code-paste"] {
            let document = try ModernDocument(json: Data(contentsOf: fixtures.appendingPathComponent(name + ".json")))
            let seed = ModernProjectionSeed(document), data = seed.retainedAtoms(seed.births)
            let field = try #require(seed.fields.first { field in field.name == "content" && seed.atoms.contains { $0.key.origin == field } })
            let keys = seed.atoms.filter { $0.key.origin == field }.map(\.key)
            let id = ChangeID(counter: 1, actor: "author"), peer = ChangeID(counter: 2, actor: "peer")
            let peerKeys = seed.atoms.filter { $0.key.origin != field && $0.key.origin.name == "content" && $0.node["type"] == .string("text") }.map(\.key)
            var edits = [WritingEdit(id: id, mutations: [.delete(keys: keys)])]
            if !peerKeys.isEmpty { edits.append(.init(id: peer, mutations: [.format(keys: peerKeys, type: "bold", mark: .object(["type": .string("bold")]))])) }
            for active in [[ChangeID: Bool](), [id: false], [peer: false], [id: false, peer: false]] {
                let indexed = try WritingProjection(seeds: data.atoms, edits: edits, active: active,
                    emptyFields: seed.fields, hiddenSeeds: data.hidden, seedIndex: data.index)
                let full = try WritingProjection(seeds: data.atoms, edits: edits, active: active,
                    emptyFields: seed.fields, hiddenSeeds: data.hidden)
                #expect(indexed.usesIndependentFields)
                for _ in 0..<2 {
                    var fast = seed.structure, ordinary = seed.structure
                    let a = try projectedWritingValues(structure: &fast, projection: indexed, seeds: data.atoms,
                        fields: seed.fields, births: seed.births, retainedOrigins: true, valueOrigins: data.valueOrigins)
                    let b = try projectedWritingValues(structure: &ordinary, projection: full, seeds: data.atoms,
                        fields: seed.fields, births: seed.births, retainedOrigins: true)
                    #expect(a.keys.count == b.keys.count)
                    for (node, value) in a { #expect(try canonicalEncoder().encode(value) == canonicalEncoder().encode(b[node])) }
                    #expect(fast.touched == ordinary.touched)
                    #expect(try fast.visibleOrder(in: .root) == ordinary.visibleOrder(in: .root))
                    #expect(try fast.document(documentID: document.documentID, text: a).json() == ordinary.document(documentID: document.documentID, text: b).json())
                }
            }
            #expect(seed.structure.touched.isEmpty)
        }
    }

    @Test func inactiveBirthPropertyChangesAndForeignSeedOwnersCannotBorrowACompletedBasis() throws {
        let document = try ModernDocument(documentID: "basis", title: "Title", blocks: [Block.paragraph(id: "a", text: "e\u{301}😀"), Block.paragraph(id: "b", text: "Peer")])
        let seed = ModernProjectionSeed(document), data = seed.retainedAtoms(seed.births)
        let field = WritingField(node: .baseline(blockID: "a", path: []), name: "content")
        let projection = try WritingProjection(seeds: data.atoms, edits: [], emptyFields: seed.fields, hiddenSeeds: data.hidden, seedIndex: data.index)
        // Equal field/birth values are insufficient: this foreign index has no
        // visible atoms and would erase activity if the owner check were lost.
        let foreignIndex = try #require(WritingSeedIndex(atoms: [], hiddenKeys: [], fields: seed.fields))
        let foreign = WritingValueOrigins(births: seed.births, index: foreignIndex)
        for variant in 0..<4 {
            var source = seed.structure
            _ = source.checkedWritingValueBasis(try #require(data.valueOrigins))
            if variant == 0 {
                let node = source.nodes[field.node]!
                source.nodes[field.node] = .init(identity: node.identity, kind: node.kind, birthKind: node.birthKind,
                    fields: node.fields, collections: node.collections, birthActive: false)
            } else if variant == 1 { source.nodes[field.node]!.fields[field.name] = .array([textNode("different")]) }
            let fields: Set<WritingField> = variant == 3 ? [field] : seed.fields
            var fast = source, ordinary = source
            let a = try projectedWritingValues(structure: &fast, projection: projection, seeds: data.atoms,
                fields: fields, births: seed.births, retainedOrigins: true, valueOrigins: variant == 2 ? foreign : data.valueOrigins)
            let b = try projectedWritingValues(structure: &ordinary, projection: projection, seeds: data.atoms,
                fields: fields, births: seed.births, retainedOrigins: true)
            #expect(a.keys.count == b.keys.count)
            for (node, value) in a { #expect(try canonicalEncoder().encode(value) == canonicalEncoder().encode(b[node])) }
            #expect(fast.touched == ordinary.touched)
            #expect(try fast.document(documentID: document.documentID, text: a).json() == ordinary.document(documentID: document.documentID, text: b).json())
        }
    }
}
