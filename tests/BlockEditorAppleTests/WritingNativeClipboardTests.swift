#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor @Test(arguments: [4, 5, 6])
func writingNativeClipboardKeepsExplicitProtocolAndEpoch(version: Int) throws {
    let session = try WritingSession(documentID: "native-clipboard-version", actorID: "a", epoch: "explicit-\(version)", document: Document(blocks: [.paragraph(id: "p", text: "A")]), protocolVersion: version)
    let model = try WritingEditorModel(session: session)
    #expect(model.session.protocolVersion == version)
    let persisted = try JSONDecoder().decode(JSONValue.self, from: model.session.save())
    #expect(persisted["epoch"] == .string("explicit-\(version)"))
    #expect(persisted["version"] == .number(Double(version)))
}

/// Native component callbacks do not establish installed OS IME/clipboard acceptance.
@MainActor @Test(arguments: [4, 5, 6])
func writingNativeStructuredPasteFinalizesMarkedDraftAndKeepsPeerAuthorHistory(version: Int) async throws {
    _ = NSApplication.shared
    let document = try Document(blocks: [.paragraph(id: "p", text: "AB")])
    let a = try WritingSession(documentID: "native-clipboard", actorID: "a", epoch: "v\(version)", document: document, protocolVersion: version)
    let b = try WritingSession(documentID: "native-clipboard", actorID: "b", epoch: "v\(version)", document: document, protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = WritingMacTextView(); coordinator.connect(view); window.contentView?.addSubview(view)
    defer { coordinator.close(); window.contentView = nil; window.close() }
    #expect(window.makeFirstResponder(view))
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    _ = try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "R"); try a.receive(b.changes())
    #expect(a.isComposing && a.document.blocks[0].text == "AB")
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task"), "label": .string("TASK"), "host": .object(["id": .string("opaque-reference")])])
    let clipboard = WritingClipboard(parts: [.inline([textNode("X😀", marks: [.object(["type": .string("italic")])]), reference])])
    let callback = try #require(view.pasteSharedClipboard)
    #expect(try callback(.structured(WritingNativeClipboard.encode(clipboard))))
    try await Task.sleep(for: .milliseconds(50))
    #expect(!a.isComposing && model.error == nil && a.document.blocks[0].text == "A東京X😀TASKBR")
    #expect(view.string == "A東京X😀TASKBR")
    #expect(view.selectedRange() == NSRange(location: 10, length: 0))
    #expect((a.document.blocks[0].fields["content"]?.array ?? []).contains(reference))
    #expect((a.document.blocks[0].fields["content"]?.array ?? []).contains { $0["text"] == .string("X😀") && $0["marks"] == .array([.object(["type": .string("italic")])]) })
    try b.receive(a.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[0].text == "A東京BR")
    try reopened.redo(); #expect(reopened.document == a.document)
    try reopened.undo(); try reopened.undo(); #expect(reopened.document.blocks[0].text == "ABR")
}

