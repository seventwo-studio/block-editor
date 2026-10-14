#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor private final class ScopeTestClipboard: ModernClipboardAccess {
    var copies = 0
    func read() throws -> ModernClipboardPayload? { nil }
    func publish(_ clipboard: ModernClipboard) throws -> Bool { copies += 1; return true }
}

@MainActor @Suite struct ModernNativeModelScopeTests {
    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }
    private func window<V: View>(_ root: V) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root); window.contentView = host
        host.layoutSubtreeIfNeeded(); return (window, host)
    }
    @Test(arguments: ["document", "epoch", "actor", "model"])
    func replacingModelRebindsEqualFieldIdentitiesToTheirActualSession(change: String) async throws {
        let first = try ModernSession(documentID: "first", actorID: "a", epoch: "e", document: ModernDocument(documentID: "first", blocks: [.paragraph(id: "p", text: "FIRST")]))
        let documentID = change == "document" ? "second" : "first"
        let newText = change == "model" ? "FIRST" : "SECOND"
        let second = try ModernSession(documentID: documentID, actorID: change == "actor" ? "b" : "a", epoch: change == "epoch" ? "new" : "e", document: ModernDocument(documentID: documentID, blocks: [.paragraph(id: "p", text: newText)]))
        let oldModel = ModernEditorModel(session: first), newModel = ModernEditorModel(session: second)
        let oldField = try first.field(node: first.node(at: NodeAddress("p"))), newField = try second.field(node: second.node(at: NodeAddress("p")))
        #expect(oldField == newField)
        let (window, host) = window(ModernTextInput(model: oldModel, field: oldField))
        defer { window.close() }
        let oldView = try #require(textViews(host).first), original = try first.save()
        oldModel.isActive = false
        host.rootView = ModernTextInput(model: newModel, field: newField)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where textViews(host).first === oldView { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(textViews(host).first)
        #expect(view !== oldView && view.string == newText)
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: newText.utf16.count, length: 0))
        view.insertText("!", replacementRange: NSRange(location: newText.utf16.count, length: 0))
        #expect(try second.text(in: newField) == newText + "!")
        #expect(try first.save() == original)
        #expect(newModel.error == nil)
    }

    @Test func emptyDocumentBoundaryRebindsAndRetainsOriginalMarkedInput() async throws {
        let a = try ModernSession(documentID: "empty-a", actorID: "a", epoch: "e", document: ModernDocument(documentID: "empty-a"))
        let b = try ModernSession(documentID: "empty-b", actorID: "a", epoch: "e", document: ModernDocument(documentID: "empty-b"))
        let oldModel = ModernEditorModel(session: a), newModel = ModernEditorModel(session: b)
        let (window, host) = window(ModernEmptyTextInput(model: oldModel))
        defer { window.close() }
        let oldView = try #require(textViews(host).first)
        #expect(window.makeFirstResponder(oldView))
        oldView.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let original = try a.save(), retained = oldModel.clipboard.retained
        oldModel.isActive = false
        host.rootView = ModernEmptyTextInput(model: newModel)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where textViews(host).first === oldView { try await Task.sleep(for: .milliseconds(10)) }
        let view = try #require(textViews(host).first)
        #expect(view !== oldView && view.string.isEmpty)
        #expect(window.makeFirstResponder(view))
        view.insertText("New 😀", replacementRange: NSRange(location: 0, length: 0))
        #expect(b.document.blocks.count == 1 && b.document.blocks.first?.text == "New 😀")
        #expect(try a.save() == original)
        let detached = retained.map { ModernRetainedClipboard(id: $0.id, documentID: $0.documentID, epoch: $0.epoch,
            payload: $0.payload, purpose: $0.purpose, reason: "awaitingCommit") }
        #expect(retained.count == 1 && retained[0].payload == .text("東京"))
        #expect(oldModel.clipboard.retained == detached && !a.isComposing)
        let restored = try oldModel.checkpoint().restore()
        #expect(restored.session.document == a.document && restored.retainedClipboard == detached)
        #expect(newModel.error == nil)
    }

    @Test func updatedHostInteractionsKeepCompositionAndUseCurrentCallbacksAndClipboard() async throws {
        let session = try ModernSession(documentID: "callbacks", actorID: "a", epoch: "e", document: ModernDocument(documentID: "callbacks", blocks: [.paragraph(id: "p", text: "A")]))
        let model = ModernEditorModel(session: session), field = try session.field(node: session.node(at: NodeAddress("p")))
        let oldClipboard = ScopeTestClipboard(), newClipboard = ScopeTestClipboard()
        var calls: [String] = []
        let (window, host) = window(ModernTextInput(model: model, field: field,
            onSubmit: { calls.append("old submit"); return true }, onBoundary: { name in
                if name == "moveUp:" { calls.append("old boundary"); return true }; return false
            }, clipboard: oldClipboard))
        defer { window.close() }
        let view = try #require(textViews(host).first)
        #expect(window.makeFirstResponder(view))
        view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
        host.rootView = ModernTextInput(model: model, field: field, label: "Updated",
            onSubmit: { calls.append("new submit"); return true }, onBoundary: { name in
                if name == "moveUp:" { calls.append("new boundary"); return true }; return false
            }, clipboard: newClipboard)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where view.accessibilityLabel() != "Updated" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(textViews(host).first === view && view.hasMarkedText() && view.string == "A東京")
        view.unmarkText()
        #expect(try session.text(in: field) == "A東京")
        view.doCommand(by: Selector(("insertNewline:")))
        view.doCommand(by: Selector(("moveUp:")))
        view.setSelectedRange(NSRange(location: 0, length: 1)); view.copy(nil)
        #expect(calls == ["new submit", "new boundary"])
        #expect(newClipboard.copies == 1 && oldClipboard.copies == 0)
        #expect(model.error == nil)
    }
}
#endif
