#if os(macOS)
import AppKit
import BlockEditorCore
import Testing
@testable import BlockEditorApple

@MainActor private func listInsertionPair(_ version: Int) throws -> (WritingSession, WritingSession, WritingEditorModel) {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task-original"), "label": .string("TASK"), "consumer": .string("reference-opaque")])
    let item: JSONValue = .object(["id": .string("i"), "checked": .bool(true), "content": .array([textNode("AB😀", marks: [.object(["type": .string("italic")])]), reference]), "consumer": .object(["id": .string("preserve"), "nested": .array([.bool(true)])])])
    let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([item]), "consumer": .string("list-opaque")])
    let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    let document = try Document(blocks: [list, toggle, .paragraph(id: "q", text: "peer")])
    let a = try WritingSession(documentID: "list-add", actorID: "a", epoch: "v\(version)", document: document, protocolVersion: version)
    let b = try WritingSession(documentID: "list-add", actorID: "b", epoch: "v\(version)", document: document, protocolVersion: version)
    return (a, b, try WritingEditorModel(session: a))
}

/// Hidden native components prove callback ordering and focus routing; installed
/// menus, system IME, VoiceOver and physical devices require separate acceptance.
@MainActor @Test(arguments: [4, 5, 6])
func writingListAddItemFinalizesAndDrainsBeforeFreshCaretAndUndo(version: Int) async throws {
    let (a, b, model) = try listInsertionPair(version)
    let owner = try a.node(at: NodeAddress("list")), item = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let original = try model.nodeValue(item), lease = WritingRenderedOrigin(model: model, identity: owner)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    let source = WritingMacTextView(), coordinator = WritingMacTextInput.Coordinator(model: model, address: item.textAddressForApple("content"))
    coordinator.connect(source); window.contentView?.addSubview(source); defer { coordinator.close() }
    #expect(window.makeFirstResponder(source))
    source.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    let peerItem: JSONValue = .object(["id": .string("peer-item"), "checked": .bool(true), "content": .array([textNode("café😀"), original["content"]!.array![1]]), "consumer": .string("peer-opaque")])
    try b.insertCollectionNodes([peerItem], into: NodeCollection(owner: owner, field: "items"), after: item)
    try a.receive(b.changes())
    #expect(a.isComposing && a.document.blocks[0].fields["items"]?.array?.count == 1)
    #expect(lease.addListItem(nested: false))
    #expect(!a.isComposing && !source.hasMarkedText())
    let items = try #require(a.document.blocks[0].fields["items"]?.array)
    #expect(items.count == 3 && items[1] == peerItem)
    #expect(items[0]["consumer"] == original["consumer"] && items[0]["checked"] == .bool(true))
    #expect(items[0]["content"]?.array?.contains(original["content"]!.array![1]) == true)
    #expect(plainText(items[0]["content"]?.array ?? []) == "A東京B😀TASK")
    #expect(items[2]["content"] == .array([]) && items[2]["checked"] == .bool(false))
    #expect(a.document.blocks[0].fields["consumer"] == .string("list-opaque"))
    #expect(a.changes().changes.filter { $0.id.actor == "a" }.count == 2)
    let caret = try #require(model.pendingCaret), fresh = caret.field.node
    #expect(try a.resolve(caret).offset == 0 && fresh != item)
    #expect(try a.address(of: fresh) == NodeAddress("list", path: ["items", items[2]["id"]!.string!]))
    let destination = WritingMacTextView(), current = WritingMacTextInput.Coordinator(model: model, address: fresh.textAddressForApple("content"))
    current.connect(destination); window.contentView?.addSubview(destination); defer { current.close() }
    model.focus.restoreAfterLayout(); try await Task.sleep(for: .milliseconds(30))
    #expect(window.firstResponder === destination && destination.selectedRange() == NSRange(location: 0, length: 0))
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[0].fields["items"]?.array == Array(items.prefix(2)))
    try reopened.redo(); #expect(reopened.document == a.document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingListAddNestedItemExplicitlyCreatesAbsentCollectionAndUndoesExactly(version: Int) throws {
    let (a, _, model) = try listInsertionPair(version)
    let item = try a.node(at: NodeAddress("list", path: ["items", "i"])), lease = WritingRenderedOrigin(model: model, identity: item)
    let accepted = try a.save(), original = try model.nodeValue(item)
    #expect(original["children"] == nil && lease.canAddListItem(nested: true))
    #expect(try a.save() == accepted)
    #expect(lease.addListItem(nested: true))
    let children = try #require(model.nodeValue(item)["children"]?.array)
    #expect(children.count == 1 && children[0]["content"] == .array([]) && children[0]["checked"] == .bool(false))
    #expect(try model.nodeValue(item)["consumer"] == original["consumer"] && model.nodeValue(item)["content"] == original["content"])
    let caret = try #require(model.pendingCaret)
    #expect(try a.resolve(caret).offset == 0)
    #expect(try a.address(of: caret.field.node).path == ["items", "i", "children", children[0]["id"]!.string!])
    #expect(a.changes().changes.count == 1)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(try reopened.document == WritingSession.restore(accepted, actorID: "a").document)
    #expect(reopened.document.blocks[0].fields["items"]?.array?.first?["children"] == nil)
    try reopened.redo(); #expect(reopened.document == a.document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingListInsertionPreflightKeepsMarkedDraftAndHeldPeersOnDisabledOrRetiredActions(version: Int) throws {
    let (a, b, model) = try listInsertionPair(version)
    let list = try a.node(at: NodeAddress("list")), lease = WritingRenderedOrigin(model: model, identity: list)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    let nativeCommit = coordinator.input.onCommit; var finalizers = 0
    coordinator.input.onCommit = { finalizers += 1; try nativeCommit?() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    try b.replaceText(at: TextAddress("q"), range: 4..<4, with: "R"); try a.receive(b.changes())
    let accepted = try a.save(), receipt = a.syncState, deferred = try a.exportDeferredChanges(), draft = view.string
    model.allowedBlockTypes = ["paragraph"]; #expect(!lease.canAddListItem(nested: false) && !lease.addListItem(nested: false))
    model.allowedBlockTypes = nil; model.isEditable = false; #expect(!lease.addListItem(nested: false))
    model.isEditable = true; lease.close(); #expect(!lease.addListItem(nested: false))
    #expect(finalizers == 0 && a.isComposing && view.hasMarkedText() && view.string == draft)
    #expect(try a.save() == accepted && a.syncState == receipt && a.exportDeferredChanges() == deferred)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingListInsertionRejectsReparentingAfterCompositionWithoutMutatingCollections(version: Int) throws {
    let (a, b, model) = try listInsertionPair(version)
    let list = try a.node(at: NodeAddress("list")), lease = WritingRenderedOrigin(model: model, identity: list)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    let toggle = try b.node(at: NodeAddress("toggle"))
    try b.move(WritingSelection(nodes: [list]), into: NodeCollection(owner: toggle, field: "children")); try a.receive(b.changes())
    #expect(lease.canAddListItem(nested: false))
    #expect(!lease.addListItem(nested: false))
    #expect(!a.isComposing && !view.hasMarkedText() && !lease.isActive)
    #expect(try model.nodeValue(list)["items"]?.array?.count == 1)
    #expect(a.document.blocks.first(where: { $0.id == "q" })?.text == "peer東京")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(try reopened.address(of: list) == NodeAddress("toggle", path: ["children", "list"]))
    #expect(reopened.document.blocks.first(where: { $0.id == "q" })?.text == "peer")
    try reopened.redo(); #expect(reopened.document == a.document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingListInsertionRetainsFailedCompositionAndUsesCurrentDrainedStyle(version: Int) throws {
    let (a, b, model) = try listInsertionPair(version)
    let item = try a.node(at: NodeAddress("list", path: ["items", "i"])), lease = WritingRenderedOrigin(model: model, identity: item)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    try b.convertBlock(at: item.textAddressForApple("content"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered")); try a.receive(b.changes())
    let accepted = try a.save(), receipt = a.syncState, deferred = try a.exportDeferredChanges(), draft = view.string
    let nativeCommit = coordinator.input.onCommit
    coordinator.input.onCommit = { throw WritingSessionError.compositionActive }
    #expect(!lease.addListItem(nested: true))
    #expect(try a.save() == accepted && a.syncState == receipt && a.exportDeferredChanges() == deferred)
    #expect(a.isComposing && view.hasMarkedText() && view.string == draft && model.error != nil)
    coordinator.input.onCommit = nativeCommit
    #expect(lease.addListItem(nested: true))
    let children = try #require(model.nodeValue(item)["children"]?.array)
    #expect(children.count == 1 && children[0]["checked"] == nil)
    #expect(a.document.blocks[0].fields["style"] == .string("ordered") && model.error == nil)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[0].fields["style"] == .string("ordered"))
    #expect(reopened.document.blocks[0].fields["items"]?.array?.first?["children"] == nil)
    try reopened.redo(); #expect(reopened.document == a.document)
}
#endif
