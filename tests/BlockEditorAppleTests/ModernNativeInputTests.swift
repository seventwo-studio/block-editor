#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor private struct ModernInputTestCanvas: View {
    let model: ModernEditorModel
    var body: some View {
        VStack {
            ModernTextInput(model: model, field: model.session.titleField, label: "title")
            ForEach(model.document.blocks) { block in
                if let field = try? model.session.field(node: model.session.node(at: NodeAddress(block.id))) {
                    ModernTextInput(model: model, field: field, label: block.id)
                }
            }
        }.frame(width: 500)
    }
}

@MainActor @Suite struct ModernNativeInputTests {
    private func pair() throws -> (ModernSession, ModernSession, ModernEditorModel) {
        let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("external"), "label": .string("REF")])
        let p = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "host": .string("keep"),
            "content": .array([.object(["type": .string("text"), "text": .string("ABC"), "marks": .array([.object(["type": .string("bold")])])]), reference])])
        let doc = try ModernDocument(documentID: "native", title: "Title", blocks: [p, .paragraph(id: "q", text: "Other")])
        let a = try ModernSession(documentID: "native", actorID: "a", epoch: "native", document: doc)
        return (a, try ModernSession(documentID: "native", actorID: "b", epoch: "native", document: doc), ModernEditorModel(session: a))
    }
    private func window(_ model: ModernEditorModel) -> NSWindow {
        let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        value.isReleasedWhenClosed = false
        value.contentView = NSHostingView(rootView: ModernInputTestCanvas(model: model))
        value.contentView?.layoutSubtreeIfNeeded(); return value
    }
    private func input(_ label: String, in root: NSView?) throws -> NSTextView {
        func collect(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(collect) }
        let views = root.map(collect) ?? []
        return try #require(views.first(where: { $0.accessibilityLabel() == label }))
    }
    @Test func nativeCompositionPairsOriginalBufferAndPreservesPeerAndRichAtomsThroughUndo() async throws {
        let (a, b, model) = try pair(), window = window(model); defer { window.close() }
        let view = try input("p", in: window.contentView)
        #expect(window.makeFirstResponder(view)); view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("東京😀", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 3, length: 0))
        #expect(view.hasMarkedText() && a.isComposing)
        let field = try b.field(node: b.node(at: NodeAddress("p")))
        try b.replaceText(in: field, range: 0..<0, with: "R"); try model.receive(b.changes())
        #expect(a.document.blocks[0].text == "ABCREF")
        let checkpoint = try model.checkpoint(), draft = try #require(checkpoint.pendingInputs.first)
        #expect(draft.text == "東京😀" && draft.nativeText == "ABC東京😀REF")
        let restarted = try checkpoint.restore()
        #expect(restarted.pendingInputs == checkpoint.pendingInputs && restarted.session.document == a.document)
        view.unmarkText()
        #expect(a.document.blocks[0].text == "RABC東京😀REF")
        #expect(view.string == "RABC東京😀REF" && !a.isComposing && model.error == nil)
        #expect(a.document.blocks[0].fields["host"] == .string("keep"))
        #expect(a.document.blocks[0].fields["content"]?.array?.contains(where: { $0["entityId"] == .string("external") }) == true)
        #expect(a.document.blocks[0].fields["content"] == .array([
            .object(["type": .string("text"), "text": .string("RABC東京😀"), "marks": .array([.object(["type": .string("bold")])])]),
            .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("external"), "label": .string("REF")])
        ]))
        try model.undo(); try await Task.sleep(for: .milliseconds(35))
        #expect(a.document.blocks[0].text == "RABCREF" && view.string == "RABCREF")
        try model.redo(); try await Task.sleep(for: .milliseconds(35))
        #expect(a.document.blocks[0].text == "RABC東京😀REF" && view.string == "RABC東京😀REF")
    }
    @Test func commandFocusUsesOriginalWindowAndIntentionalBlurCancelsDelayedTransfer() async throws {
        let (a, _, model) = try pair(), first = window(model), second = window(model)
        defer { first.close(); second.close() }
        let source = try input("p", in: first.contentView)
        #expect(first.makeFirstResponder(source)); source.setSelectedRange(NSRange(location: 1, length: 0))
        let field = try a.field(node: a.node(at: NodeAddress("p")))
        try model.perform { session in try session.splitBlock(in: session.captureTextRange(in: field, start: 1, end: 1), newBlockID: "tail").focus }
        try await Task.sleep(for: .milliseconds(80)); first.contentView?.layoutSubtreeIfNeeded(); second.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(35))
        let tail = try input("tail", in: first.contentView), otherTail = try input("tail", in: second.contentView)
        #expect(first.firstResponder === tail && second.firstResponder !== otherTail)
        #expect(tail.selectedRange() == NSRange(location: 0, length: 0))
        try model.undo()
        let external = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        first.contentView?.addSubview(external); #expect(first.makeFirstResponder(external))
        try await Task.sleep(for: .milliseconds(80))
        #expect(first.firstResponder === external)
        #expect(a.document.blocks.map(\.id) == ["p", "q"])
    }
    @Test func rejectedNativeEditRetainsTheExactBufferAndAcceptedCheckpoint() throws {
        let (a, _, model) = try pair(), window = window(model); defer { window.close() }
        let view = try input("p", in: window.contentView), before = try a.save()
        #expect(window.makeFirstResponder(view)); view.setSelectedRange(NSRange(location: 3, length: 0))
        a.allowedCommands = ["setAppearance"]
        view.insertText("保留😀", replacementRange: NSRange(location: 3, length: 0))
        #expect(try a.save() == before && model.error != nil)
        let draft = try #require(model.pendingInputs.values.first)
        #expect(draft.text == "保留😀" && draft.nativeText == "ABC保留😀REF")
        #expect(view.string == "ABC保留😀REF")
        let saved = try model.checkpoint(), restored = try saved.restore()
        #expect(restored.pendingInputs == [draft] && restored.session.document == a.document)
        #expect(throws: (any Error).self) { try model.perform { try $0.setAppearance(field: "fontSize", value: "large"); return nil } }
        #expect(try a.save() == before && model.pendingInputs.values.first == draft)
    }
}
#endif
