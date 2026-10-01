import Foundation
import Testing
@testable import BlockEditorCore

private func selectionSession(_ actor: String, _ blocks: [Block]) throws -> WritingSession {
    try WritingSession(documentID: "batch-document", actorID: actor, epoch: "batch-v3", document: Document(blocks: blocks))
}

@Test func writingBatchMixedDeletionPreservesRemoteTextAndReopenUndo() throws {
    let middle = try Block(fields: ["id": .string("middle"), "type": .string("quote"),
        "content": .array([textNode("kept", marks: [.object(["type": .string("bold")])])]),
        "consumer": .object(["id": .string("external-id")])])
    let blocks = [try Block.paragraph(id: "first", text: "ABC"), middle, try Block.paragraph(id: "last", text: "XYZ")]
    let a = try selectionSession("a", blocks), b = try selectionSession("b", blocks)
    let selected = try WritingSelection(nodes: [a.node(at: NodeAddress("middle"))], text: [
        a.selectedText(at: TextAddress("first"), range: 1..<3),
        a.selectedText(at: TextAddress("last"), range: 0..<2)])
    let copied = try a.copy(selected)
    #expect(copied.nodes == [.object(middle.fields)])
    #expect(copied.text.map { plainText($0) } == ["BC", "XY"])
    try b.replaceText(at: TextAddress("first"), range: 0..<0, with: "R-")
    try b.replaceText(at: TextAddress("last"), range: 3..<3, with: "!")
    try a.receive(b.changes())
    try a.delete(selected)
    #expect(a.document.blocks.map(\.text) == ["R-A", "Z!"])
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.document == a.document)
    try reopened.undo()
    #expect(reopened.document.blocks.map(\.text) == ["R-ABC", "kept", "XYZ!"])
    #expect(reopened.document.blocks[1] == middle)
    #expect(!reopened.canUndo && reopened.canRedo)
    try b.receive(a.changes()); try b.receive(a.changes())
    #expect(b.document == a.document)
}

@Test func writingBatchMoveKeepsNestedOriginsAndRemoteAuthorWork() throws {
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([textNode("left")]),
        "children": .array([.object(Block.paragraph(id: "p", text: "one").fields), .object(Block.paragraph(id: "q", text: "two").fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([textNode("right")]), "children": .array([])])
    let a = try selectionSession("a", [left, right]), b = try selectionSession("b", [left, right])
    let p = try a.node(at: NodeAddress("left", path: ["children", "p"]))
    let q = try a.node(at: NodeAddress("left", path: ["children", "q"]))
    let caret = try a.position(at: a.textAddress(of: p), offset: 2)
    let selected = WritingSelection(nodes: [p, q])
    #expect(try a.move(selected, into: NodeCollection(owner: a.node(at: NodeAddress("right")), field: "children")) == selected)
    try b.replaceText(at: b.textAddress(of: p), range: 3..<3, with: " remote")
    try a.receive(b.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(try a.address(of: p) == NodeAddress("right", path: ["children", "p"]))
    #expect(try a.resolve(caret).address == a.textAddress(of: p))
    #expect(try a.text(at: a.textAddress(of: p)) == "one remote")
    try a.undo()
    #expect(try a.address(of: p).blockID == "left")
    #expect(try a.address(of: q).blockID == "left")
    #expect(try a.text(at: a.textAddress(of: p)) == "one remote")
    #expect(!a.canUndo)
}

@Test func writingBatchDuplicateCopiesRichDescendantsWithFreshOrigins() throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("external"), "entityType": .string("note"), "label": .string("世界😀")])
    let child = try Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNode("a", marks: [.object(["type": .string("bold")])]), reference]),
        "consumer": .object(["id": .string("never-rewrite")])])
    let toggle = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([textNode("summary")]), "children": .array([.object(child.fields)])])
    let a = try selectionSession("a", [toggle]), b = try selectionSession("b", [toggle])
    let original = try a.node(at: NodeAddress("t"))
    let duplicate = try a.duplicate(WritingSelection(nodes: [original]), into: .root, after: original)
    #expect(duplicate.nodes.count == 1 && duplicate.nodes[0] != original)
    let copied = try a.copy(duplicate).nodes[0]
    #expect(copied["id"] != .string("t"))
    let nested = try #require(copied["children"]?.array?.first)
    #expect(nested["id"] != .string("p"))
    #expect(nested["content"] == child.fields["content"])
    #expect(nested["consumer"] == child.fields["consumer"])
    try b.replaceText(at: TextAddress("t", path: ["children", "p", "content"]), range: 0..<0, with: "remote-")
    try a.receive(b.changes()); try a.undo()
    #expect(a.document.blocks.count == 1)
    #expect(try a.text(at: TextAddress("t", path: ["children", "p", "content"])) == "remote-a世界😀")
    try a.redo()
    #expect(try a.copy(duplicate).nodes[0] == copied)
    let restored = try WritingSession.restore(a.save(), actorID: "a")
    #expect(restored.document == a.document)
}

