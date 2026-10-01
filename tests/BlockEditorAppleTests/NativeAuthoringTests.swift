#if canImport(SwiftUI)
import BlockEditorCore
import Foundation
import Testing
@testable import BlockEditorApple

@MainActor @Test func nativeInsertionsRespectPolicyAndPreserveExistingContent() throws {
    let unknown = try Block(fields: ["id": .string("host"), "type": .string("host-rich"), "private": .string("preserve")])
    let session = try EditorSession(documentID: "insert", actorID: "a", document: Document(blocks: [unknown]), collaborationVersion: 2)
    let model = try EditorModel(session: session)
    model.allowedBlockTypes = ["heading"]
    #expect(session.allowedBlockTypes == model.allowedBlockTypes)
    #expect(NativeBlockInsertion.allCases.filter { $0.isAllowed(in: session) } == [.paragraph, .heading])
    let before = try session.save()
    #expect(throws: EditorError.restrictedBlock("list")) { try session.insert(NativeBlockInsertion.checklist.block(id: "restricted")) }
    #expect(try session.save() == before)
    session.allowedBlockTypes = nil
    for insertion in NativeBlockInsertion.allCases {
        try session.insert(insertion.block(), after: session.document.blocks.last?.id)
    }
    #expect(try session.document.blocks.first == unknown)
    #expect(try session.document.blocks.count == NativeBlockInsertion.allCases.count + 1)
    try session.undo()
    #expect(try session.document.blocks.count == NativeBlockInsertion.allCases.count)
    #expect(try session.document.blocks.first == unknown)
}

@MainActor @Test func nativeRootOrderingAndUndoUseSharedCommands() throws {
    for version in [1, 2] {
        let document = try Document(blocks: [.paragraph(id: "a"), .paragraph(id: "b"), .paragraph(id: "c")])
        let session = try EditorSession(documentID: "order", actorID: "a", document: document, collaborationVersion: version)
        let target = try NativeNodeTarget(session: session, address: NodeAddress("b"))
        try target.move(in: session, down: true)
        #expect(try session.document.blocks.map(\.id) == ["a", "c", "b"])
        try session.undo()
        #expect(try session.document == document)
        try target.move(in: session, down: false)
        #expect(try session.document.blocks.map(\.id) == ["b", "a", "c"])
        #expect(!target.canMove(in: session, down: false))
    }
}

@MainActor @Test func legacyNestedActionsCannotDeleteTheirContainingRoot() throws {
    let list = try NativeBlockInsertion.checklist.block(id: "list")
    let item = try #require(list.fields["items"]?.array?.first?.selfID)
    let session = try EditorSession(documentID: "legacy", actorID: "a", document: Document(blocks: [list]))
    #expect(throws: EditorError.unsupportedVersion(2)) {
        try NativeNodeTarget(session: session, address: NodeAddress("list", path: ["items", item]))
    }
    #expect(try session.document.blocks == [list])
    #expect(!session.canUndo)
}

@MainActor @Test func nativeFormattingShortcutTogglesMarksAndIgnoresCompositionAndDisposal() throws {
    let session = try EditorSession(documentID: "shortcut", actorID: "a", document: Document(blocks: [.paragraph(id: "p", text: "Hello")]), collaborationVersion: 2)
    let model = try EditorModel(session: session)
    let input = CollaborativeInput(model: model, address: TextAddress("p"))
    input.selection = NSRange(location: 0, length: 5)
    input.formatSelection(type: "bold")
    #expect(try session.document.blocks[0].fields["content"]?.array?.first?["marks"]?.array?.first?["type"] == .string("bold"))
    input.formatSelection(type: "bold")
    #expect(try session.document.blocks[0].fields["content"]?.array?.first?["marks"]?.array?.isEmpty == true)
    input.beginComposition()
    let before = try session.save()
    input.formatSelection(type: "italic")
    #expect(try session.save() == before)
    input.close()
    input.formatSelection(type: "italic")
    #expect(try session.save() == before)
    #expect(model.error == nil)
}

