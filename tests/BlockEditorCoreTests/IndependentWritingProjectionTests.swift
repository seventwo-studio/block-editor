@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct IndependentWritingProjectionTests {
    private let a = WritingField(node: .baseline(blockID: "a", path: []), name: "content")
    private let b = WritingField(node: .baseline(blockID: "b", path: []), name: "content")
    private let empty = WritingField(node: .baseline(blockID: "empty", path: []), name: "content")
    private func baseline() -> (atoms: [WritingAtomSeed], hidden: Set<WritingAtomKey>) {
        seedWritingAtoms([a: WritingFieldBirth(value: .array([textNode("A😀")]), active: true),
            b: WritingFieldBirth(value: .array([textNode("世界")]), active: true),
            empty: WritingFieldBirth(value: .array([]), active: true)])
    }
    private func exact(_ values: [JSONValue]) throws -> Data { try canonicalEncoder().encode(values) }

    @Test func independentFieldsPreserveLiteralPeerTextMarksTombstonesAndAuthorDeactivation() throws {
        let seed = baseline(), fields: Set<WritingField> = [a, b, empty]
        let index = try #require(WritingSeedIndex(atoms: seed.atoms, hiddenKeys: seed.hidden, fields: fields))
        let emoji = try #require(seed.atoms.first { $0.key.origin == a && $0.key.element.index == 1 })
        let world = try #require(seed.atoms.first { $0.key.origin == b && $0.key.element.index == 0 })
        let peer = ChangeID(counter: 1, actor: "peer"), author = ChangeID(counter: 2, actor: "author")
        let e = WritingAtomKey(origin: a, element: ElementID(change: peer, index: 0))
        let accent = WritingAtomKey(origin: a, element: ElementID(change: peer, index: 1))
        let edits = [WritingEdit(id: peer, mutations: [
            .insert(.init(key: e, node: textNode("e"), edge: .after(emoji.key), route: .follow(emoji.key))),
            .insert(.init(key: accent, node: textNode("\u{301}"), edge: .after(e), route: .follow(e))),
            .format(keys: [world.key], type: "bold", mark: .object(["type": .string("bold")]))]),
            WritingEdit(id: author, mutations: [.delete(keys: [emoji.key])])]
        for (active, expectedA, expectedBold) in [([ChangeID: Bool](), "Ae\u{301}", true),
            ([author: false], "A😀e\u{301}", true), ([peer: false], "A", false), ([author: false, peer: false], "A😀", false)] {
            let scoped = try WritingProjection(seeds: seed.atoms, edits: edits, active: active, emptyFields: fields, seedIndex: index)
            let full = try WritingProjection(seeds: seed.atoms, edits: edits, active: active, emptyFields: fields)
            #expect(scoped.usesIndependentFields)
            #expect(Array(scoped.text(in: a).utf8) == Array(expectedA.utf8))
            #expect(scoped.text(in: b) == "世界" && scoped.text(in: empty).isEmpty)
            #expect(scoped.nodes(in: b).first?["marks"] == .array(expectedBold ? [.object(["type": .string("bold")])] : []))
            #expect(scoped.retainedKeys == full.retainedKeys)
            for field in fields {
                #expect(scoped.visibleKeys(in: field) == full.visibleKeys(in: field))
                #expect(try exact(scoped.nodes(in: field)) == exact(full.nodes(in: field)))
                #expect(try scoped.startOffset(of: field) == full.startOffset(of: field))
            }
            for key in scoped.retainedKeys {
                #expect(scoped.containsRetainedKey(key) && full.containsRetainedKey(key))
                #expect(try scoped.field(of: key) == full.field(of: key))
                #expect(try scoped.offset(of: key, affinity: .before) == full.offset(of: key, affinity: .before))
                #expect(try scoped.offset(of: key, affinity: .after) == full.offset(of: key, affinity: .after))
                #expect(try scoped.retainedOffset(of: key, affinity: .after) == full.retainedOffset(of: key, affinity: .after))
            }
            let unknown = WritingAtomKey(origin: a, element: ElementID(change: .init(counter: 9, actor: "unknown"), index: 0))
            let head = WritingAtomKey(origin: a, element: ElementID(change: .init(counter: 0, actor: ""), index: -1))
            #expect(!scoped.containsRetainedKey(unknown) && !full.containsRetainedKey(unknown))
            #expect(!scoped.containsRetainedKey(head) && !full.containsRetainedKey(head))
        }
        #expect(index.projections[a]?.text(in: a) == "A😀")
        #expect(index.projections[b]?.nodes(in: b).first?["marks"] == .array([]))
    }

    @Test func crossFieldEdgesTransfersAndJoinsKeepTheFullGraphPath() throws {
        let seed = baseline(), fields: Set<WritingField> = [a, b, empty]
        let index = try #require(WritingSeedIndex(atoms: seed.atoms, hiddenKeys: seed.hidden, fields: fields))
        let first = try #require(seed.atoms.first { $0.key.origin == a && $0.key.element.index == 0 })
        let lastB = try #require(seed.atoms.first { $0.key.origin == b && $0.key.element.index == 1 })
        let id = ChangeID(counter: 1, actor: "peer")
        let foreign = WritingAtomKey(origin: a, element: ElementID(change: id, index: 0))
        for mutations: [WritingMutation] in [
            [.transfer(keys: [first.key], destination: b, edge: .start)],
            [.join(source: a, destination: b, edge: .after(lastB.key))],
            [.insert(.init(key: foreign, node: textNode("X"), edge: .after(lastB.key), route: .follow(lastB.key)))]] {
            let edit = WritingEdit(id: id, mutations: mutations)
            let scoped = try WritingProjection(seeds: seed.atoms, edits: [edit], emptyFields: fields, seedIndex: index)
            let full = try WritingProjection(seeds: seed.atoms, edits: [edit], emptyFields: fields)
            #expect(!scoped.usesIndependentFields)
            for field in fields { #expect(try exact(scoped.nodes(in: field)) == exact(full.nodes(in: field))) }
            #expect(scoped.retainedKeys == full.retainedKeys)
        }
    }

    @Test func checkedFieldRebuildRejectsMissingDuplicateAndCyclicAtomsWithoutChangingTheBaseline() throws {
        let seed = baseline(), fields: Set<WritingField> = [a, b, empty]
        let index = try #require(WritingSeedIndex(atoms: seed.atoms, hiddenKeys: seed.hidden, fields: fields))
        let original = try #require(seed.atoms.first { $0.key.origin == a })
        let id = ChangeID(counter: 1, actor: "bad")
        let missing = WritingAtomKey(origin: a, element: ElementID(change: id, index: 99))
        let cycle = WritingAtomSeed(key: missing, node: textNode("X"), edge: .after(missing), route: .follow(missing))
        for (mutation, expected) in [(WritingMutation.delete(keys: [missing]), WritingProjectionError.missingAtom),
            (.insert(original), .duplicateAtom), (.insert(cycle), .routeCycle)] {
            #expect(throws: expected) { try WritingProjection(seeds: seed.atoms, edits: [.init(id: id, mutations: [mutation])], emptyFields: fields, seedIndex: index) }
        }
        #expect(index.projections[a]?.text(in: a) == "A😀")
    }

    @Test func canonicallyEquivalentWireOriginsKeepFullReplayAndExactCapturedSpelling() throws {
        let baseline = WritingField(node: .baseline(blockID: "e\u{301}", path: []), name: "content")
        let variant = WritingField(node: .baseline(blockID: "é", path: []), name: "content")
        #expect(baseline == variant)
        let seeded = seedWritingAtoms([baseline: WritingFieldBirth(value: .array([textNode("A")]), active: true)])
        let index = try #require(WritingSeedIndex(atoms: seeded.atoms, hiddenKeys: [], fields: [baseline]))
        let key = WritingAtomKey(origin: variant, element: ElementID(change: .init(counter: 1, actor: "peer"), index: 0))
        let anchor = seeded.atoms[0].key
        let edit = WritingEdit(id: key.element.change, mutations: [.insert(.init(key: key, node: textNode("X"), edge: .after(anchor), route: .follow(anchor)))])
        let indexed = try WritingProjection(seeds: seeded.atoms, edits: [edit], emptyFields: [baseline], seedIndex: index)
        let full = try WritingProjection(seeds: seeded.atoms, edits: [edit], emptyFields: [baseline])
        #expect(!indexed.usesIndependentFields)
        #expect(indexed.text(in: baseline) == "AX")
        #expect(try canonicalEncoder().encode(indexed.field(of: key)) == canonicalEncoder().encode(full.field(of: key)))
        #expect(try canonicalEncoder().encode(indexed.destination(of: variant)) == canonicalEncoder().encode(full.destination(of: variant)))
    }
}
