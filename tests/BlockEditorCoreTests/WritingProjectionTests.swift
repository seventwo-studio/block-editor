@testable import BlockEditorCore
import Testing

private func field(_ id: String) -> WritingField { WritingField(node: .baseline(blockID: id, path: []), name: "content") }
private func seed(_ field: WritingField, _ text: String) -> [WritingAtomSeed] {
    var previous: WritingAtomKey?
    return text.unicodeScalars.enumerated().map { index, scalar in
        let key = WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))
        let atom = WritingAtomSeed(key: key, node: textNode(String(scalar)), edge: previous.map(WritingEdge.after) ?? .start, route: .field(field))
        previous = key; return atom
    }
}
private func insertion(_ actor: String, field: WritingField, text: String, edge: WritingEdge, route: WritingRoute) -> WritingEdit {
    let id = ChangeID(counter: 1, actor: actor)
    var previous = edge
    let values = text.unicodeScalars.enumerated().map { index, scalar -> WritingMutation in
        let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index))
        let atom = WritingAtomSeed(key: key, node: textNode(String(scalar)), edge: previous,
            route: index == 0 ? route : .follow(previous.anchor!))
        previous = .after(key)
        return .insert(atom)
    }
    return WritingEdit(id: id, mutations: values)
}

@Test func writingPrototypeSplitRetainsConcurrentTypingFormattingAndAtomOrigins() throws {
    let left = field("left"), right = field("right"), atoms = seed(left, "abcd")
    let split = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.transfer(keys: atoms.suffix(2).map(\.key), destination: right, edge: .start)])
    let peer = insertion("b", field: left, text: "X", edge: .after(atoms[2].key), route: .follow(atoms[2].key))
    let mark = WritingEdit(id: ChangeID(counter: 2, actor: "b"), mutations: [.format(keys: [atoms[2].key], type: "bold", mark: .object(["type": .string("bold")]))])
    let projection = try WritingProjection(seeds: atoms, edits: [mark, peer, split])
    #expect(projection.text(in: left) == "ab"); #expect(projection.text(in: right) == "cXd")
    #expect(projection.visibleKeys(in: right).first == atoms[2].key)
    #expect(projection.nodes(in: right).first?["marks"] == .array([.object(["type": .string("bold")])]))
    let undone = try WritingProjection(seeds: atoms, edits: [split, peer, mark], active: [split.id: false])
    #expect(undone.text(in: left) == "abcXd"); #expect(undone.text(in: right).isEmpty)
    #expect(undone.nodes(in: left)[2]["marks"] == .array([.object(["type": .string("bold")])]))
    #expect(projection.retainedKeys == undone.retainedKeys)
}

@Test func writingPrototypeBoundaryAffinityFollowsTheAdjacentContent() throws {
    let left = field("left"), right = field("right"), atoms = seed(left, "abcd")
    let split = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.transfer(keys: atoms.suffix(2).map(\.key), destination: right, edge: .start)])
    let before = insertion("b", field: left, text: "R", edge: .before(atoms[2].key), route: .follow(atoms[2].key))
    let after = insertion("c", field: left, text: "L", edge: .after(atoms[1].key), route: .follow(atoms[1].key))
    let projection = try WritingProjection(seeds: atoms, edits: [after, split, before])
    #expect(projection.text(in: left) == "abL"); #expect(projection.text(in: right) == "Rcd")
    #expect(try projection.field(of: atoms[2].key) == right)
    let undone = try WritingProjection(seeds: atoms, edits: [split, before, after], active: [split.id: false])
    #expect(undone.text(in: left) == "abLRcd")
}