@MainActor @Test func nativeActionFollowsMovedIdentityWhenOldLabelIsReused() throws {
    let child = try Block.paragraph(id: "p", text: "original")
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([]), "children": .array([.object(child.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "actions", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "actions", actorID: "b", document: document, collaborationVersion: 2)
    let live = NodeAddress("left", path: ["children", "p"])
    let target = try NativeNodeTarget(session: a, address: live)
    let original = try b.node(at: live)
    try b.moveNode(original, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    let replacement = try b.insertNode(.object(Block.paragraph(id: "p", text: "replacement").fields),
        into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "children"))
    try a.receive(b.changes())
    try target.delete(in: a)
    #expect(try a.text(at: a.textAddress(of: replacement)) == "replacement")
    try a.undo()
    #expect(try a.text(at: a.textAddress(of: original)) == "original")
    #expect(try a.address(of: original) == NodeAddress("right", path: ["children", "p"]))
}

@MainActor @Test func nativeFormattingMapsQueuedRemoteInsertionBeforeCommand() throws {
    let mention: JSONValue = .object(["type": .string("mention"), "entityId": .string("mira"), "entityType": .string("user"), "label": .string("Mira")])
    let p = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("Hello "), mention])])
    let document = try Document(blocks: [p])
    let a = try EditorSession(documentID: "format", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "format", actorID: "b", document: document, collaborationVersion: 2)
    let model = try EditorModel(session: a)
    let input = CollaborativeInput(model: model, address: TextAddress("p"))
    defer { input.close() }
    input.beginComposition()
    input.onCommit = { try input.commit(text: "Hello Mira", selection: NSRange(location: 0, length: 5)) }
    let selection = try NativeFormattingSelection(session: a, address: input.address, range: NSRange(location: 0, length: 5))
    try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "R")
    try a.receive(b.changes())
    model.perform { try selection.apply(in: $0, type: "code", remove: false) }
    #expect(model.error == nil)
    let nodes = try a.document.blocks[0].fields["content"]?.array ?? []
    #expect(nodes.contains(mention))
    #expect(nodes.contains { $0["text"] == .string("Hello") && ($0["marks"]?.array ?? []).contains(.object(["type": .string("code")])) })
    try a.undo()
    #expect(try a.text(at: TextAddress("p")) == "RHello Mira")
    #expect(try a.document.blocks[0].fields["content"]?.array?.contains(mention) == true)
}

@MainActor @Test func checklistCommandFollowsOriginAfterCompositionReleasesMoveAndLabelReuse() throws {
    let item: JSONValue = .object(["id": .string("item"), "content": .array([textNode("Original")]), "checked": .bool(false)])
    let left = try Block(fields: ["id": .string("left"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("list"), "style": .string("todo"), "items": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "checklist-identity", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "checklist-identity", actorID: "b", document: document, collaborationVersion: 2)
    let live = NodeAddress("left", path: ["items", "item"])
    let original = try a.node(at: live)
    let model = try EditorModel(session: a)
    let input = CollaborativeInput(model: model, address: TextAddress("left", path: ["items", "item", "content"]))
    defer { input.close() }
    input.beginComposition()
    input.onCommit = { try input.commit(text: "Original", selection: NSRange(location: 0, length: 0)) }
    try b.moveNode(original, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "items"))
    let replacement = try b.insertNode(item, into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "items"))
    try a.receive(b.changes())
    let target = try NativeFieldTarget(session: a, address: live)
    model.perform { try target.set(in: $0, field: "checked", value: .bool(true)) }
    #expect(model.error == nil)
    #expect(try a.document.blocks[1].fields["items"]?.array?.first?["checked"] == .bool(true))
    #expect(try a.document.blocks[0].fields["items"]?.array?.first?["checked"] == .bool(false))
    #expect(try a.node(at: live) == replacement)
    try a.undo()
    #expect(try a.document.blocks[1].fields["items"]?.array?.first?["checked"] == .bool(false))
    #expect(try a.address(of: original) == NodeAddress("right", path: ["items", "item"]))
}
#endif
