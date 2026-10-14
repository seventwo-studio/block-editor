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

@Test func rankedWritingOrderKeepsLiteralRawUnicodeAndElementPriority() {
    let labels = ["😀", "é", "a", "e\u{301}"]
    let fields = labels.map { WritingField(node: .baseline(blockID: $0, path: []), name: "content") }
    let zero = ChangeID(counter: 0, actor: "")
    let input = [1, 0].flatMap { index in fields.map { WritingAtomKey(origin: $0, element: ElementID(change: zero, index: index)) } }
    let output = writingAtomsSorted(input)
    let expectedLabels = ["a", "e\u{301}", "é", "😀", "a", "e\u{301}", "é", "😀"]
    let actualLabels = output.map { key -> [UInt8] in
        guard case .baseline(let label, _) = key.origin.node else { return [] }
        return Array(label.utf8)
    }
    #expect(actualLabels == expectedLabels.map { Array($0.utf8) })
    #expect(output.map(\.element.index) == [0, 0, 0, 0, 1, 1, 1, 1])
    let tied = [input[0], input[0], input[1], input[0]]
    #expect(writingAtomsSorted(tied).map { Array($0.origin.key.utf8) } == tied.sorted().map { Array($0.origin.key.utf8) })
}
