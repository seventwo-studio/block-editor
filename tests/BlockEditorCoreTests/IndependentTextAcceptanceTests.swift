import BlockEditorCore
import Foundation
import Testing

private func acceptancePermutations<T>(_ values: [T]) -> [[T]] {
    if values.isEmpty { return [[]] }
    return values.indices.flatMap { index in
        var remaining = values
        let first = remaining.remove(at: index)
        return acceptancePermutations(remaining).map { [first] + $0 }
    }
}

private func acceptanceSync(_ a: EditorSession, _ b: EditorSession) throws {
    let left = a.changes(since: b.syncState), right = b.changes(since: a.syncState)
    try a.receive(right)
    try b.receive(left)
    #expect(try a.document == b.document)
    #expect(a.syncState == b.syncState)
    #expect(a.changes(since: b.syncState).changes.isEmpty)
    #expect(b.changes(since: a.syncState).changes.isEmpty)
}

/// Public session API acceptance, independent of materializer/atom implementation.
/// These fixtures establish engine behavior, not platform IME or UI acceptance.
@Test(arguments: [1, 2])
func independentTextAcceptanceRestoredAuthorUndoPreservesRemoteMarksAndReference(version: Int) throws {
    let bold: JSONValue = .object(["type": .string("bold")])
    let italic: JSONValue = .object(["type": .string("italic")])
    let reference: JSONValue = .object([
        "type": .string("mention"), "entityId": .string("person-7"),
        "entityType": .string("user"), "label": .string("Mira"),
    ])
    let baseline = try Document(blocks: [Block(fields: [
        "id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNode("A😀"), reference, textNode("Z")]),
        "extension": .object(["owner": .string("consumer")]),
    ])])
    var a = try EditorSession(documentID: "independent-marks", actorID: "alice", document: baseline, collaborationVersion: version)
    let b = try EditorSession(documentID: "independent-marks", actorID: "bob", document: baseline, collaborationVersion: version)
    let address = TextAddress("p")
    let referenceStart = try a.position(at: address, offset: 3)
    try a.replaceText(at: address, range: 1..<3, with: "")
    try a.format(at: address, range: 0..<1, markType: "bold", mark: bold)
    try b.replaceText(at: address, range: 1..<1, with: "e\u{301}", marks: [italic])
    try b.format(at: address, range: 9..<10, markType: "italic", mark: italic)
    let edits = a.changes().changes + b.changes().changes
    let merged: [JSONValue] = [textNode("A", marks: [bold]), textNode("e\u{301}", marks: [italic]), reference, textNode("Z", marks: [italic])]

    // Every order includes causal gaps and duplicate single-change packets.
    for order in acceptancePermutations(edits) {
        let observer = try EditorSession(documentID: a.documentID, actorID: "observer", document: baseline, collaborationVersion: version)
        for change in order {
            let packet = ChangeBatch(documentID: a.documentID, baseline: baseline, changes: [change], version: version)
            try observer.receive(packet)
            try observer.receive(packet)
        }
        #expect(try observer.document.blocks[0].fields["content"] == .array(merged))
        #expect(try observer.document.blocks[0].fields["extension"] == baseline.blocks[0].fields["extension"])
        #expect(!observer.canUndo)
    }
    try acceptanceSync(a, b)
    #expect(try a.offset(of: referenceStart) == 3)
    let newAuthor = try EditorSession.restore(a.save(), actorID: "new-author")
    #expect(!newAuthor.canUndo)
    #expect(!newAuthor.canRedo)

    a = try EditorSession.restore(a.save(), actorID: "alice")
    try a.undo() // Alice's bold only; Bob's italic survives.
    try acceptanceSync(a, b)
    #expect(try a.document.blocks[0].fields["content"] == .array([
        textNode("A"), textNode("e\u{301}", marks: [italic]), reference, textNode("Z", marks: [italic]),
    ]))
    a = try EditorSession.restore(a.save(), actorID: "alice")
    try a.undo() // Alice's deletion only; Bob's insertion and marks survive.
    try acceptanceSync(a, b)
    #expect(try a.text(at: address) == "Ae\u{301}😀MiraZ")
    #expect(try a.offset(of: referenceStart) == 5)
    #expect(try a.document.blocks[0].fields["content"] == .array([
        textNode("A"), textNode("e\u{301}", marks: [italic]), textNode("😀"), reference, textNode("Z", marks: [italic]),
    ]))
    a = try EditorSession.restore(a.save(), actorID: "alice")
    try a.redo()
    try a.redo()
    try acceptanceSync(a, b)
    #expect(try a.document.blocks[0].fields["content"] == .array(merged))
    #expect(try a.document.blocks[0].id == "p")
    #expect(try a.document.blocks[0].fields["extension"] == baseline.blocks[0].fields["extension"])
}

@Test(arguments: [1, 2])
func independentTextAcceptanceUndoDoesNotResurrectAnotherAuthorsDeletion(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "A😀BC")])
    var a = try EditorSession(documentID: "independent-delete", actorID: "alice", document: baseline, collaborationVersion: version)
    var b = try EditorSession(documentID: "independent-delete", actorID: "bob", document: baseline, collaborationVersion: version)
    let address = TextAddress("p")
    try a.replaceText(at: address, range: 1..<3, with: "")
    try b.replaceText(at: address, range: 1..<4, with: "")
    try acceptanceSync(a, b)
    #expect(try a.text(at: address) == "AC")
    a = try EditorSession.restore(a.save(), actorID: "alice")
    try a.undo()
    try acceptanceSync(a, b)
    #expect(try a.text(at: address) == "AC")
    b = try EditorSession.restore(b.save(), actorID: "bob")
    try b.undo()
    try acceptanceSync(a, b)
    #expect(try a.document == baseline)
    try a.redo()
    try acceptanceSync(a, b)
    #expect(try b.text(at: address) == "ABC")
    try b.redo()
    try acceptanceSync(a, b)
    #expect(try a.text(at: address) == "AC")
}
