#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor private func writingPair(_ blocks: [Block]) throws -> (WritingSession, WritingSession, WritingEditorModel) {
    let document = try Document(blocks: blocks)
    let a = try WritingSession(documentID: "native-writing", actorID: "a", epoch: "native-v4", document: document, protocolVersion: 4)
    let b = try WritingSession(documentID: "native-writing", actorID: "b", epoch: "native-v4", document: document, protocolVersion: 4)
    return (a, b, try WritingEditorModel(session: a))
}

/// Direct native-control evidence; it does not establish real OS IME/device input.
@MainActor @Test func writingAppKitCompositionCommitsBeforeEnterAndKeepsPeerUndo() throws {
    let (a, b, model) = try writingPair([.paragraph(id: "p", text: "AB")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    #expect(view.hasMarkedText() && a.isComposing && a.document.blocks[0].text == "AB")
    try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "R")
    try a.receive(b.changes()); #expect(a.document.blocks[0].text == "AB")
    view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(!view.hasMarkedText() && !a.isComposing && model.error == nil)
    #expect(a.document.blocks.map(\.text) == ["A東京", "BR"])
    #expect(a.changes().version == 4)
    try b.receive(a.changes()); #expect(a.document == b.document)
    model.perform { try $0.undo() }; #expect(a.document.blocks.map(\.text) == ["A東京BR"])
    model.perform { try $0.undo() }; #expect(a.document.blocks.map(\.text) == ["ABR"])
    #expect(try WritingSession.restore(a.save(), actorID: "a").document == a.document)
}

@MainActor @Test func writingAppKitMinimalDraftPreservesMarksReferenceAndRejectsPartialReference() throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task"), "label": .string("TASK")])
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("A😀", marks: [.object(["type": .string("bold")])]), reference, textNode("B", marks: [.object(["type": .string("italic")])])])])
    let (a, _, model) = try writingPair([block])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    #expect(try a.text(at: TextAddress("p")) == "xA😀TASKB")
    let content = try #require(a.document.blocks[0].fields["content"]?.array)
    #expect(content.contains(reference))
    #expect(content.first?["marks"] == .array([.object(["type": .string("bold")])]))
    #expect(content.last?["marks"] == .array([.object(["type": .string("italic")])]))
    let accepted = try a.save()
    view.insertText("?", replacementRange: NSRange(location: 5, length: 1))
    #expect(try model.error != nil && a.save() == accepted)
    #expect(view.string == "xA😀TASKB")
}

@MainActor @Test func writingAppKitSoftBreakAndBoundaryBackspaceUseSharedTransactions() throws {
    let (a, b, model) = try writingPair([.paragraph(id: "left", text: "B"), .paragraph(id: "right", text: "C")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("right")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: 0))
    try b.replaceText(at: TextAddress("left"), range: 0..<0, with: "R"); try a.receive(b.changes())
    view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    #expect(model.error == nil && a.document.blocks.map(\.text) == ["RB東京C"])
    model.perform { try $0.undo() }; #expect(a.document.blocks.map(\.text) == ["RB", "東京C"])
    view.setSelectedRange(NSRange(location: 2, length: 0)); coordinator.input.selection = view.selectedRange()
    view.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
    #expect(model.error == nil && a.document.blocks.map(\.text) == ["RB", "東京\nC"])
    model.perform { try $0.undo() }; #expect(a.document.blocks.map(\.text) == ["RB", "東京C"])
}

@MainActor @Test func writingCompositionMenuUsesCapturedOriginAfterQueuedReparentAndLabelReuse() throws {
    let original = try Block.paragraph(id: "p", text: "A")
    let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    let (a, b, model) = try writingPair([original, toggle])
    let identity = try a.node(at: NodeAddress("p")), coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    try b.move(WritingSelection(nodes: [identity]), into: NodeCollection(owner: b.node(at: NodeAddress("toggle")), field: "children"))
    try b.insertCollectionNodes([.object(Block.paragraph(id: "p", text: "replacement").fields)], into: .root)
    try a.receive(b.changes())
    model.perform { try $0.setNodeField(identity, path: ["host"], value: .string("original")) }
    #expect(model.error == nil && !a.isComposing)
    #expect(try a.text(at: identity.textAddressForApple("content")) == "A東京")
    #expect(try model.nodeValue(identity)["host"] == .string("original"))
    #expect(a.document.blocks.first { $0.id == "p" }?.text == "replacement")
    #expect(a.document.blocks.first { $0.id == "p" }?.fields["host"] == nil)
    try b.receive(a.changes()); #expect(a.document == b.document)
}