@Test func writingBatchRejectsOverlapAndCompositionWithoutMutation() throws {
    let nested = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([textNode("summary")]),
        "children": .array([.object(Block.paragraph(id: "p", text: "😀ab").fields)])])
    let a = try selectionSession("a", [nested])
    let parent = try a.node(at: NodeAddress("t")), child = try a.node(at: NodeAddress("t", path: ["children", "p"]))
    let before = try a.save()
    #expect(throws: EditorError.invalidRange) { try a.delete(WritingSelection(nodes: [parent, child])) }
    #expect(throws: EditorError.invalidRange) { try a.selectedText(at: a.textAddress(of: child), range: 1..<2) }
    a.isComposing = true
    #expect(throws: WritingSessionError.compositionActive) { try a.delete(WritingSelection(nodes: [child])) }
    #expect(throws: WritingSessionError.compositionActive) { try a.move(WritingSelection(nodes: [child]), into: .root) }
    #expect(throws: WritingSessionError.compositionActive) { try a.duplicate(WritingSelection(nodes: [parent]), into: .root) }
    #expect(try a.save() == before)
}

@Test func writingBatchCapturesBackwardRootAndNestedRanges() throws {
    let blocks = [try Block.paragraph(id: "p", text: "😀ab"), try Block.paragraph(id: "q", text: "middle"), try Block.paragraph(id: "r", text: "tail")]
    let a = try selectionSession("a", blocks)
    let start = try a.position(at: TextAddress("p"), offset: 2), end = try a.position(at: TextAddress("r"), offset: 2)
    let forward = try a.selection(from: start, to: end), backward = try a.selection(from: end, to: start)
    #expect(forward == backward)
    #expect(try a.copy(forward).text.map { plainText($0) } == ["ab", "ta"])
    #expect(try a.copy(forward).nodes == [.object(blocks[1].fields)])
    let result = try a.delete(forward)
    #expect(a.document.blocks.map(\.text) == ["😀", "il"])
    #expect(try a.resolve(result.text[0].start).offset == 2)
    #expect(try a.resolve(result.text[1].start).offset == 0)
    #expect(result.text.allSatisfy { $0.start == $0.end })
    let toggle = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([textNode("t")]), "children": .array(blocks.map { .object($0.fields) })])
    let nested = try selectionSession("n", [toggle])
    let address: (String) -> TextAddress = { TextAddress("t", path: ["children", $0, "content"]) }
    let selected = try nested.selection(from: nested.position(at: address("p"), offset: 2), to: nested.position(at: address("r"), offset: 2))
    try nested.delete(selected)
    #expect(try nested.text(at: address("p")) == "😀")
    #expect(try nested.text(at: address("r")) == "il")
    #expect(nested.document.blocks[0].fields["children"]?.array?.count == 2)
}

@Test func writingBatchRetainedRangeFollowsRemoteSplitAndPreservesItOnUndo() throws {
    let blocks = [try Block.paragraph(id: "p", text: "abcd")]
    let a = try selectionSession("a", blocks), b = try selectionSession("b", blocks)
    let captured = try WritingSelection(text: [a.selectedText(at: TextAddress("p"), range: 1..<3)])
    try b.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    try a.receive(b.changes())
    #expect(try a.copy(captured).text.map { plainText($0) } == ["b", "c"])
    let collapsed = try a.delete(captured)
    #expect(a.document.blocks.map(\.text) == ["a", "d"])
    #expect(try a.resolve(collapsed.text[0].start).offset == 1)
    let restored = try WritingSession.restore(a.save(), actorID: "a")
    try restored.undo()
    #expect(restored.document.blocks.map(\.id) == ["p", "q"])
    #expect(restored.document.blocks.map(\.text) == ["ab", "cd"])
    #expect(!restored.canUndo && restored.canRedo)
}

