#if os(macOS)
import AppKit
import BlockEditorCore
import Testing
@testable import BlockEditorApple

/// Production render callbacks and real AppKit input components. These tests
/// do not assert installed menu, accessibility or physical device acceptance.
@MainActor private func renderedPair(_ version: Int) throws -> (WritingSession, WritingSession, WritingEditorModel) {
    let item: JSONValue = .object(["id": .string("i"), "checked": .bool(false), "content": .array([textNode("AB😀", marks: [.object(["type": .string("italic")])])]), "consumer": .object(["id": .string("opaque"), "unknown": .bool(true)])])
    let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let target = try Block(fields: ["id": .string("target"), "type": .string("list"), "style": .string("todo"), "items": .array([])])
    let document = try Document(blocks: [list, target, .paragraph(id: "q", text: "peer")])
    let a = try WritingSession(documentID: "rendered-lease", actorID: "a", epoch: "v\(version)", document: document, protocolVersion: version)
    let b = try WritingSession(documentID: "rendered-lease", actorID: "b", epoch: "v\(version)", document: document, protocolVersion: version)
    return (a, b, try WritingEditorModel(session: a))
}

@MainActor @Test(arguments: [4, 5, 6])
func writingRenderedCallbacksCannotReauthorizeAfterMoveAndReturn(version: Int) throws {
    let (a, b, model) = try renderedPair(version)
    let origin = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let retired = WritingRenderedOrigin(model: model, identity: origin)
    let checked = retired.checkedSetter()
    let delete = { retired.perform { try $0.delete(WritingSelection(nodes: [origin])) } }
    let target = try b.node(at: NodeAddress("target"))
    try b.move(WritingSelection(nodes: [origin]), into: NodeCollection(owner: target, field: "items"))
    try a.receive(b.changes())
    #expect(!retired.isActive)
    // No SwiftUI run-loop turn occurs between moving away and restoring the
    // exact same public path. The old token is nevertheless permanently dead.
    try b.undo(); try a.receive(b.changes())
    let accepted = try a.save(), receipts = a.syncState
    checked(true); #expect(!delete()); #expect(!retired.move(down: true))
    #expect(try a.save() == accepted && a.syncState == receipts)
    let fresh = WritingRenderedOrigin(model: model, identity: origin)
    fresh.checkedSetter()(true)
    #expect(try model.nodeValue(origin)["checked"] == .bool(true))
    #expect(try model.nodeValue(origin)["consumer"] == .object(["id": .string("opaque"), "unknown": .bool(true)]))
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(try reopened.document == WritingSession.restore(accepted, actorID: "a").document)
    try reopened.redo(); #expect(reopened.document == a.document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingRenderedDisposedAndReadOnlyControlsPreserveFullHistory(version: Int) throws {
    let (a, _, model) = try renderedPair(version)
    let origin = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let disposed = WritingRenderedOrigin(model: model, identity: origin), callback = disposed.checkedSetter()
    disposed.close()
    let accepted = try a.save(), receipts = a.syncState
    callback(true); #expect(!disposed.perform { try $0.delete(WritingSelection(nodes: [origin])) })
    let replacement = WritingRenderedOrigin(model: model, identity: origin)
    model.isEditable = false; replacement.checkedSetter()(true)
    #expect(try a.save() == accepted && a.syncState == receipts)
    model.isEditable = true
    #expect(replacement.perform { try $0.delete(WritingSelection(nodes: [origin])) })
    #expect(try model.nodeValue(a.node(at: NodeAddress("list")))["items"] == .array([]))
    try a.undo(); #expect(try a.document == WritingSession.restore(accepted, actorID: "a").document)
    callback(true); #expect(try a.document == WritingSession.restore(accepted, actorID: "a").document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingImpossibleMovementDoesNotFinalizeMarkedDraftOrDrainPeer(version: Int) throws {
    let (a, b, model) = try renderedPair(version)
    let origin = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let lease = WritingRenderedOrigin(model: model, identity: origin)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: origin.textAddressForApple("content"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    let nativeCommit = coordinator.input.onCommit; var finalized = 0
    coordinator.input.onCommit = { finalized += 1; try nativeCommit?() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    try b.replaceText(at: TextAddress("q"), range: 4..<4, with: "R"); try a.receive(b.changes())
    let accepted = try a.save(), receipts = a.syncState, draft = view.string
    #expect(!lease.canMove(down: false) && !lease.canMove(down: true) && !lease.canIndent && !lease.canOutdent)
    #expect(!lease.move(down: false) && !lease.move(down: true) && !lease.indent() && !lease.outdent())
    #expect(finalized == 0 && view.hasMarkedText() && a.isComposing && view.string == draft)
    #expect(try a.save() == accepted && a.syncState == receipts && a.document.blocks[2].text == "peer")
    // A valid check action then finalizes once and drains the exact held peer.
    lease.checkedSetter()(true)
    #expect(finalized == 1 && !view.hasMarkedText() && !a.isComposing)
    #expect(a.document.blocks[2].text == "peerR")
    #expect(try model.nodeValue(origin)["checked"] == .bool(true))
    #expect(model.pendingDrafts.isEmpty)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[2].text == "peerR")
    #expect(reopened.document.blocks[0].fields["items"]?.array?.first?["checked"] == .bool(false))
}

@MainActor @Test(arguments: [4, 5, 6])
func writingRenderedMovementRechecksBoundsAfterHeldPeerDrain(version: Int) throws {
    let (a, b, model) = try renderedPair(version)
    let q = try a.node(at: NodeAddress("q")), lease = WritingRenderedOrigin(model: model, identity: q)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    try b.move(WritingSelection(nodes: [q]), into: .root)
    try a.receive(b.changes())
    #expect(lease.canMove(down: false))
    #expect(!lease.move(down: false))
    #expect(a.document.blocks.first?.id == "q" && a.document.blocks.first?.text == "peer東京")
    #expect(!a.isComposing && !view.hasMarkedText())
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks.first?.id == "q" && reopened.document.blocks.first?.text == "peer")
}

@MainActor @Test(arguments: [4, 5, 6])
func writingRenderedListConvertRetainsBothOwnerAndTargetLease(version: Int) throws {
    let (a, b, model) = try renderedPair(version)
    let list = try a.node(at: NodeAddress("list")), item = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let ownerLease = WritingRenderedOrigin(model: model, identity: list)
    let targetLease = WritingRenderedOrigin(model: model, identity: item)
    let target = item.textAddressForApple("content")
    let convert = { ownerLease.convert(at: target, requiring: targetLease, to: "list") }
    try b.move(WritingSelection(nodes: [item]), into: NodeCollection(owner: b.node(at: NodeAddress("target")), field: "items"))
    try a.receive(b.changes())
    #expect(ownerLease.canAuthor && !targetLease.canAuthor)
    let movedSave = try a.save(); #expect(!convert()); #expect(try a.save() == movedSave)
    try b.undo(); try a.receive(b.changes())
    #expect(ownerLease.canAuthor && !targetLease.canAuthor)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    let commit = coordinator.input.onCommit; var finalized = 0
    coordinator.input.onCommit = { finalized += 1; try commit?() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    try b.replaceText(at: TextAddress("q"), range: 4..<4, with: "R"); try a.receive(b.changes())
    let accepted = try a.save(), receipt = a.syncState, draft = view.string
    #expect(!convert() && finalized == 0 && view.hasMarkedText() && a.isComposing && view.string == draft)
    #expect(try a.save() == accepted && a.syncState == receipt)
    let fresh = WritingRenderedOrigin(model: model, identity: item)
    #expect(ownerLease.convert(at: target, requiring: fresh, to: "list"))
    #expect(finalized == 1 && !a.isComposing && !view.hasMarkedText())
    #expect(a.document.blocks[0].fields["style"] == .string("unordered"))
    #expect(try model.nodeValue(item)["consumer"] == .object(["id": .string("opaque"), "unknown": .bool(true)]))
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[0].fields["style"] == .string("todo"))
    #expect(reopened.document.blocks[2].text.contains("東京") && reopened.document.blocks[2].text.contains("R"))
    try reopened.redo(); #expect(reopened.document == a.document)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingRenderedListConvertRejectsTargetReparentingDuringDrain(version: Int) throws {
    let (a, b, model) = try renderedPair(version)
    let list = try a.node(at: NodeAddress("list")), item = try a.node(at: NodeAddress("list", path: ["items", "i"]))
    let ownerLease = WritingRenderedOrigin(model: model, identity: list)
    let targetLease = WritingRenderedOrigin(model: model, identity: item)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("q"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
    try b.move(WritingSelection(nodes: [item]), into: NodeCollection(owner: b.node(at: NodeAddress("target")), field: "items"))
    try a.receive(b.changes())
    #expect(ownerLease.canAuthor && targetLease.canAuthor)
    #expect(!ownerLease.convert(at: item.textAddressForApple("content"), requiring: targetLease, to: "list"))
    #expect(!a.isComposing && !view.hasMarkedText())
    #expect(a.document.blocks[0].fields["style"] == .string("todo") && a.document.blocks[1].fields["style"] == .string("todo"))
    #expect(try a.address(of: item) == NodeAddress("target", path: ["items", "i"]))
    #expect(a.document.blocks[2].text == "peer東京")
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks[2].text == "peer")
    #expect(try reopened.address(of: item) == NodeAddress("target", path: ["items", "i"]))
    try reopened.redo(); #expect(reopened.document == a.document)
}
#endif
