#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor @Suite struct ModernAccessibilityLabelTests {
    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }
    private func window<V: View>(_ content: V) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    @Test func updatedHostLabelPreservesMarkedBufferIdentityAndFirstResponder() async throws {
        let document = try ModernDocument(documentID: "labels", blocks: [.paragraph(id: "p", text: "A😀")])
        let session = try ModernSession(documentID: "labels", actorID: "a", epoch: "e", document: document)
        let model = ModernEditorModel(session: session), field = try session.field(node: session.node(at: NodeAddress("p")))
        let (window, host) = window(ModernTextInput(model: model, field: field, label: "Block text"))
        defer { window.close() }
        let view = try #require(textViews(host).first)
        #expect(view.accessibilityLabel() == "Block text")
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 3, length: 0))
        let before = try session.save(), pending = try model.checkpoint().pendingInputs
        host.rootView = ModernTextInput(model: model, field: field, label: "Updated narrative")
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where view.accessibilityLabel() != "Updated narrative" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.accessibilityLabel() == "Updated narrative")
        #expect(textViews(host).first === view && window.firstResponder === view)
        #expect(view.hasMarkedText() && view.string == "A😀東京" && session.isComposing)
        #expect(try session.save() == before && model.checkpoint().pendingInputs == pending)
        view.unmarkText()
        #expect(try session.text(in: field) == "A😀東京")
    }
    @Test func fullEditorConversionAndUndoRefreshNativeAccessibleName() async throws {
        let document = try ModernDocument(documentID: "heading-label", blocks: [.paragraph(id: "p", text: "A😀")])
        let session = try ModernSession(documentID: "heading-label", actorID: "a", epoch: "e", document: document)
        let model = ModernEditorModel(session: session), node = try session.node(at: NodeAddress("p"))
        let (window, host) = window(ModernBlockEditorView(model: model))
        defer { window.close() }
        let view = try #require(textViews(host).first { $0.string == "A😀" })
        #expect(view.accessibilityLabel() == "Block text")
        _ = try session.convertBlocks(session.captureNodes([node]), to: WritingBlockTarget(type: "heading", level: 2))
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where view.accessibilityLabel() != "Heading" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.accessibilityLabel() == "Heading")
        #expect(textViews(host).contains { $0 === view } && view.string == "A😀")
        #expect(try session.node(at: NodeAddress("p")) == node)
        try session.undo()
        host.layoutSubtreeIfNeeded()
        for _ in 0..<20 where view.accessibilityLabel() != "Block text" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.accessibilityLabel() == "Block text" && view.string == "A😀")
        #expect(session.document == document)
    }
}
#endif
