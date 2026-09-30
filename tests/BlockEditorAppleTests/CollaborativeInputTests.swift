#if canImport(SwiftUI)
import Foundation
import Testing
import BlockEditorCore
@testable import BlockEditorApple

@MainActor @Test func compositionCommitsBeforeRemoteChangesAndPreservesAuthorUndo() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "input", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "input", actorID: "b", document: doc)
    let model = try EditorModel(session: a)
    let input = CollaborativeInput(model: model, address: TextAddress("p"))
    defer { input.close() }
    input.update(text: "漢Hello", selection: NSRange(location: 1, length: 0), composing: true)
    try b.setText(at: TextAddress("p"), to: "RHello")
    try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    #expect(input.text == "Hello")
    input.update(text: "漢Hello", selection: NSRange(location: 1, length: 0), composing: false)
    #expect(input.text == "R漢Hello")
    #expect(input.selection == NSRange(location: 2, length: 0))
    try a.undo()
    #expect(input.text == "RHello")
    try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(model.error == nil)
}

@MainActor @Test func appleSelectionMapsRemoteEditsAndDisposalReleasesComposition() throws {
    let doc = try Document(blocks: [.paragraph(id: "p", text: "Hello world")])
    let a = try EditorSession(documentID: "selection", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "selection", actorID: "b", document: doc)
    let model = try EditorModel(session: a)
    let input = CollaborativeInput(model: model, address: TextAddress("p"))
    input.selection = NSRange(location: 6, length: 5)
    try b.setText(at: TextAddress("p"), to: "RHello world"); try a.receive(b.changes())
    #expect(input.selection == NSRange(location: 7, length: 5))
    input.beginComposition()
    try b.setText(at: TextAddress("p"), to: "SRHello world"); try a.receive(b.changes())
    #expect(input.text == "RHello world")
    input.close(); input.close()
    #expect(input.text == "SRHello world")
    #expect(model.error == nil)
}
@MainActor @Test func appleCompositionPreservesMarksAndAtomicReferences() throws {
    let mention: JSONValue = .object(["type": .string("mention"), "entityId": .string("mira"), "entityType": .string("user"), "label": .string("Mira")])
    let nodes: [JSONValue] = [.object(["type": .string("text"), "text": .string("Hello "), "marks": .array([.object(["type": .string("bold")])])]), mention]
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array(nodes)])
    let doc = try Document(blocks: [block])
    let a = try EditorSession(documentID: "references", actorID: "a", document: doc)
    let b = try EditorSession(documentID: "references", actorID: "b", document: doc)
    let input = CollaborativeInput(model: try EditorModel(session: a), address: TextAddress("p"))
    defer { input.close() }
    input.selection = NSRange(location: 8, length: 0)
    try b.setText(at: TextAddress("p"), to: "RHello Mira"); try a.receive(b.changes())
    #expect(input.selection.location == 9)
    input.update(text: "漢RHello Mira", selection: NSRange(location: 1, length: 0), composing: true)
    input.update(text: "漢RHello Mira", selection: NSRange(location: 1, length: 0), composing: false)
    let final = try a.document.blocks[0].fields["content"]?.array ?? []
    #expect(final.contains(mention))
    #expect(final.contains { $0["text"]?.string?.contains("Hello ") == true && ($0["marks"]?.array ?? []).contains(.object(["type": .string("bold")])) })
}
#endif