@MainActor @Test func writingEditorRejectsImplicitLegacyEpochAndClosedInputMutation() throws {
    let legacy = try WritingSession(documentID: "legacy", actorID: "a", epoch: "legacy", document: Document(blocks: [.paragraph(id: "p", text: "legacy")]))
    #expect(throws: EditorError.unsupportedVersion(3)) { try WritingEditorModel(session: legacy) }
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "A")])
    let input = WritingCollaborativeInput(model: model, address: TextAddress("p")); input.close()
    let accepted = try a.save(); input.update(text: "late", selection: NSRange(location: 4, length: 0), composing: false)
    #expect(try a.save() == accepted)
}
@MainActor @Test func writingRetainedNativeCallbacksRespectCurrentPermissionAndCloseLease() throws {
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "A")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view)
    let command = try #require(view.command), history = try #require(view.history), format = try #require(view.formatSelection)
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    let accepted = try a.save()
    view.isEditable = false
    #expect(!command(.enter)); history(false); format("bold")
    model.perform { try $0.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "rejected") }
    #expect(try a.save() == accepted)
    #expect(a.isComposing && coordinator.input.composing)
    // AppKit ends native marking when isEditable changes; the adapter retains
    // the uncommitted draft and remote hold independently of that OS lifecycle.
    view.isEditable = true; model.isEditable = false
    #expect(!command(.softBreak)); history(false); format("italic")
    #expect(try a.save() == accepted)
    coordinator.close()
    #expect(try a.save() == accepted && !a.isComposing)
    let draft = try #require(model.pendingDrafts.values.first)
    #expect(draft.text == "A東京" && draft.address.identity != nil)
    model.isEditable = true; view.isEditable = true
    #expect(!command(.enter)); history(false); format("bold")
    #expect(try a.save() == accepted)
    let fresh = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), live = WritingMacTextView()
    fresh.connect(live); defer { fresh.close() }
    live.insertText("X", replacementRange: NSRange(location: 1, length: 0))
    #expect(a.document.blocks[0].text == "AX")
}

@MainActor @Test func writingRetainedChecklistSetterKeepsOriginAfterMoveAndRejectsDeletedReuse() throws {
    func list(_ id: String, _ items: [JSONValue]) throws -> Block { try Block(fields: ["id": .string(id), "type": .string("list"), "style": .string("todo"), "items": .array(items)]) }
    let original: JSONValue = .object(["id": .string("i"), "content": .array([textNode("original")]), "checked": .bool(false), "host": .string("keep")])
    let (a, b, model) = try writingPair([list("left", [original]), list("right", [.object(["id": .string("other"), "content": .array([]), "checked": .bool(false)])])])
    let origin = try a.node(at: NodeAddress("left", path: ["items", "i"])), right = try b.node(at: NodeAddress("right"))
    let setter = model.checkedSetter(for: origin)
    try b.move(WritingSelection(nodes: [origin]), into: NodeCollection(owner: right, field: "items"))
    try b.insertCollectionNodes([.object(["id": .string("i"), "content": .array([textNode("replacement")]), "checked": .bool(false)])], into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "items"))
    try a.receive(b.changes()); setter(true)
    #expect(try model.nodeValue(origin)["checked"] == .bool(true))
    #expect(a.document.blocks.first { $0.id == "left" }?.fields["items"]?.array?.first?["checked"] == .bool(false))
    model.perform(on: origin) { try $0.delete(WritingSelection(nodes: [origin])) }
    let accepted = try a.save(); setter(false)
    #expect(try a.save() == accepted)
    let replacement = try a.node(at: NodeAddress("left", path: ["items", "i"]))
    let fresh = model.checkedSetter(for: replacement); fresh(true)
    #expect(try model.nodeValue(replacement)["checked"] == .bool(true))
    model.isEditable = false; let readonly = try a.save(); fresh(false)
    #expect(try a.save() == readonly)
}

