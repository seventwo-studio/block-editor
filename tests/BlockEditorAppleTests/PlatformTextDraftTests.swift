#if canImport(SwiftUI)
import BlockEditorCore
import Testing
@testable import BlockEditorApple

@MainActor @Test func platformEntryCommitsBeforeApplyingQueuedRemoteText() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "platform-entry", actorID: "a", document: document)
    let b = try EditorSession(documentID: "platform-entry", actorID: "b", document: document)
    let model = try EditorModel(session: a)
    let input = PlatformTextDraft(model: model, address: TextAddress("p"))
    defer { input.close() }
    input.begin(); input.begin()
    input.change(to: "漢Hello")
    #expect(try a.text(at: TextAddress("p")) == "Hello")
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    #expect(input.draft == "漢Hello")
    #expect(a.syncState.received.isEmpty)
    input.finish(); input.finish()
    #expect(input.draft == "R漢Hello")
    #expect(try a.text(at: TextAddress("p")) == input.draft)
    try a.undo()
    #expect(input.draft == "RHello")
    #expect(model.error == nil)
}

@MainActor @Test func platformEntryDisposalCommitsDraftAndReleasesRemoteHold() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "platform-close", actorID: "a", document: document)
    let b = try EditorSession(documentID: "platform-close", actorID: "b", document: document)
    let input = PlatformTextDraft(model: try EditorModel(session: a), address: TextAddress("p"))
    input.begin(); input.change(to: "LHello")
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    input.close(); input.close()
    #expect(try a.text(at: TextAddress("p")) == "RLHello")
    try b.receive(a.changes())
    #expect(try a.document == b.document)
}

@MainActor @Test func committedPlatformInputPreservesMarksAndReferences() throws {
    let mention: JSONValue = .object(["type": .string("mention"), "entityId": .string("mira"), "entityType": .string("user"), "label": .string("Mira")])
    let bold: JSONValue = .object(["type": .string("bold")])
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([
        .object(["type": .string("text"), "text": .string("Hello "), "marks": .array([bold])]), mention
    ])])
    let session = try EditorSession(documentID: "platform-committed", actorID: "a", document: Document(blocks: [block]))
    let input = PlatformTextDraft(model: try EditorModel(session: session), address: TextAddress("p"))
    defer { input.close() }
    input.change(to: "New Hello Mira")
    #expect(!input.editing)
    #expect(try session.text(at: TextAddress("p")) == "New Hello Mira")
    let nodes = try session.document.blocks[0].fields["content"]?.array ?? []
    #expect(nodes.contains(mention))
    #expect(nodes.contains { $0["text"]?.string?.contains("Hello ") == true && ($0["marks"]?.array ?? []).contains(bold) })
}
#endif
