import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct StructuralOrderingTests {
    @Test func cachedPlacementKeysRetainLiteralTiersRawUnicodeAndCanonicalOwnerEquality() {
        let composed = NodeID.baseline(blockID: "é", path: []), decomposed = NodeID.baseline(blockID: "e\u{301}", path: [])
        let a = NodeID.baseline(blockID: "a", path: []), z = NodeID.baseline(blockID: "z", path: [])
        let first = ElementID(change: ChangeID(counter: 1, actor: "peer"), index: 0)
        let second = ElementID(change: ChangeID(counter: 2, actor: "peer"), index: 0)
        let expected: [NodePlacementID] = [.initial(decomposed), .initial(composed),
            .role(owner: composed, node: a), .role(owner: decomposed, node: z),
            .columnRoute(layout: composed, slot: first, node: a), .columnRoute(layout: decomposed, slot: first, node: z),
            .columnRoute(layout: a, slot: second, node: a), .edit(first), .edit(second)]
        let input = Array(expected.reversed())
        func wire(_ ids: [NodePlacementID]) -> [Data] { ids.map { try! canonicalEncoder().encode($0) } }
        #expect(wire(structuralPlacementsSorted(input, by: { $0 })) == wire(expected))
        #expect(wire(structuralPlacementsSorted(expected, by: { $0 }, descending: true)) == wire(input))
        // Also compare every admitted comparator branch with its public rule;
        // literal expectations above prevent merely mirroring implementation.
        #expect(wire(structuralPlacementsSorted(input, by: { $0 })) == wire(input.sorted()))
    }

    @Test func nodeKeySortKeepsCanonicalStringTiesStableWithoutMergingRawSpellings() {
        let first = NodeID.baseline(blockID: "é", path: []), second = NodeID.baseline(blockID: "e\u{301}", path: [])
        let last = NodeID.baseline(blockID: "z", path: []), initial = NodeID.baseline(blockID: "a", path: [])
        let input = [first, last, second, initial]
        let ordered = structuralNodesSorted(input)
        #expect(ordered.map { Array($0.key.utf8) } == [initial, last, first, second].map { Array($0.key.utf8) })
        #expect(ordered.count == input.count)
        #expect(ordered.map { Array($0.key.utf8) } == input.sorted { $0.key < $1.key }.map { Array($0.key.utf8) })
    }
}