@MainActor @Test(arguments: [4, 5, 6])
func writingNativePasteRespectsRetiredLeaseAndHostRestrictions(version: Int) throws {
    let a = try WritingSession(documentID: "native-clipboard-guard", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: "A")]), protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(); coordinator.connect(view)
    let callback = try #require(view.pasteSharedClipboard)
    let accepted = try a.save(); view.isEditable = false
    #expect(!callback(.text("blocked"))); #expect(try a.save() == accepted)
    view.isEditable = true; model.allowedBlockTypes = ["heading"]
    let disallowed = WritingClipboard(parts: [.node(value: .object(try Block.paragraph(id: "clipboard", text: "visible paragraph").fields), kind: "block")])
    #expect(try !callback(.structured(WritingNativeClipboard.encode(disallowed))))
    #expect(model.error != nil); #expect(try a.save() == accepted)
    model.allowedBlockTypes = nil
    #expect(!callback(.structured(Data("{invalid".utf8))))
    #expect(try a.save() == accepted)
    coordinator.close()
    #expect(!callback(.text("retired"))); #expect(try a.save() == accepted)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingNativeCopyRoundTripRetainsRichReferenceWithoutAuthorMutation(version: Int) throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task"), "label": .string("TASK"), "host": .string("opaque")])
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("😀", marks: [.object(["type": .string("bold")])]), reference])])
    let a = try WritingSession(documentID: "native-copy", actorID: "a", epoch: "v\(version)", document: Document(blocks: [block]), protocolVersion: version)
    let model = try WritingEditorModel(session: a), input = WritingCollaborativeInput(model: model, address: TextAddress("p"))
    defer { input.close() }
    input.selection = NSRange(location: 0, length: 6)
    let accepted = try a.save(), clipboard = try #require(input.copyClipboard())
    #expect(try WritingNativeClipboard.decode(.structured(WritingNativeClipboard.encode(clipboard))) == clipboard)
    #expect(clipboard.parts == [.inline(try #require(block.fields["content"]?.array))])
    #expect(try a.save() == accepted)
}
/// The old responder proxies a returned tail until the destination view attaches.
@MainActor @Test(arguments: [4, 5, 6], [false, true])
func writingNativePasteUsesPendingTailAfterMarkedCommitBeforeLayout(version: Int, emptyTail: Bool) throws {
    _ = NSApplication.shared
    let a = try WritingSession(documentID: "native-paste-pending-tail", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: emptyTail ? "A" : "AB")]), protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let source = WritingMacTextView(); coordinator.connect(source); window.contentView?.addSubview(source)
    defer { coordinator.close(); window.contentView = nil; window.close() }
    #expect(window.makeFirstResponder(source))
    source.setSelectedRange(NSRange(location: 1, length: 0)); coordinator.input.selection = source.selectedRange()
    source.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let tail = try #require(model.pendingCaret?.field.node)
    let b = try WritingSession.restore(a.save(), actorID: "b")
    source.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    _ = try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "L"); try a.receive(b.changes())
    #expect(source.hasMarkedText() && a.isComposing && a.document.blocks[0].text == "A")
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task"), "label": .string("TASK"), "host": .string("opaque")])
    let clipboard = WritingClipboard(parts: [.inline([textNode("X😀", marks: [.object(["type": .string("italic")])]), reference])])
    let callback = try #require(source.pasteSharedClipboard)
    #expect(try callback(.structured(WritingNativeClipboard.encode(clipboard))))
    #expect(!source.hasMarkedText() && !a.isComposing && model.error == nil)
    #expect(try a.text(at: TextAddress("p")) == "LA")
    #expect(try a.text(at: tail.textAddressForApple("content")) == "東京X😀TASK" + (emptyTail ? "" : "B"))
    #expect(model.pendingCaret?.field.node == tail)
    try b.receive(a.changes()); #expect(b.document == a.document)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(try reopened.text(at: TextAddress("p")) == "LA")
    #expect(try reopened.text(at: tail.textAddressForApple("content")) == "東京" + (emptyTail ? "" : "B"))
    try reopened.redo(); #expect(reopened.document == a.document)
    try reopened.undo(); try reopened.undo()
    #expect(try reopened.text(at: TextAddress("p")) == "LA")
    #expect(try reopened.text(at: tail.textAddressForApple("content")) == (emptyTail ? "" : "B"))
}
@MainActor @Test(arguments: [4, 5, 6], [false, true])
func writingNativePlainPasteUsesExistingSharedInlineCommand(version: Int, replacingSelection: Bool) async throws {
    _ = NSApplication.shared
    let a = try WritingSession(documentID: "native-plain-paste", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: "A")]), protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = WritingMacTextView(); coordinator.connect(view); window.contentView?.addSubview(view)
    defer { coordinator.close(); window.contentView = nil; window.close() }
    #expect(window.makeFirstResponder(view))
    let range = replacingSelection ? NSRange(location: 0, length: 1) : NSRange(location: 1, length: 0)
    view.setSelectedRange(range); coordinator.input.selection = view.selectedRange()
    let callback = try #require(view.pasteSharedClipboard)
    #expect(callback(.text("café😀")))
    try await Task.sleep(for: .milliseconds(50))
    let expected = replacingSelection ? "café😀" : "Acafé😀"
    #expect(model.error == nil && a.document.blocks.map(\.text) == [expected])
    #expect(view.string == expected)
    #expect(view.selectedRange() == NSRange(location: expected.utf16.count, length: 0))
    #expect(a.changes().changes.count == 1)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.protocolVersion == version && reopened.epoch == "v\(version)")
    try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["A"])
    try reopened.redo(); #expect(reopened.document == a.document)
    if version == 4 {
        let accepted = try a.save()
        let whole = WritingClipboard(parts: [.node(value: .object(try Block.paragraph(id: "external", text: "whole").fields), kind: "block")])
        #expect(try !callback(.structured(WritingNativeClipboard.encode(whole))))
        #expect(try a.save() == accepted && a.protocolVersion == 4)
        #expect(callback(.text("\nline")))
        #expect(a.document.blocks.count == 1 && a.document.blocks[0].text.contains("\nline"))
    }
}
#endif
