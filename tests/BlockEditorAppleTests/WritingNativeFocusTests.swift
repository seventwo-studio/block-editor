#if os(macOS)
import AppKit
import BlockEditorCore
import Testing
@testable import BlockEditorApple

@MainActor private func focusWritingPair() throws -> (WritingSession, WritingSession, WritingEditorModel) {
    let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    let document = try Document(blocks: [.paragraph(id: "p", text: "AB😀CD"), toggle])
    let a = try WritingSession(documentID: "focus-writing", actorID: "a", epoch: "v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "focus-writing", actorID: "b", epoch: "v4", document: document, protocolVersion: 4)
    return (a, b, try WritingEditorModel(session: a))
}

@MainActor @Test(arguments: [false, true]) func writingFocusTransfersOpaqueOriginAndUpstreamSelectionAfterReplay(rapidReceive: Bool) async throws {
    let (a, b, model) = try focusWritingPair()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), old = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    old.connect(source); window.contentView?.addSubview(source)
    #expect(window.makeFirstResponder(source))
    source.setSelectedRange(NSRange(location: 1, length: 4), affinity: .upstream, stillSelecting: false)
    old.input.selection = source.selectedRange(); old.input.selectionAffinity = source.selectionAffinity
    let identity = try a.node(at: NodeAddress("p")), owner = try b.node(at: NodeAddress("toggle"))
    try b.move(WritingSelection(nodes: [identity]), into: NodeCollection(owner: owner, field: "children"))
    try b.insertCollectionNodes([.object(Block.paragraph(id: "p", text: "replacement").fields)], into: .root)
    try a.receive(b.changes())
    if rapidReceive { try b.replaceText(at: identity.textAddressForApple("content"), range: 0..<0, with: "R"); try a.receive(b.changes()) }
    source.removeFromSuperview(); old.close()
    let reused = WritingMacTextView(), wrong = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    wrong.connect(reused); window.contentView?.addSubview(reused); defer { wrong.close() }
    let destination = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: TextAddress("toggle", path: ["children", "p", "content"]))
    current.connect(destination); window.contentView?.addSubview(destination); defer { current.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === destination)
    #expect(destination.selectedRange() == NSRange(location: rapidReceive ? 2 : 1, length: 4))
    #expect(destination.selectionAffinity == .upstream && reused.string == "replacement")
}

@MainActor @Test func writingTextOnlyReplayExpiresFocusCaptureBeforeIntentionalBlurAndLaterMove() async throws {
    let (a, b, model) = try focusWritingPair()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), old = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    old.connect(source); window.contentView?.addSubview(source); #expect(window.makeFirstResponder(source))
    try b.replaceText(at: TextAddress("p"), range: 6..<6, with: "R"); try a.receive(b.changes())
    let external = NSTextView(); window.contentView?.addSubview(external); #expect(window.makeFirstResponder(external)); #expect(window.makeFirstResponder(nil))
    let identity = try b.node(at: NodeAddress("p")); try b.move(WritingSelection(nodes: [identity]), into: NodeCollection(owner: b.node(at: NodeAddress("toggle")), field: "children")); try a.receive(b.changes())
    source.removeFromSuperview(); old.close()
    let destination = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: TextAddress("toggle", path: ["children", "p", "content"]))
    current.connect(destination); window.contentView?.addSubview(destination); defer { current.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder !== destination)
}
@MainActor @Test func writingRemoteSplitOfUnfocusedFieldDoesNotStealAnotherFieldsFocus() async throws {
    let (a, b, model) = try focusWritingPair()
    try b.insertCollectionNodes([.object(Block.paragraph(id: "right", text: "focused").fields)], into: .root)
    try a.receive(b.changes())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let left = WritingMacTextView(), right = WritingMacTextView(), tail = WritingMacTextView()
    let original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), focused = WritingMacTextInput.Coordinator(model: model, address: TextAddress("right"))
    original.connect(left); focused.connect(right); window.contentView?.addSubview(left); window.contentView?.addSubview(right)
    defer { original.close(); focused.close() }
    left.setSelectedRange(NSRange(location: 2, length: 0)); original.input.selection = left.selectedRange()
    #expect(window.makeFirstResponder(right))
    right.setSelectedRange(NSRange(location: 3, length: 0)); focused.input.selection = right.selectedRange()
    try b.splitParagraph(at: TextAddress("p"), range: 0..<0, newBlockID: "tail"); try a.receive(b.changes())
    let destination = WritingMacTextInput.Coordinator(model: model, address: TextAddress("tail")); destination.connect(tail); window.contentView?.addSubview(tail); defer { destination.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === right && right.selectedRange() == NSRange(location: 3, length: 0))
}
@MainActor @Test(arguments: [0, 3], [false, true]) func writingLocalUndoRebasesFocusedTailToOriginalFieldDuringNativeLayout(selectionLength: Int, remoteEdit: Bool) async throws {
    let (a, b, model) = try focusWritingPair()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    original.connect(source); window.contentView?.addSubview(source); defer { original.close() }
    #expect(window.makeFirstResponder(source)); source.setSelectedRange(NSRange(location: 1, length: 0)); original.input.selection = source.selectedRange()
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let target = try #require(model.pendingCaret?.field.node), tail = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: target.textAddressForApple("content"))
    current.connect(tail); window.contentView?.addSubview(tail); model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === tail)
    if remoteEdit {
        try b.receive(a.changes()); try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "L")
        try b.replaceText(at: target.textAddressForApple("content"), range: 5..<5, with: "R"); try a.receive(b.changes())
    }
    tail.setSelectedRange(NSRange(location: 0, length: selectionLength), affinity: .upstream, stillSelecting: false)
    current.input.selection = tail.selectedRange(); current.input.selectionAffinity = tail.selectionAffinity
    let retainedAffinity = tail.selectionAffinity
    #expect(selectionLength == 0 || retainedAffinity == .upstream)
    model.perform { try $0.undo() }
    tail.removeFromSuperview(); current.close(); model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === source && source.selectedRange() == NSRange(location: remoteEdit ? 2 : 1, length: selectionLength))
    #expect(source.selectionAffinity == retainedAffinity)
    #expect(a.document.blocks.first?.text == (remoteEdit ? "LAB😀CDR" : "AB😀CD"))
    model.perform { try $0.redo() }
    let restored = WritingMacTextView(), reopened = WritingMacTextInput.Coordinator(model: model, address: target.textAddressForApple("content"))
    reopened.connect(restored); window.contentView?.addSubview(restored); defer { reopened.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === restored && restored.selectedRange() == NSRange(location: 0, length: selectionLength))
    #expect(restored.selectionAffinity == retainedAffinity)
    #expect(a.document.blocks.first?.text == (remoteEdit ? "LA" : "A"))
    #expect(restored.string == (remoteEdit ? "B😀CDR" : "B😀CD"))
}