@Test func writingBatchDuplicateSkipsLabelsRetainedAcrossEpochReset() throws {
    let a = try selectionSession("a", [.paragraph(id: "p", text: "original"), .paragraph(id: "copy-a-1-1", text: "existing")])
    let original = try a.node(at: NodeAddress("p"))
    let selected = try a.duplicate(WritingSelection(nodes: [original]), into: .root, after: original)
    let value = try a.copy(selected).nodes[0]
    #expect(value["id"] != .string("p") && value["id"] != .string("copy-a-1-1"))
    #expect(Set(a.document.blocks.map(\.id)).count == 3)
    #expect(a.document.blocks.map(\.text) == ["original", "original", "existing"])
    try a.undo()
    #expect(a.document.blocks.map(\.text) == ["original", "existing"])
}

@Test(arguments: [0..<4, 1..<4, 4..<4])
func writingBatchRetainedFieldEndFollowsRemoteSuffix(range: Range<Int>) throws {
    let blocks = [try Block.paragraph(id: "p", text: "abcd")]
    let a = try selectionSession("a", blocks), b = try selectionSession("b", blocks)
    let span = try a.selectedText(at: TextAddress("p"), range: range)
    let selected = WritingSelection(text: [span])
    try b.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    try a.receive(b.changes())
    #expect(try a.copy(selected).text.map { plainText($0) }.joined() == (range.lowerBound == 0 ? "abcd" : range.lowerBound == 1 ? "bcd" : ""))
    if range.isEmpty {
        #expect(span.start == span.end)
        #expect(try a.resolve(span.start).address == a.textAddress(of: a.node(at: NodeAddress("q"))))
        #expect(try a.resolve(span.start).offset == 2)
    }
    try a.delete(selected)
    #expect(a.document.blocks.map(\.text) == (range.lowerBound == 0 ? ["", ""] : range.lowerBound == 1 ? ["a", ""] : ["ab", "cd"]))
    let restored = try WritingSession.restore(a.save(), actorID: "a")
    try restored.undo()
    #expect(restored.document.blocks.map(\.text) == ["ab", "cd"])
    #expect(!restored.canUndo)
}

@Test func writingBatchCrossCollectionRangeKeepsBoundaryAncestorsAndUnselectedChildren() throws {
    let root = try Block.paragraph(id: "root", text: "head")
    let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([textNode("summary")]),
        "consumer": .string("keep"), "children": .array([.object(Block.paragraph(id: "a", text: "whole").fields),
            .object(Block.paragraph(id: "b", text: "last").fields), .object(Block.paragraph(id: "c", text: "unselected").fields)])])
    let session = try selectionSession("a", [root, toggle])
    let selected = try session.selection(from: session.position(at: TextAddress("root"), offset: 2),
        to: session.position(at: TextAddress("toggle", path: ["children", "b", "content"]), offset: 2))
    let copied = try session.copy(selected)
    #expect(copied.text.map { plainText($0) } == ["ad", "summary", "la"])
    let expectedWhole = try Block.paragraph(id: "a", text: "whole")
    #expect(copied.nodes == [.object(expectedWhole.fields)])
    try session.delete(selected)
    #expect(session.document.blocks[0].text == "he")
    #expect(session.document.blocks[1].fields["consumer"] == .string("keep"))
    #expect(try session.text(at: TextAddress("toggle", path: ["summary"])) == "")
    #expect(try session.text(at: TextAddress("toggle", path: ["children", "b", "content"])) == "st")
    #expect(try session.text(at: TextAddress("toggle", path: ["children", "c", "content"])) == "unselected")
    #expect(session.document.blocks[1].fields["children"]?.array?.count == 2)
    try session.undo()
    #expect(session.document.blocks == [root, toggle])
}
