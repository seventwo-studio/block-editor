#if os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BlockEditorApple

@MainActor @Test func uiKitDisabledHostKeepsAcceptedTextSelectable() async throws {
    let session = try EditorSession(documentID: "uikit-readonly", actorID: "a",
                                    document: Document(blocks: [.paragraph(id: "p", text: "Accepted café 👩🏽‍💻")]))
    let model = try EditorModel(session: session)
    let input = UIKitTextInput(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let host = UIHostingController(rootView: input.disabled(true))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    host.loadViewIfNeeded()
    host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
    host.view.layoutIfNeeded()
    func textView(in view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    for _ in 0..<20 where textView(in: host.view) == nil {
        try await Task.sleep(for: .milliseconds(10))
        host.view.layoutIfNeeded()
    }
    let text = try #require(textView(in: host.view))
    #expect(!text.isEditable)
    #expect(text.isSelectable)
    text.selectedRange = NSRange(location: 0, length: 8)
    #expect(text.selectedRange.length == 8)
    #expect(text.text == "Accepted café 👩🏽‍💻")
    host.rootView = input.disabled(false)
    host.view.layoutIfNeeded()
    for _ in 0..<20 where !text.isEditable { try await Task.sleep(for: .milliseconds(10)) }
    #expect(text.isEditable)
    #expect(text.text == "Accepted café 👩🏽‍💻")
    #expect(session.syncState.received.isEmpty)
}

@MainActor @Test func uiKitMarkedTextDefersRemoteChangesUntilCommit() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "uikit-ime", actorID: "a", document: document)
    let b = try EditorSession(documentID: "uikit-ime", actorID: "b", document: document)
    let model = try EditorModel(session: a)
    let coordinator = UIKitTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    defer { coordinator.close() }
    view.selectedRange = NSRange(location: 0, length: 0)
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.markedTextRange != nil)
    #expect(view.text == "漢Hello")
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    #expect(view.text == "漢Hello")
    view.unmarkText()
    #expect(view.text == "R漢Hello")
    #expect(view.selectedRange == NSRange(location: 2, length: 0))
    try a.undo()
    #expect(view.text == "RHello")
    #expect(model.error == nil)
}

@MainActor @Test func uiKitSelectionAndTypingFollowRemoteText() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello world")])
    let a = try EditorSession(documentID: "uikit-selection", actorID: "a", document: document)
    let b = try EditorSession(documentID: "uikit-selection", actorID: "b", document: document)
    let model = try EditorModel(session: a)
    var selected = NSRange(location: 0, length: 0)
    let coordinator = UIKitTextInput.Coordinator(model: model, address: TextAddress("p"), selection: Binding(get: { selected }, set: { selected = $0 }))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    defer { coordinator.close() }
    view.selectedRange = NSRange(location: 6, length: 5)
    try b.setText(at: TextAddress("p"), to: "RHello world"); try a.receive(b.changes())
    #expect(view.selectedRange == NSRange(location: 7, length: 5))
    #expect(selected == view.selectedRange)
    try a.format(at: TextAddress("p"), range: selected.location..<NSMaxRange(selected), markType: "bold", mark: .object(["type": .string("bold")]))
    let nodes = try a.document.blocks[0].fields["content"]?.array ?? []
    #expect(nodes.first?["text"] == .string("RHello "))
    #expect(nodes.last?["text"] == .string("world"))
    #expect(nodes.last?["marks"]?.array?.first?["type"] == .string("bold"))
    view.insertText("there")
    #expect(try a.text(at: TextAddress("p")) == "RHello there")
    try a.undo()
    #expect(view.text == "RHello world")
    #expect(model.error == nil)
}
@MainActor @Test func disposedUIKitInputCannotCommitALateCompositionCallback() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "uikit-dispose", actorID: "a", document: document)
    let b = try EditorSession(documentID: "uikit-dispose", actorID: "b", document: document)
    let coordinator = UIKitTextInput.Coordinator(model: try EditorModel(session: a), address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    view.selectedRange = NSRange(location: 0, length: 0)
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    try b.setText(at: TextAddress("p"), to: "RHello"); try a.receive(b.changes())
    coordinator.close()
    #expect(try a.text(at: TextAddress("p")) == "RHello")
    view.unmarkText()
    view.insertText("late")
    #expect(try a.text(at: TextAddress("p")) == "RHello")
    #expect(!a.canUndo)
}
@MainActor @Test func uiKitToolbarUndoCommitsCompositionBeforeUndoAndRemoteReplay() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let a = try EditorSession(documentID: "toolbar-composition", actorID: "a", document: document)
    let b = try EditorSession(documentID: "toolbar-composition", actorID: "b", document: document)
    try a.setText(at: TextAddress("p"), to: "HelloL")
    let model = try EditorModel(session: a)
    let coordinator = UIKitTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    defer { coordinator.close() }
    view.selectedRange = NSRange(location: 6, length: 0)
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    try b.setText(at: TextAddress("p"), to: "RHello")
    try a.receive(b.changes())
    model.perform { try $0.undo() }
    #expect(view.markedTextRange == nil)
    #expect(view.text == "RHelloL")
    #expect(try a.text(at: TextAddress("p")) == "RHelloL")
    #expect(a.syncState.received.contains(ChangeID(counter: 1, actor: "b")))
    #expect(model.error == nil)
    model.perform { try $0.redo() }
    #expect(view.text == "RHelloL漢")
    view.unmarkText()
    #expect(try a.text(at: TextAddress("p")) == "RHelloL漢")
}
#endif