@MainActor @Test(arguments: [false, true]) func writingSplitTailUndoKeepsEmptyOrAtomicReferenceBoundary(empty: Bool) async throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task"), "label": .string("TASK")])
    let block = empty ? try Block.paragraph(id: "p", text: "A") : try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A"), reference, textNode("B")])])
    let a = try WritingSession(documentID: "native-boundary", actorID: "a", epoch: "v4", document: Document(blocks: [block]), protocolVersion: 4)
    let model = try WritingEditorModel(session: a)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    original.connect(source); window.contentView?.addSubview(source); defer { original.close() }
    #expect(window.makeFirstResponder(source)); source.setSelectedRange(NSRange(location: 1, length: 0)); original.input.selection = source.selectedRange()
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let target = try #require(model.pendingCaret?.field.node), tail = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: target.textAddressForApple("content"))
    current.connect(tail); window.contentView?.addSubview(tail); model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === tail)
    model.perform { try $0.undo() }
    tail.removeFromSuperview(); current.close(); model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === source && source.selectedRange() == NSRange(location: 1, length: 0))
    #expect(a.document.blocks.first?.text == (empty ? "A" : "ATASKB"))
}

@MainActor @Test func writingFailedLocalCommandExpiresCaptureBeforeIntentionalBlurAndRemoteReparent() async throws {
    let (a, b, model) = try focusWritingPair()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    original.connect(source); window.contentView?.addSubview(source); #expect(window.makeFirstResponder(source))
    let accepted = try a.save()
    model.perform { try $0.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "unsupported")) }
    #expect(try a.save() == accepted && model.error != nil)
    let external = NSTextView(); window.contentView?.addSubview(external); #expect(window.makeFirstResponder(external)); #expect(window.makeFirstResponder(nil))
    let identity = try b.node(at: NodeAddress("p")); try b.move(WritingSelection(nodes: [identity]), into: NodeCollection(owner: b.node(at: NodeAddress("toggle")), field: "children")); try a.receive(b.changes())
    source.removeFromSuperview(); original.close()
    let view = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: identity.textAddressForApple("content"))
    current.connect(view); window.contentView?.addSubview(view); defer { current.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder !== view)
}

@MainActor @Test func writingDetachedNativeSourceCannotUseRetainedKeyCallbackBeforeDisposal() throws {
    let (a, _, model) = try focusWritingPair()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = WritingMacTextView(), original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    original.connect(source); window.contentView?.addSubview(source); defer { original.close() }
    #expect(window.makeFirstResponder(source)); source.setSelectedRange(NSRange(location: 1, length: 0)); original.input.selection = source.selectedRange()
    let retained = try #require(source.command), accepted = try a.save()
    // Admit one live no-mutation key attempt to record the actual window lease.
    #expect(!retained(.backspace))
    source.removeFromSuperview()
    #expect(!retained(.enter)); #expect(try a.save() == accepted)
}

@MainActor @Test func writingPendingCaretDoesNotRouteAnotherFocusedInputOrRevokedSourceCallback() async throws {
    let (a, _, model) = try focusWritingPair()
    model.perform { try $0.insertCollectionNodes([.object(Block.paragraph(id: "right", text: "R").fields)], into: .root) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let left = WritingMacTextView(), right = WritingMacTextView(), original = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), other = WritingMacTextInput.Coordinator(model: model, address: TextAddress("right"))
    original.connect(left); other.connect(right); window.contentView?.addSubview(left); window.contentView?.addSubview(right)
    defer { original.close(); other.close() }
    #expect(window.makeFirstResponder(left)); left.setSelectedRange(NSRange(location: 1, length: 0)); original.input.selection = left.selectedRange()
    left.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let oldCaret = try #require(model.pendingCaret), accepted = try a.save(), retained = try #require(left.command)
    #expect(window.makeFirstResponder(right)); #expect(!retained(.enter)); #expect(try a.save() == accepted)
    right.setSelectedRange(NSRange(location: 1, length: 0)); other.input.selection = right.selectedRange()
    right.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(try a.text(at: oldCaret.field.node.textAddressForApple("content")) == "B😀CD")
    #expect(a.document.blocks.first { $0.id == "right" }?.text == "R")
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
}
#endif
