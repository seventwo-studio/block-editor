import Foundation
import Testing
@testable import BlockEditorCore

private func preservationSession(_ baseline: Document, actor: String) throws -> WritingSession {
    try WritingSession(documentID: "preservation-splice", actorID: actor, epoch: "five", document: baseline, protocolVersion: 5)
}
private func preservationClipboard() -> WritingClipboard {
    WritingClipboard(parts: [.node(value: .object(["id": .string("copied"), "type": .string("paragraph"),
        "content": .array([textNode("X", marks: [.object(["type": .string("bold")])])]),
        "consumer": .object(["id": .string("opaque-copy")])]), kind: "block")])
}

@Test(arguments: ["a", "z"])
func v5SpliceOnExposedPeerParagraphPreservesRoleAcrossWrapperUndoAndReopen(wrapperActor: String) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "AB")])
    let wrapper = try preservationSession(baseline, actor: wrapperActor), peer = try preservationSession(baseline, actor: "b")
    _ = try wrapper.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try peer.receive(wrapper.changes())
    _ = try peer.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 1..<1, newItemID: "peer")
    let origin = try peer.node(at: NodeAddress("p", path: ["items", "peer"]))
    try wrapper.undo(); let retired = wrapper.changes()
    try wrapper.receive(peer.changes()); try peer.receive(retired)
    #expect(wrapper.document == peer.document && peer.document.blocks.map(\.id) == ["p", "peer"])
    #expect(try peer.node(at: NodeAddress("peer")) == origin)
    let original = peer.document
    let range = try peer.selectedText(at: origin.textAddress("content"), range: 1..<1)
    let caret = try peer.pasteBlocks(preservationClipboard(), replacing: range)
    #expect(peer.document.blocks.count == 4 && peer.document.blocks.map(\.text) == ["A", "B", "X", ""])
    #expect(try peer.node(at: NodeAddress("peer")) == origin)
    #expect(try peer.resolve(caret).offset == 0)
    try wrapper.receive(peer.changes()); try wrapper.receive(peer.changes())
    #expect(wrapper.document == peer.document)
    let pasted = peer.document, reopened = try WritingSession.restore(peer.save(), actorID: "b")
    try reopened.undo(); #expect(reopened.document == original)
    #expect(try reopened.node(at: NodeAddress("peer")) == origin)
    try wrapper.receive(reopened.changes()); #expect(wrapper.document == original)
    try reopened.redo(); try wrapper.receive(reopened.changes())
    #expect(reopened.document == pasted && wrapper.document == pasted)
    // Restoring the wrapper may validly demand schema reconciliation once a
    // descendant has authored a paragraph split. It must not corrupt either state.
    let accepted = try wrapper.save(), receipt = wrapper.syncState
    do {
        try wrapper.redo()
        #expect(try wrapper.text(at: origin.textAddress("content")) == "B")
        #expect(try wrapper.resolve(caret).offset == 0)
    }
    catch WritingSessionError.recoveryRequired {
        #expect(try wrapper.save() == accepted)
        #expect(wrapper.syncState == receipt)
        let pending = try #require(try wrapper.exportRecovery())
        let resumed = try WritingSession.restore(accepted, actorID: wrapperActor)
        #expect(throws: WritingSessionError.self) { try resumed.restoreRecovery(pending) }
        #expect(try resumed.save() == accepted)
    }
}

@Test
func v5SplicePreservesForeignMovedImportedContainerAndUnseenChildThroughAuthorUndoAndReopen() throws {
    let source = try Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNode("ABCD")]), "consumer": .object(["id": .string("original")])])
    let host = try Block(fields: ["id": .string("host"), "type": .string("toggle"), "summary": .array([textNode("H")]), "children": .array([])])
    let baseline = try Document(blocks: [source, host]), a = try preservationSession(baseline, actor: "a"), b = try preservationSession(baseline, actor: "b")
    let localChild: JSONValue = .object([
        "id": .string("local"), "type": .string("paragraph"),
        "content": .array([
            textNode("L", marks: [.object(["type": .string("bold")])]),
            .object(["type": .string("entity-ref"), "entityType": .string("note"),
                "entityId": .string("local-reference"), "label": .string("Ref")])
        ])
    ])
    let clipboard = WritingClipboard(parts: [.node(value: .object(["id": .string("container"), "type": .string("toggle"),
        "summary": .array([textNode("X")]), "children": .array([localChild]),
        "consumer": .object(["id": .string("opaque-container")])]), kind: "block")])
    _ = try a.pasteBlocks(clipboard, replacing: a.selectedText(at: TextAddress("p"), range: 2..<2))
    let roots = try a.collectionNodes(in: .root), imported = try #require(roots.dropFirst().first), tail = try #require(roots.dropFirst(2).first)
    let localOrigin = try #require(try a.collectionNodes(in: NodeCollection(owner: imported, field: "children")).first)
    try b.receive(a.changes())
    let hostOrigin = try b.node(at: NodeAddress("host")), hostChildren = NodeCollection(owner: hostOrigin, field: "children")
    _ = try b.move(WritingSelection(nodes: [imported]), into: hostChildren)
    let remoteValue: JSONValue = .object(["id": .string("remote"), "type": .string("paragraph"),
        "content": .array([textNode("Y", marks: [.object(["type": .string("italic")])]),
            .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("remote-reference"), "label": .string("RemoteRef")])]),
        "consumer": .object(["id": .string("remote-opaque")])])
    let remote = try #require(try b.insertCollectionNodes([remoteValue], into: NodeCollection(owner: imported, field: "children")).nodes.first)
    let remoteCaret = try b.replaceText(at: imported.textAddress("summary"), range: 1..<1, with: "R")
    try a.receive(b.changes()); try a.receive(b.changes()); #expect(a.document == b.document)
    let moved = a.document, reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks.map(\.id) == ["p", "host"])
    #expect(reopened.document.blocks[0] == source)
    #expect(try reopened.collectionNodes(in: hostChildren) == [imported])
    #expect(try reopened.collectionNodes(in: NodeCollection(owner: imported, field: "children")) == [remote])
    #expect(try reopened.text(at: imported.textAddress("summary")) == "R")
    #expect(try reopened.resolve(remoteCaret).offset == 1)
    #expect(try reopened.copy(WritingSelection(nodes: [remote])).nodes == [remoteValue])
    let importedValue = try #require(try reopened.copy(WritingSelection(nodes: [imported])).nodes.first)
    #expect(importedValue["consumer"] == .object(["id": .string("opaque-container")]))
    try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    let afterUndo = try WritingSession.restore(reopened.save(), actorID: "a")
    try afterUndo.redo(); try b.receive(afterUndo.changes()); #expect(afterUndo.document == moved && b.document == moved)
    #expect(try afterUndo.collectionNodes(in: hostChildren) == [imported])
    let restoredChildren = try afterUndo.collectionNodes(in: NodeCollection(owner: imported, field: "children"))
    #expect(Set(restoredChildren) == Set([localOrigin, remote]) && restoredChildren.count == 2)
    #expect(try afterUndo.address(of: tail).path.isEmpty)
    #expect(try afterUndo.text(at: imported.textAddress("summary")) == "XR")
}