@Test func writingPrototypeMergeRetainsBothNamespacesAndRemoteTextThroughUndo() throws {
    let left = field("left"), right = field("right"), first = seed(left, "ab"), second = seed(right, "cd")
    #expect(first[0].key.element == second[0].key.element)
    #expect(first[0].key != second[0].key)
    let merge = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [
        .join(source: right, destination: left, edge: .after(first.last!.key))])
    let peer = insertion("b", field: right, text: "X", edge: .after(second.last!.key), route: .follow(second.last!.key))
    let atStart = insertion("c", field: right, text: "R", edge: .before(second[0].key), route: .follow(second[0].key))
    let projection = try WritingProjection(seeds: first + second, edits: [peer, atStart, merge])
    #expect(projection.text(in: left) == "abRcdX"); #expect(projection.text(in: right).isEmpty)
    let undone = try WritingProjection(seeds: first + second, edits: [merge, peer, atStart], active: [merge.id: false])
    #expect(undone.text(in: left) == "ab"); #expect(undone.text(in: right) == "RcdX")
    #expect(projection.retainedKeys == undone.retainedKeys)
}

@Test func writingPrototypeAtomicReferencesMoveWithoutReplacement() throws {
    let left = field("left"), right = field("right")
    let key = WritingAtomKey(origin: left, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: 0))
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("stable"), "entityType": .string("note"), "label": .string("世界 😀")])
    let atom = WritingAtomSeed(key: key, node: reference, edge: .start, route: .field(left))
    let split = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.transfer(keys: [key], destination: right, edge: .start)])
    let projection = try WritingProjection(seeds: [atom], edits: [split])
    #expect(projection.nodes(in: right) == [reference]); #expect(projection.visibleKeys(in: right) == [key])
    let undone = try WritingProjection(seeds: [atom], edits: [split], active: [split.id: false])
    #expect(undone.nodes(in: left) == [reference]); #expect(undone.visibleKeys(in: left) == [key])
}

@Test func writingPrototypeCyclesAndIncompleteHistoriesFailExplicitly() throws {
    let left = field("left"), right = field("right"), atoms = seed(left, "ab")
    let cycle = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.transfer(keys: [atoms[0].key], destination: left, edge: .after(atoms[1].key))])
    #expect(throws: WritingProjectionError.placementCycle) { try WritingProjection(seeds: atoms, edits: [cycle]) }
    let joins = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.join(source: left, destination: right, edge: .start), .join(source: right, destination: left, edge: .start)])
    #expect(throws: WritingProjectionError.routeCycle) { try WritingProjection(seeds: [], edits: [joins]) }
    let missing = WritingAtomKey(origin: right, element: atoms[0].key.element)
    let incomplete = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.delete(keys: [missing])])
    #expect(throws: WritingProjectionError.missingAtom) { try WritingProjection(seeds: atoms, edits: [incomplete]) }
}

@Test func writingPrototypeEmptyMergedFieldKeepsItsVirtualBoundaryAcrossUndo() throws {
    let left = field("left"), right = field("right"), atoms = seed(left, "ab")
    let merge = WritingEdit(id: ChangeID(counter: 1, actor: "a"), mutations: [.join(source: right, destination: left, edge: .after(atoms.last!.key))])
    let peer = insertion("b", field: right, text: "X", edge: .start, route: .field(right))
    let joined = try WritingProjection(seeds: atoms, edits: [peer, merge])
    #expect(joined.text(in: left) == "abX"); #expect(joined.text(in: right).isEmpty)
    let undone = try WritingProjection(seeds: atoms, edits: [merge, peer], active: [merge.id: false])
    #expect(undone.text(in: left) == "ab"); #expect(undone.text(in: right) == "X")
    let emptyLeft = field("empty-left")
    let emptyMerge = WritingEdit(id: merge.id, mutations: [.join(source: right, destination: emptyLeft, edge: .start)])
    let leftPeer = insertion("c", field: emptyLeft, text: "L", edge: .start, route: .field(emptyLeft))
    let both = try WritingProjection(seeds: [], edits: [peer, emptyMerge, leftPeer])
    #expect(both.text(in: emptyLeft) == "LX")
}