@MainActor @Test func writingFailedCompositionClosePreservesRecoverableDraftAndQueuedRemoteInput() throws {
    let (a, b, model) = try writingPair([.paragraph(id: "p", text: "A")])
    let input = WritingCollaborativeInput(model: model, address: TextAddress("p"))
    input.update(text: "A東京", selection: NSRange(location: 3, length: 0), composing: true)
    input.onCommit = { throw EditorError.invalidRange }
    try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "R"); try a.receive(b.changes())
    #expect(a.document.blocks[0].text == "A")
    input.close()
    #expect(!a.isComposing && a.document.blocks[0].text == "AR")
    let draft = try #require(model.pendingDrafts[input.id])
    #expect(draft.text == "A東京" && draft.selection == NSRange(location: 3, length: 0))
    let accepted = try a.save(); input.update(text: "stale", selection: NSRange(location: 5, length: 0), composing: false)
    #expect(try a.save() == accepted)
}
@MainActor @Test func writingNativeTypingAppliesSharedMarkdownAndRespectsDisabledTypes() throws {
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.insertText("#", replacementRange: NSRange(location: 0, length: 0))
    view.insertText(" ", replacementRange: NSRange(location: 1, length: 0))
    #expect(a.document.blocks[0].type == "heading" && a.document.blocks[0].text == "" && model.error == nil)
    model.perform { try $0.undo() }
    #expect(a.document.blocks[0].type == "paragraph" && a.document.blocks[0].text == "# ")
    model.allowedBlockTypes = ["paragraph"]
    model.perform { try $0.undo() }; model.perform { try $0.undo() }
    view.insertText("- ", replacementRange: NSRange(location: 0, length: 0))
    #expect(a.document.blocks[0].type == "paragraph" && a.document.blocks[0].text == "- " && model.error == nil)
}
@MainActor @Test func writingCleanDisabledInputAllowsAnotherNativeCommandButMarkedDraftBlocksIt() throws {
    let (a, _, model) = try writingPair([.paragraph(id: "left", text: "A"), .paragraph(id: "right", text: "B")])
    let disabled = WritingMacTextInput.Coordinator(model: model, address: TextAddress("left")), editable = WritingMacTextInput.Coordinator(model: model, address: TextAddress("right"))
    let left = WritingMacTextView(), right = WritingMacTextView()
    disabled.connect(left); editable.connect(right); defer { disabled.close(); editable.close() }
    left.isEditable = false
    right.setSelectedRange(NSRange(location: 1, length: 0)); editable.input.selection = right.selectedRange()
    right.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(model.error == nil && a.document.blocks.map(\.text) == ["A", "B", ""])
    left.isEditable = true
    left.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    left.isEditable = false
    let accepted = try a.save()
    right.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
    #expect(try a.save() == accepted && model.error != nil && a.isComposing)
    disabled.close()
    #expect(model.pendingDrafts.values.contains { $0.text == "A東京" })
}

@MainActor @Test func writingNativeFormattingTogglesAndPreservesUpstreamSelectionAffinity() throws {
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "A😀B")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 1, length: 2), affinity: .upstream, stillSelecting: false)
    coordinator.input.selection = view.selectedRange(); coordinator.input.selectionAffinity = view.selectionAffinity
    let format = try #require(view.formatSelection); format("bold")
    #expect(view.selectedRange() == NSRange(location: 1, length: 2) && view.selectionAffinity == .upstream)
    #expect(a.document.blocks[0].fields["content"]?.array?.contains { $0["text"] == .string("😀") && $0["marks"] == .array([.object(["type": .string("bold")])]) } == true)
    format("bold")
    #expect(a.document.blocks[0].fields["content"]?.array?.allSatisfy { $0["marks"] == .array([]) } == true)
    #expect(view.selectedRange() == NSRange(location: 1, length: 2) && view.selectionAffinity == .upstream)
}
@MainActor @Test func writingFocusedFormattingRetainsNativeRangeAndUpstreamAffinityAfterScheduledFocusWork() async throws {
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "A😀B")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; coordinator.connect(view); window.contentView?.addSubview(view)
    defer { coordinator.close(); window.close() }
    #expect(window.makeFirstResponder(view))
    view.setSelectedRange(NSRange(location: 1, length: 2), affinity: .upstream, stillSelecting: false)
    coordinator.input.selection = view.selectedRange(); coordinator.input.selectionAffinity = view.selectionAffinity
    let format = try #require(view.formatSelection); format("bold")
    try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === view && view.selectedRange() == NSRange(location: 1, length: 2) && view.selectionAffinity == .upstream)
    #expect(a.document.blocks[0].fields["content"]?.array?.contains { $0["text"] == .string("😀") && $0["marks"] == .array([.object(["type": .string("bold")])]) } == true)
    format("bold"); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === view && view.selectedRange() == NSRange(location: 1, length: 2) && view.selectionAffinity == .upstream)
}

@MainActor @Test func writingImmediateRepeatedEnterUsesThePendingDestinationIdentityAndCaret() throws {
    let (a, _, model) = try writingPair([.paragraph(id: "p", text: "AB")])
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p")), view = WritingMacTextView()
    coordinator.connect(view); defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 1, length: 0)); coordinator.input.selection = view.selectedRange()
    view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    let destination = try #require(model.pendingCaret?.field.node)
    view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(try a.text(at: destination.textAddressForApple("content")) == "")
    let caret = try #require(model.pendingCaret), resolved = try a.resolve(caret)
    #expect(try a.text(at: resolved.address) == "B" && resolved.offset == 0)
    #expect(a.document.blocks.map(\.text) == ["A", "", "B"])
}
#endif
