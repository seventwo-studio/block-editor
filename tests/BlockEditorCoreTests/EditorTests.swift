import BlockEditorCore
import Foundation
import Testing

private func pair(_ text: String = "Hello") throws -> (EditorSession, EditorSession) {
    let document = try Document(blocks: [.paragraph(id: "p", text: text)])
    return (try EditorSession(documentID: "doc", actorID: "a", document: document),
            try EditorSession(documentID: "doc", actorID: "b", document: document))
}
private func sync(_ a: EditorSession, _ b: EditorSession) throws {
    let left = a.changes(since: b.syncState), right = b.changes(since: a.syncState)
    try a.receive(right); try b.receive(left)
    #expect(try a.document == b.document)
}

@Test func concurrentTypingAndAuthorUndo() throws {
    let (a, b) = try pair()
    try a.replaceText(at: TextAddress("p"), range: 5..<5, with: " Alice")
    try b.replaceText(at: TextAddress("p"), range: 5..<5, with: " Bob")
    try sync(a, b)
    #expect(try a.document.blocks[0].text == "Hello Bob Alice")
    try a.undo(); try sync(a, b)
    #expect(try b.document.blocks[0].text == "Hello Bob")
    try a.redo(); try sync(a, b)
    #expect(try b.document.blocks[0].text == "Hello Bob Alice")
}

@Test func formattingAndStructureRedoPreserveUnrelatedRemoteChanges() throws {
    let (a, b) = try pair()
    try a.insert(.paragraph(id: "q", text: "Q"), after: "p")
    try a.insert(.paragraph(id: "r", text: "R"), after: "q")
    try sync(a, b)
    try a.format(at: TextAddress("p"), range: 0..<5, markType: "bold", mark: .object(["type": .string("bold")]))
    try b.format(at: TextAddress("p"), range: 0..<5, markType: "italic", mark: .object(["type": .string("italic")]))
    try sync(a, b)
    try a.undo(); try sync(a, b)
    let afterUndo = try a.document.blocks[0].fields["content"]?.array?.first?["marks"]?.array ?? []
    #expect(afterUndo.map { $0["type"]?.string } == ["italic"])
    try a.redo(); try sync(a, b)
    let afterRedo = try a.document.blocks[0].fields["content"]?.array?.first?["marks"]?.array ?? []
    #expect(Set(afterRedo.compactMap { $0["type"]?.string }) == Set(["bold", "italic"]))
    try a.move(blockID: "q", after: "r")
    try b.setText(at: TextAddress("r"), to: "Remote R")
    try sync(a, b); try a.undo(); try sync(a, b)
    #expect(try a.document.blocks.map(\.id) == ["p", "q", "r"])
    #expect(try a.text(at: TextAddress("r")) == "Remote R")
    try a.redo(); try sync(a, b)
    #expect(try a.document.blocks.map(\.id) == ["p", "r", "q"])
    #expect(try a.text(at: TextAddress("r")) == "Remote R")
}

@Test func concurrentFormattingAndDeletion() throws {
    let (a, b) = try pair()
    try a.format(at: TextAddress("p"), range: 0..<5, markType: "bold", mark: .object(["type": .string("bold")]))
    try b.replaceText(at: TextAddress("p"), range: 1..<3, with: "i")
    try sync(a, b)
    #expect(try a.document.blocks[0].text == "Hilo")
    try a.undo(); try sync(a, b)
    #expect(try a.document.blocks[0].text == "Hilo")
    #expect(try a.document.blocks[0].fields["content"]?.array?.count == 1)
}

@Test func duplicateAndReorderedDelivery() throws {
    let (a, b) = try pair("")
    try a.replaceText(at: TextAddress("p"), range: 0..<0, with: "A")
    try a.replaceText(at: TextAddress("p"), range: 1..<1, with: "B")
    let all = a.changes()
    for change in all.changes.reversed() {
        try b.receive(ChangeBatch(documentID: all.documentID, baseline: all.baseline, changes: [change]))
    }
    try b.receive(all)
    #expect(try a.document == b.document)
    #expect(a.changes(since: b.syncState).changes.isEmpty)
}

@Test func undoKeepsRemoteDescendants() throws {
    let (a, b) = try pair("")
    try a.replaceText(at: TextAddress("p"), range: 0..<0, with: "A")
    try sync(a, b)
    try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "B")
    try sync(a, b); try a.undo(); try sync(a, b)
    #expect(try a.document.blocks[0].text == "B")
}

@Test func concurrentMovesAndDeletesConverge() throws {
    let (a, b) = try pair()
    try a.insert(.paragraph(id: "q", text: "Q"), after: "p")
    try a.insert(.paragraph(id: "r", text: "R"), after: "q")
    try sync(a, b)
    try a.move(blockID: "p", after: "r")
    try b.move(blockID: "r", after: "p")
    try sync(a, b)
    #expect(try Set(a.document.blocks.map(\.id)) == Set(["p", "q", "r"]))
    try a.delete(blockID: "q"); try b.setText(at: TextAddress("q"), to: "remote edit")
    try sync(a, b); try a.undo(); try sync(a, b)
    #expect(try a.document.blocks.first { $0.id == "q" }?.text == "remote edit")
}

@Test func unicodeRangesAndRoundTrip() throws {
    let (a, _) = try pair("A😀e\u{301}文")
    #expect(throws: EditorError.invalidRange) { try a.replaceText(at: TextAddress("p"), range: 2..<2, with: "x") }
    try a.replaceText(at: TextAddress("p"), range: 1..<3, with: "🦜")
    let saved = try a.save()
    a.receivePresence(Presence(actor: "remote", revision: 1))
    #expect(try a.save() == saved)
    let restored = try EditorSession.restore(saved, actorID: "new-writer")
    #expect(try restored.document == a.document)
    #expect(restored.presence.isEmpty)
}

