#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

/// Offscreen component evidence; it does not establish real IME or keyboard input.
@MainActor @Test func fullEditorViewPreservesFocusedOriginAfterRemoteReparentAndLabelReuse() async throws {
    _ = NSApplication.shared
    let child = try Block.paragraph(id: "p", text: "ORIGINAL")
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"),
        "summary": .array([textNode("LEFT")]), "children": .array([.object(child.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"),
        "summary": .array([textNode("RIGHT")]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "focused-origin", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "focused-origin", actorID: "b", document: document, collaborationVersion: 2)
    let model = try EditorModel(session: a)
    let host = NSHostingView(rootView: BlockEditorView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.close() }
    func textViews(in view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if textViews(in: host).contains(where: { $0.string == "ORIGINAL" }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let previous = try #require(textViews(in: host).first { $0.string == "ORIGINAL" })
    previous.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(window.makeFirstResponder(previous))
    let identity = try b.node(at: NodeAddress("left", path: ["children", "p"]))
    try b.moveNode(identity, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    let replacement = try b.insertNode(.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields),
        into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "children"))
    try a.receive(b.changes())
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if textViews(in: host).contains(where: { $0.string == "REPLACEMENT" }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let originalView = try #require(textViews(in: host).first { $0.string == "ORIGINAL" })
    #expect(window.firstResponder === originalView)
    #expect(originalView.window === window)
    let focused = try #require(window.firstResponder as? NSTextView)
    focused.insertText("after-", replacementRange: NSRange(location: 0, length: 0))
    #expect(try a.text(at: a.textAddress(of: identity)) == "after-ORIGINAL")
    #expect(try a.text(at: a.textAddress(of: replacement)) == "REPLACEMENT")
    #expect(model.error == nil)
}
#endif
