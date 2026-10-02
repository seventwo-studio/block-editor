#if os(macOS)
import AppKit
import BlockEditorCore
import Testing
@testable import BlockEditorApple

@MainActor private func pendingCaretWindow(list: Bool = false, emptyTail: Bool = false) throws -> (WritingSession, WritingEditorModel, NSWindow, WritingMacTextView, WritingMacTextInput.Coordinator) {
    let block = try Block(fields: list ? ["id": .string("p"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("i"), "content": .array([textNode(emptyTail ? "A" : "AB")]), "checked": .bool(true)])])] : ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode(emptyTail ? "A" : "AB")])])
    let a = try WritingSession(documentID: "pending-caret", actorID: "a", epoch: "v4", document: Document(blocks: [block]), protocolVersion: 4)
    let model = try WritingEditorModel(session: a)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let source = WritingMacTextView(), coordinator = WritingMacTextInput.Coordinator(model: model, address: list ? TextAddress("p", path: ["items", "i", "content"]) : TextAddress("p"))
    coordinator.connect(source); window.contentView?.addSubview(source); #expect(window.makeFirstResponder(source))
    source.setSelectedRange(NSRange(location: 1, length: 0)); coordinator.input.selection = source.selectedRange()
    return (a, model, window, source, coordinator)
}

@MainActor @Test func writingPendingCaretExpiresAfterSynchronousFocusAwayAndBackBeforeLayout() throws {
    let (a, model, window, source, coordinator) = try pendingCaretWindow()
    defer { coordinator.close(); window.close() }
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let oldTail = try #require(model.pendingCaret?.field.node)
    let external = NSTextView(); window.contentView?.addSubview(external)
    #expect(window.makeFirstResponder(external)); #expect(window.makeFirstResponder(source))
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(try a.text(at: oldTail.textAddressForApple("content")) == "B")
    #expect(a.document.blocks.map(\.text) == ["A", "", "B"])
}

@MainActor @Test func writingOrdinaryTypingBeforePendingTailLayoutUsesTheSharedDestination() throws {
    let (a, model, window, source, coordinator) = try pendingCaretWindow()
    defer { coordinator.close(); window.close() }
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let tail = try #require(model.pendingCaret?.field.node)
    source.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    source.insertText("😀", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(a.document.blocks.map(\.text) == ["A", "X😀B"])
    #expect(try model.pendingCaret?.field.node == tail && a.resolve(#require(model.pendingCaret)).offset == 3)
    #expect(try WritingSession.restore(a.save(), actorID: "a").document == a.document)
}

@MainActor @Test(arguments: [false, true], [false, true]) func writingPendingTargetMarkedInputCommitsBeforeAnotherEnterAndRetainsPeerUndo(list: Bool, emptyTail: Bool) throws {
    let (a, model, window, source, coordinator) = try pendingCaretWindow(list: list, emptyTail: emptyTail)
    defer { coordinator.close(); window.close() }
    let original = coordinator.input.address
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let tail = try #require(model.pendingCaret?.field.node), b = try WritingSession.restore(a.save(), actorID: "b")
    source.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(source.hasMarkedText() && a.isComposing)
    try b.replaceText(at: original, range: 0..<0, with: "L"); try a.receive(b.changes())
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let final = try #require(model.pendingCaret?.field.node)
    #expect(!source.hasMarkedText() && !a.isComposing && model.error == nil)
    #expect(try a.text(at: original) == "LA" && a.text(at: tail.textAddressForApple("content")) == "東京")
    #expect(try a.text(at: final.textAddressForApple("content")) == (emptyTail ? "" : "B"))
    try b.receive(a.changes()); #expect(a.document == b.document)
    model.perform { try $0.undo() }; #expect(try a.text(at: tail.textAddressForApple("content")) == (emptyTail ? "東京" : "東京B"))
    model.perform { try $0.undo() }; #expect(try a.text(at: original) == "LA" && a.text(at: tail.textAddressForApple("content")) == (emptyTail ? "" : "B"))
    #expect(try WritingSession.restore(a.save(), actorID: "a").document == a.document)
}


@MainActor @Test func writingPendingTargetSelectionFormatsItsRenderedRichFieldBeforeLayout() throws {
    let (a, model, window, source, coordinator) = try pendingCaretWindow()
    defer { coordinator.close(); window.close() }
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let tail = try #require(model.pendingCaret?.field.node)
    #expect(source.string == "B")
    source.setSelectedRange(NSRange(location: 0, length: 1), affinity: .upstream, stillSelecting: false)
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: source))
    source.formatSelection?("bold")
    let address = try a.address(of: tail), tailBlock = try #require(a.document.blocks.first { $0.id == address.blockID })
    let content = try #require(tailBlock.fields["content"]?.array)
    #expect(content.first?["marks"] == .array([.object(["type": .string("bold")])]))
    #expect(a.document.blocks.first?.fields["content"]?.array?.first?["marks"] == .array([]))
    #expect(source.selectedRange() == NSRange(location: 0, length: 1) && source.string == "B")
}

@MainActor @Test func writingEmptyTailUndoAndRedoRetainsNativeHeadPositionProvenance() async throws {
    let (a, model, window, source, coordinator) = try pendingCaretWindow(emptyTail: true)
    defer { coordinator.close(); window.close() }
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let target = try #require(model.pendingCaret?.field.node), tail = WritingMacTextView(), first = WritingMacTextInput.Coordinator(model: model, address: target.textAddressForApple("content"))
    first.connect(tail); window.contentView?.addSubview(tail); model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === tail)
    model.perform { try $0.undo() }; tail.removeFromSuperview(); first.close()
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === source && source.selectedRange() == NSRange(location: 1, length: 0))
    model.perform { try $0.redo() }
    let restored = WritingMacTextView(), second = WritingMacTextInput.Coordinator(model: model, address: target.textAddressForApple("content"))
    second.connect(restored); window.contentView?.addSubview(restored); defer { second.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === restored && restored.selectedRange() == NSRange(location: 0, length: 0))
    #expect(a.document.blocks.map(\.text) == ["A", ""])
}

#endif
