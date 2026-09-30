import Foundation
import Testing
@testable import BlockEditorCore

@Test func nestedReceiveHoldsKeepReceiptsPendingAndDrainAfterInvalidBatch() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "hold", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "hold", actorID: "b", document: doc)
    let first = a.deferRemoteChanges(), second = a.deferRemoteChanges()
    try b.setText(at: TextAddress("p"), to: "RHello")
    let invalid = ChangeBatch(documentID: "hold", baseline: doc, changes: [], version: 99)
    try a.receive(invalid); try a.receive(b.changes())
    try first()
    #expect(a.syncState.received.isEmpty)
    let restored = try EditorSession.restore(a.save(), actorID: "a")
    #expect(try restored.text(at: TextAddress("p")) == "Hello")
    #expect(throws: EditorError.unsupportedVersion(99)) { try second() }
    try second()
    #expect(try a.text(at: TextAddress("p")) == "RHello")
    #expect(a.syncState.received == b.syncState.received)
}

@Test func receivePreparationOnlyRunsForValidatedStateChanges() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "prepare", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "prepare", actorID: "b", document: doc)
    var observed: [String] = []
    a.onWillReceive = { observed.append((try? a.text(at: TextAddress("p"))) ?? "") }
    try a.receive(b.changes())
    #expect(observed.isEmpty)
    #expect(throws: EditorError.unsupportedVersion(99)) {
        try a.receive(ChangeBatch(documentID: "prepare", baseline: doc, changes: [], version: 99))
    }
    #expect(observed.isEmpty)
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    #expect(observed == ["Hello"])
    try a.receive(b.changes())
    #expect(observed.count == 1)
}

@Test func receiveHoldBoundsQueuedMessagesWithoutAcknowledgingThem() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "bounded", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "bounded", actorID: "b", document: doc)
    let finish = a.deferRemoteChanges()
    try b.setText(at: TextAddress("p"), to: "RHello")
    for _ in 0..<64 { try a.receive(b.changes()) }
    #expect(throws: EditorError.invalidChange) { try a.receive(b.changes()) }
    #expect(a.syncState.received.isEmpty)
    try finish(); try finish()
    #expect(try a.text(at: TextAddress("p")) == "RHello")
}

@Test func receivePreparationCannotOverwriteReentrantLocalChanges() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "reentrant", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "reentrant", actorID: "b", document: doc)
    var rejected = false
    a.onWillReceive = {
        do { try a.setText(at: TextAddress("p"), to: "Lost edit") }
        catch { rejected = true }
    }
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    #expect(rejected)
    #expect(!a.canUndo)
    #expect(try a.text(at: TextAddress("p")) == "RHello")
}
