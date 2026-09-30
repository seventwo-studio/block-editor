#if os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BlockEditorApple

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
    let coordinator = UIKitTextInput.Coordinator(model: model, address: TextAddress("p"), selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    defer { coordinator.close() }
    view.selectedRange = NSRange(location: 6, length: 5)
    try b.setText(at: TextAddress("p"), to: "RHello world"); try a.receive(b.changes())
    #expect(view.selectedRange == NSRange(location: 7, length: 5))
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
#endif
