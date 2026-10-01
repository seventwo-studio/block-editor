#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor @Test func appKitDisabledHostKeepsAcceptedTextSelectable() async throws {
    let session = try EditorSession(documentID: "appkit-readonly", actorID: "a",
                                    document: Document(blocks: [.paragraph(id: "p", text: "Accepted café 👩🏽‍💻")]))
    let model = try EditorModel(session: session)
    let input = MacTextInput(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let host = NSHostingView(rootView: input.disabled(true))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    host.layoutSubtreeIfNeeded()
    func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let text = try #require(textView(in: host))
    #expect(!text.isEditable)
    #expect(text.isSelectable)
    text.setSelectedRange(NSRange(location: 0, length: 8))
    #expect(text.selectedRange().length == 8)
    #expect(text.string == "Accepted café 👩🏽‍💻")
    host.rootView = input.disabled(false)
    host.layoutSubtreeIfNeeded()
    for _ in 0..<20 where !text.isEditable { try await Task.sleep(for: .milliseconds(10)) }
    #expect(text.isEditable)
    #expect(text.string == "Accepted café 👩🏽‍💻")
    #expect(session.syncState.received.isEmpty)
}

@MainActor @Test func appKitCompositionCommitsUnicodeBeforeRemoteReplay() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "appkit-ime", actorID: "a", document: document)
    let b = try EditorSession(documentID: "appkit-ime", actorID: "b", document: document)
    let model = try EditorModel(session: a)
    let coordinator = MacTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    coordinator.connect(view)
    defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText())
    #expect(view.string == "漢Hello")
    try b.setText(at: TextAddress("p"), to: "RHello")
    try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    #expect(view.string == "漢Hello")
    view.insertText("漢字 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!view.hasMarkedText())
    #expect(view.string == "R漢字 👩🏽‍💻Hello")
    #expect(view.selectedRange() == NSRange(location: "R漢字 👩🏽‍💻".utf16.count, length: 0))
    try a.undo()
    #expect(view.string == "RHello")
    #expect(model.error == nil)
}

@MainActor @Test func appKitSelectionAndUnicodeInsertionFollowRemoteText() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello world")])
    let a = try EditorSession(documentID: "appkit-selection", actorID: "a", document: document)
    let b = try EditorSession(documentID: "appkit-selection", actorID: "b", document: document)
    let model = try EditorModel(session: a)
    var selected = NSRange(location: 0, length: 0)
    let coordinator = MacTextInput.Coordinator(model: model, address: TextAddress("p"), selection: Binding(get: { selected }, set: { selected = $0 }))
    let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    coordinator.connect(view)
    defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 6, length: 5))
    try b.setText(at: TextAddress("p"), to: "RHello world")
    try a.receive(b.changes())
    #expect(view.selectedRange() == NSRange(location: 7, length: 5))
    #expect(selected == view.selectedRange())
    try a.format(at: TextAddress("p"), range: selected.location..<NSMaxRange(selected), markType: "bold", mark: .object(["type": .string("bold")]))
    let nodes = try a.document.blocks[0].fields["content"]?.array ?? []
    #expect(nodes.first?["text"] == .string("RHello "))
    #expect(nodes.last?["text"] == .string("world"))
    #expect(nodes.last?["marks"]?.array?.first?["type"] == .string("bold"))
    view.insertText("café 👩🏽‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(try a.text(at: TextAddress("p")) == "RHello café 👩🏽‍💻")
    try a.undo()
    #expect(view.string == "RHello world")
    #expect(model.error == nil)
}
@MainActor @Test func appKitUnmarkAndDisposalReleaseRemoteChanges() throws {
    for dispose in [false, true] {
        let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
        let a = try EditorSession(documentID: "appkit-finish", actorID: "a", document: document)
        let b = try EditorSession(documentID: "appkit-finish", actorID: "b", document: document)
        let model = try EditorModel(session: a)
        let coordinator = MacTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
        let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        coordinator.connect(view)
        view.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try b.setText(at: TextAddress("p"), to: "RHello")
        try a.receive(b.changes())
        if dispose { coordinator.close() }
        view.unmarkText()
        #expect(try a.text(at: TextAddress("p")) == (dispose ? "RHello" : "RéHello"))
        #expect(a.syncState.received.contains(ChangeID(counter: 1, actor: "b")))
        if dispose {
            view.insertText("late", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(try a.text(at: TextAddress("p")) == "RHello")
            #expect(!a.canUndo)
        }
        #expect(model.error == nil)
        coordinator.close()
    }
}
@MainActor @Test func appKitToolbarUndoCommitsCompositionBeforeUndoAndRemoteReplay() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "toolbar-composition", actorID: "a", document: document)
    let b = try EditorSession(documentID: "toolbar-composition", actorID: "b", document: document)
    try a.setText(at: TextAddress("p"), to: "HelloL")
    let model = try EditorModel(session: a)
    let coordinator = MacTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    coordinator.connect(view)
    defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 6, length: 0))
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try b.setText(at: TextAddress("p"), to: "RHello")
    try a.receive(b.changes())
    model.perform { try $0.undo() }
    #expect(!view.hasMarkedText())
    #expect(view.string == "RHelloL")
    #expect(try a.text(at: TextAddress("p")) == "RHelloL")
    #expect(a.syncState.received.contains(ChangeID(counter: 1, actor: "b")))
    #expect(model.error == nil)
    model.perform { try $0.redo() }
    #expect(view.string == "RHelloL漢")
    view.unmarkText()
    #expect(try a.text(at: TextAddress("p")) == "RHelloL漢")
}
#endif
