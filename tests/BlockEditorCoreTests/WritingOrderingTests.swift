import Testing
@testable import BlockEditorCore

@Test func cachedWritingOrderMatchesCanonicalIdentityOrder() {
    let labels = ["", "a", "é", "e\u{301}", "😀", "quote\"", "slash/", "back\\", "line\n", "tab\t"]
    let changes = [ChangeID(counter: 0, actor: ""), ChangeID(counter: 1, actor: "a"), ChangeID(counter: 1, actor: "b")]
    var keys: [WritingAtomKey] = []
    for label in labels {
        for node in [NodeID.baseline(blockID: label, path: []), .baseline(blockID: "root", path: ["children", label]),
                     .inserted(creation: ElementID(change: changes[1], index: 0), path: ["children", label])] {
            for name in ["content", "summary"] {
                for change in changes {
                    for index in [-1, 0, 1] {
                        keys.append(WritingAtomKey(origin: WritingField(node: node, name: name), element: ElementID(change: change, index: index)))
                    }
                }
            }
        }
    }
    for input in [keys, Array(keys.reversed()), keys.filter { $0.element.index >= 0 }, [], [keys[0]]] {
        let actual = writingAtomsSorted(input), expected = input.sorted()
        // Array equality also normalizes String; compare every exact wire byte.
        #expect(actual.map { Array($0.origin.key.utf8) } == expected.map { Array($0.origin.key.utf8) })
        #expect(actual.map(\.element) == expected.map(\.element))
    }
}