@Test func invalidBatchIsAtomic() throws {
    let (a, b) = try pair()
    try a.setText(at: TextAddress("p"), to: "changed")
    let before = try b.save()
    let original = a.changes()
    let invalid = Change(id: ChangeID(counter: 99, actor: "attacker"),
                         body: .setActive(target: original.changes[0].id, active: false))
    #expect(throws: EditorError.invalidChange) {
        try b.receive(ChangeBatch(documentID: "doc", baseline: original.baseline, changes: original.changes + [invalid]))
    }
    #expect(try b.save() == before)
    #expect(throws: EditorError.unsupportedVersion(99)) {
        try b.receive(ChangeBatch(documentID: "doc", baseline: original.baseline, changes: [], version: 99))
    }
}

@Test func authoringRestrictionsDoNotDestroySavedBlocks() throws {
    let (a, _) = try pair()
    a.allowedBlockTypes = ["heading"]
    try a.insert(.paragraph(id: "q"))
    #expect(throws: EditorError.restrictedBlock("image")) {
        try a.insert(Block(fields: ["id": .string("image"), "type": .string("image"), "src": .string("asset")]))
    }
    #expect(try a.document.blocks.count == 2)
}

@Test func preservesUnknownFieldsAndNestedContent() throws {
    let json = Data(#"[{"id":"toggle","type":"toggle","summary":[],"children":[{"id":"nested","type":"paragraph","content":[{"type":"entity-ref","entityType":"task","entityId":"task-1","label":"Task"}]}],"extension":{"future":true}}]"#.utf8)
    let document = try Document(json: json)
    let a = try EditorSession(documentID: "nested", actorID: "a", document: document)
    #expect(try a.document == document)
    let address = TextAddress("toggle", path: ["children", "nested", "content"])
    try a.replaceText(at: address, range: 4..<4, with: " added")
    #expect(try a.text(at: address) == "Task added")
    #expect(try a.document.blocks[0].fields["extension"] == document.blocks[0].fields["extension"])
    #expect(try a.document.blocks[0].value(at: address.path)?.array?.first?["entityId"]?.string == "task-1")
}

@Test func localHistorySurvivesRestartWithoutRevertingRemoteWork() throws {
    let (a, b) = try pair()
    try a.setText(at: TextAddress("p"), to: "Hello A")
    try b.setText(at: TextAddress("p"), to: "Hello B")
    try sync(a, b)
    let resumed = try EditorSession.restore(a.save(), actorID: "a")
    #expect(resumed.canUndo)
    try resumed.undo(); try sync(resumed, b)
    #expect(try b.document.blocks[0].text == "Hello B")
    let again = try EditorSession.restore(resumed.save(), actorID: "a")
    #expect(again.canRedo)
    try again.redo(); try sync(again, b)
    #expect(try b.document.blocks[0].text == "Hello B A")
}

@Test func observerSeesCommittedHistory() throws {
    let (a, _) = try pair()
    var history: [Bool] = []
    a.onChange = { _, _ in history.append(a.canUndo) }
    try a.setText(at: TextAddress("p"), to: "new")
    try a.undo()
    #expect(history == [true, false])
}

@Test func allDeliveryPermutationsConverge() throws {
    let (a, b) = try pair("abc")
    try a.replaceText(at: TextAddress("p"), range: 1..<2, with: "AX")
    try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "BY")
    try a.format(at: TextAddress("p"), range: 0..<1, markType: "bold", mark: .object(["type": .string("bold")]))
    try b.format(at: TextAddress("p"), range: 0..<1, markType: "italic", mark: .object(["type": .string("italic")]))
    let all = a.changes().changes + b.changes().changes
    func permutations<T>(_ values: [T]) -> [[T]] {
        if values.isEmpty { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values; let first = remaining.remove(at: index)
            return permutations(remaining).map { [first] + $0 }
        }
    }
    try sync(a, b)
    for order in permutations(all) {
        let replica = try EditorSession(documentID: "doc", actorID: "observer", document: a.baseline)
        for change in order {
            let batch = ChangeBatch(documentID: "doc", baseline: a.baseline, changes: [change])
            try replica.receive(batch); try replica.receive(batch)
        }
        #expect(try replica.document == a.document)
    }
}

@Test func markdownDialectAndUnknownProtocol() throws {
    var next = 0
    let source = "# Heading\n\n- [x] Done\n- [ ] Next\n\n> [!warning]\n> Careful\n\n| A | B |\n| --- | --- |\n| C | D |\n\n```swift\nprint(1)\n```"
    let document = try Markdown.parse(source, makeID: { next += 1; return "id-\(next)" })
    #expect(document.blocks.map(\.type) == ["heading", "list", "callout", "table", "code"])
    #expect(Markdown.serialize(document) == source)
    #expect(throws: (any Error).self) { try EditorSession.restore(Data("[]".utf8), actorID: "new") }
}

@Test func bridgeReportsErrorsAndReleasesSessions() throws {
    let bridge = EditorBridge()
    func call(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: bridge.call(Data(json.utf8))) }
    #expect(try call(#"{"command":"create","session":"s","documentID":"d","actorID":"a","blocks":[]}"#)["ok"] == .bool(true))
    #expect(try call(#"{"command":"replaceText","session":"s","start":2,"end":1,"address":{"blockID":"p","path":["content"]}}"#)["ok"] == .bool(false))
    #expect(try call(#"{"command":"close","session":"s"}"#)["ok"] == .bool(true))
    #expect(try call(#"{"command":"document","session":"s"}"#)["ok"] == .bool(false))
}
