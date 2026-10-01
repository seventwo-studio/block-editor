#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor @Test func fullEditorViewRebindsAReusedLabelToItsNewOrigin() async throws {
    let child = try Block.paragraph(id: "p", text: "ORIGINAL")
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([textNode("LEFT")]), "children": .array([.object(child.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([textNode("RIGHT")]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "view-identity", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "view-identity", actorID: "b", document: document, collaborationVersion: 2)
    let model = try EditorModel(session: a)
    let host = NSHostingView(rootView: BlockEditorView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
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
    let rendered = textViews(in: host)
    #expect(rendered.filter { $0.string == "ORIGINAL" }.count == 1)
    #expect(rendered.filter { $0.string == "REPLACEMENT" }.count == 1)
    #expect(!rendered.contains { $0 === previous })
    let replacementView = try #require(rendered.first { $0.string == "REPLACEMENT" })
    replacementView.setSelectedRange(NSRange(location: 0, length: 0))
    replacementView.insertText("new-", replacementRange: NSRange(location: 0, length: 0))
    #expect(try a.text(at: a.textAddress(of: replacement)) == "new-REPLACEMENT")
    #expect(try a.text(at: a.textAddress(of: identity)) == "ORIGINAL")
    #expect(model.error == nil)
}
#endif
