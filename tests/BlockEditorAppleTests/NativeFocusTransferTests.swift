#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

enum FocusReplayScenario: CaseIterable { case reparent, selectionRebase, consecutiveReceives }

/// Offscreen component evidence; it does not establish real IME or keyboard input.
@MainActor @Test(arguments: FocusReplayScenario.allCases)
func fullEditorViewPreservesFocusedOriginAfterRemoteReparentAndLabelReuse(scenario: FocusReplayScenario) async throws {
    let rebaseSelection = scenario != .reparent
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
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
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
    previous.setSelectedRange(rebaseSelection ? NSRange(location: 2, length: 3) : NSRange(location: 0, length: 0))
    #expect(window.makeFirstResponder(previous))
    let identity = try b.node(at: NodeAddress("left", path: ["children", "p"]))
    if rebaseSelection { try b.setText(at: b.textAddress(of: identity), to: "R-ORIGINAL") }
    try b.moveNode(identity, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    let replacement = try b.insertNode(.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields),
        into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "children"))
    try a.receive(b.changes())
    // Both receives complete before SwiftUI can replace the old native view.
    if scenario == .consecutiveReceives {
        try b.setText(at: b.textAddress(of: identity), to: "R2-R-ORIGINAL")
        try a.receive(b.changes())
    }
    let expectedOriginal = scenario == .consecutiveReceives ? "R2-R-ORIGINAL" : (rebaseSelection ? "R-ORIGINAL" : "ORIGINAL")
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if textViews(in: host).contains(where: { $0.string == "REPLACEMENT" }),
           (window.firstResponder as? NSTextView)?.string == expectedOriginal { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let originalView = try #require(textViews(in: host).first { $0.string == expectedOriginal })
    #expect(window.firstResponder === originalView)
    #expect(originalView.window === window)
    let focused = try #require(window.firstResponder as? NSTextView)
    let expectedSelection = scenario == .consecutiveReceives ? NSRange(location: 7, length: 3) : (rebaseSelection ? NSRange(location: 4, length: 3) : NSRange(location: 0, length: 0))
    #expect(focused.selectedRange() == expectedSelection)
    focused.insertText("after-", replacementRange: NSRange(location: NSNotFound, length: 0))
    let expectedText = scenario == .consecutiveReceives ? "R2-R-ORafter-NAL" : (rebaseSelection ? "R-ORafter-NAL" : "after-ORIGINAL")
    #expect(try a.text(at: a.textAddress(of: identity)) == expectedText)
    #expect(try a.text(at: a.textAddress(of: replacement)) == "REPLACEMENT")
    #expect(model.error == nil)
}
/// The remote batch stays deferred while marked text belongs to the old view.
@MainActor @Test func fullEditorFocusHandoffWaitsForCompositionCommit() async throws {
    _ = NSApplication.shared
    let child = try Block.paragraph(id: "p", text: "ORIGINAL")
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"),
        "summary": .array([textNode("LEFT")]), "children": .array([.object(child.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"),
        "summary": .array([textNode("RIGHT")]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "composition-focus", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "composition-focus", actorID: "b", document: document, collaborationVersion: 2)
    let model = try EditorModel(session: a)
    let host = NSHostingView(rootView: BlockEditorView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
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
    previous.setSelectedRange(NSRange(location: 2, length: 0))
    #expect(window.makeFirstResponder(previous))
    previous.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let identity = try b.node(at: NodeAddress("left", path: ["children", "p"]))
    try b.moveNode(identity, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    let replacement = try b.insertNode(.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields),
        into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "children"))
    try a.receive(b.changes())
    #expect(window.firstResponder === previous)
    #expect(previous.hasMarkedText())
    #expect(try a.address(of: identity).blockID == "left")
    previous.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if (window.firstResponder as? NSTextView)?.string == "OR漢字IGINAL", window.firstResponder !== previous { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let focused = try #require(window.firstResponder as? NSTextView)
    #expect(focused !== previous)
    #expect(!focused.hasMarkedText())
    #expect(focused.selectedRange() == NSRange(location: 4, length: 0))
    #expect(try a.address(of: identity).blockID == "right")
    focused.insertText("after-", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(try a.text(at: a.textAddress(of: identity)) == "OR漢字after-IGINAL")
    #expect(try a.text(at: a.textAddress(of: replacement)) == "REPLACEMENT")
    #expect(model.error == nil)
}

@MainActor @Test func focusHandoffDoesNotOverrideAnotherNativeResponder() async throws {
    _ = NSApplication.shared
    let session = try EditorSession(documentID: "focus-choice", actorID: "a",
        document: Document(blocks: [.paragraph(id: "p", text: "ORIGINAL"), .paragraph(id: "q", text: "OTHER")]),
        collaborationVersion: 2)
    let model = try EditorModel(session: session)
    let original = CollaborativeInput(model: model, address: TextAddress("p"))
    let replacement = CollaborativeInput(model: model, address: TextAddress("p"))
    defer { original.close(); replacement.close() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let old = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
    let moved = ComposingTextView(frame: NSRect(x: 0, y: 50, width: 200, height: 50))
    let other = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 50))
    container.addSubview(old); container.addSubview(moved); container.addSubview(other)
    window.contentView = container
    model.macFocus.register(old, input: original)
    model.macFocus.register(moved, input: replacement)
    #expect(window.makeFirstResponder(old))
    model.macFocus.capture(old, input: original)
    old.removeFromSuperview()
    model.macFocus.unregister(old)
    #expect(window.makeFirstResponder(other))
    try await Task.sleep(for: .milliseconds(20))
    #expect(window.firstResponder === other)
    // Once the user's choice wins, a later layout must not resurrect the capture.
    #expect(window.makeFirstResponder(nil))
    model.macFocus.restoreAfterLayout()
    try await Task.sleep(for: .milliseconds(20))
    #expect(window.firstResponder !== moved)
    model.macFocus.unregister(moved)
}

@MainActor @Test func unchangedReplayDoesNotLeaveFocusCaptureForALaterReparent() async throws {
    _ = NSApplication.shared
    let child = try Block.paragraph(id: "p", text: "ORIGINAL")
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"),
        "summary": .array([textNode("LEFT")]), "children": .array([.object(child.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"),
        "summary": .array([textNode("RIGHT")]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "stale-focus", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "stale-focus", actorID: "b", document: document, collaborationVersion: 2)
    let model = try EditorModel(session: a)
    let host = NSHostingView(rootView: BlockEditorView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
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
    #expect(window.makeFirstResponder(previous))
    try b.setText(at: TextAddress("left", path: ["summary"]), to: "LEFT-REMOTE")
    try a.receive(b.changes())
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(20))
    #expect(window.firstResponder === previous)
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
    host.addSubview(other)
    #expect(window.makeFirstResponder(other))
    #expect(window.makeFirstResponder(nil))
    other.removeFromSuperview()
    let identity = try b.node(at: NodeAddress("left", path: ["children", "p"]))
    try b.moveNode(identity, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    try a.receive(b.changes())
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if !textViews(in: host).contains(where: { $0 === previous }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(20))
    let moved = try #require(textViews(in: host).first { $0.string == "ORIGINAL" })
    #expect(window.firstResponder !== moved)
    #expect(try a.address(of: identity).blockID == "right")
    #expect(model.error == nil)
}

#endif
