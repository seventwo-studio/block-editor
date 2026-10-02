import Foundation
import Testing
@testable import BlockEditorCore

private func pasteBlocksSession(_ actor: String, _ baseline: Document, version: Int = 5) throws -> WritingSession {
    try WritingSession(documentID: "actual-paste", actorID: actor, epoch: "five", document: baseline, protocolVersion: version)
}
private var wholeClipboard: WritingClipboard {
    WritingClipboard(parts: [.node(value: .object(["id": .string("input"), "type": .string("paragraph"),
        "content": .array([textNode("東京😀", marks: [.object(["type": .string("bold")])]),
            .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("consumer-task"), "label": .string("Task")])]),
        "consumer": .object(["id": .string("opaque-owner")])]), kind: "block")])
}
@Test(arguments: ["a", "z"], [1, 2])
func pasteBlocksPublicCommandRetainsWholeMetadataAndConcurrentCutGroups(actor: String, cut: Int) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let paste = try pasteBlocksSession(actor, baseline), peer = try pasteBlocksSession("m", baseline)
    let caret = try paste.pasteBlocks(wholeClipboard, replacing: paste.selectedText(at: TextAddress("p"), range: cut..<cut))
    let importedID = "paste-\(actor)-1-1", tailID = "paste-\(actor)-1-2"
    #expect(paste.changes().changes.count == 1 && paste.canUndo)
    let peerCut = cut == 1 ? 2 : 1
    _ = try peer.splitParagraph(at: TextAddress("p"), range: peerCut..<peerCut, newBlockID: "peer-tail")
    let own = paste.changes(), remote = peer.changes()
    try paste.receive(remote); try peer.receive(own); try paste.receive(remote); try peer.receive(own)
    #expect(paste.document == peer.document)
    let expected = cut == 1 ? ["p", importedID, tailID, "peer-tail"] : ["p", "peer-tail", importedID, tailID]
    #expect(paste.document.blocks.map(\.id) == expected)
    #expect(paste.document.blocks.map(\.text) == (cut == 1 ? ["a", "東京😀Task", "b", "cd"] : ["a", "b", "東京😀Task", "cd"]))
    let imported = try #require(paste.document.blocks.first { $0.id == importedID })
    #expect(imported.fields["consumer"] == .object(["id": .string("opaque-owner")]))
    #expect(imported.fields["content"] == wholeClipboard.parts.compactMap { if case .node(let value, _) = $0 { return value["content"] }; return nil }.first)
    #expect(try paste.resolve(caret).offset == 0)
    let reopened = try WritingSession.restore(paste.save(), actorID: actor)
    try reopened.undo(); try peer.receive(reopened.changes())
    #expect(reopened.document == peer.document && reopened.document.blocks.map(\.text) == (cut == 1 ? ["ab", "cd"] : ["a", "bcd"]))
    try reopened.redo(); try peer.receive(reopened.changes())
    #expect(reopened.document == peer.document && reopened.document.blocks.map(\.id) == expected)
}
@Test func pasteBlocksAtZeroPreservesOriginalSuffixIdentityAndOpaqueBoundaryMetadata() throws {
    let original = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("abcd")]),
        "consumer": .object(["id": .string("original-owner")])])
    let session = try pasteBlocksSession("a", Document(blocks: [original]))
    let caret = try session.pasteBlocks(wholeClipboard, replacing: session.selectedText(at: TextAddress("p"), range: 0..<2))
    #expect(session.document.blocks.map(\.id) == ["paste-a-1-1", "p"])
    #expect(session.document.blocks.map(\.text) == ["東京😀Task", "cd"])
    #expect(session.document.blocks[1].fields["consumer"] == original.fields["consumer"])
    #expect(try session.resolve(caret).address.identity == NodeID.baseline(blockID: "p", path: []))
    #expect(session.changes().changes.count == 1)
    try session.undo(); #expect(session.document.blocks == [original])
    try session.redo(); #expect(session.document.blocks.map(\.text) == ["東京😀Task", "cd"])
}
@Test func pasteBlocksRejectsUnsupportedPolicyCompositionAndOldEpochWithoutAcceptedMutation() throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let current = try pasteBlocksSession("a", baseline), legacy = try pasteBlocksSession("a", baseline, version: 4)
    let currentRange = try current.selectedText(at: TextAddress("p"), range: 1..<2)
    let accepted = try current.save(), receipt = current.syncState
    #expect(throws: EditorError.self) { try current.pasteBlocks(wholeClipboard, replacing: currentRange, policy: WritingPastePolicy(allowedMarkTypes: [])) }
    #expect(throws: EditorError.self) { try current.pasteBlocks(.plainText("inline"), replacing: currentRange) }
    current.isComposing = true
    #expect(throws: WritingSessionError.compositionActive) { try current.pasteBlocks(wholeClipboard, replacing: currentRange) }
    current.isComposing = false
    #expect(try current.save() == accepted && current.syncState == receipt && !current.canUndo)
    let old = try legacy.save()
    #expect(throws: EditorError.unsupportedVersion(4)) { try legacy.pasteBlocks(wholeClipboard, replacing: legacy.selectedText(at: TextAddress("p"), range: 1..<1)) }
    #expect(try legacy.save() == old && !legacy.canUndo)
}
@Test(arguments: [false, true])
func pasteSpliceRejectsDuplicateOwnershipEvenWhenAuthorUndoRetainsMalformedEdit(inactive: Bool) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let builder = try pasteBlocksSession("a", baseline), receiver = try pasteBlocksSession("b", baseline)
    _ = try builder.pasteBlocks(wholeClipboard, replacing: builder.selectedText(at: TextAddress("p"), range: 1..<1))
    let original = try #require(builder.changes().changes.first)
    guard case .edit(var operations) = original.body else { throw EditorError.invalidChange }
    let descriptor = try #require(operations.first { if case .text(.spliceBoundary) = $0 { return true }; return false })
    operations.append(descriptor)
    var changes = [WritingChange(id: original.id, body: .edit(operations), observed: original.observed)]
    if inactive { changes.append(WritingChange(id: ChangeID(counter: 2, actor: "a"), body: .setActive(target: original.id, active: false), observed: [original.id])) }
    let before = try receiver.save(), receipt = receiver.syncState
    #expect(throws: EditorError.invalidChange) { try receiver.receive(WritingBatch(documentID: receiver.documentID, epoch: receiver.epoch, baseline: baseline, changes: changes, version: 5)) }
    #expect(try receiver.save() == before && receiver.syncState == receipt && receiver.mergeRecovery == nil)
}
@Test func pasteBlocksSequentialSameBoundaryKeepsCapturedBeforeImportedGroup() throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let session = try pasteBlocksSession("a", baseline)
    _ = try session.pasteBlocks(wholeClipboard, replacing: session.selectedText(at: TextAddress("p"), range: 1..<1))
    _ = try session.pasteBlocks(wholeClipboard, replacing: session.selectedText(at: TextAddress("p"), range: 1..<1))
    #expect(session.document.blocks.map(\.id) == ["p", "paste-a-2-1", "paste-a-2-2", "paste-a-1-1", "paste-a-1-2"])
    #expect(session.document.blocks.map(\.text) == ["a", "東京😀Task", "", "東京😀Task", "bcd"])
    try session.undo(); #expect(session.document.blocks.map(\.id) == ["p", "paste-a-1-1", "paste-a-1-2"])
    try session.redo(); #expect(session.document.blocks.map(\.id) == ["p", "paste-a-2-1", "paste-a-2-2", "paste-a-1-1", "paste-a-1-2"])
    let reader = try pasteBlocksSession("reader", baseline)
    try reader.receive(session.changes()); #expect(reader.document == session.document)
}
@Test(arguments: [false, true])
func pasteSpliceRejectsUnobservedSameEditOuterNeighborWhenActiveOrUndone(inactive: Bool) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let builder = try pasteBlocksSession("a", baseline), receiver = try pasteBlocksSession("b", baseline)
    _ = try builder.pasteBlocks(wholeClipboard, replacing: builder.selectedText(at: TextAddress("p"), range: 1..<1))
    let authored = try #require(builder.changes().changes.first)
    guard case .edit(let original) = authored.body else { throw EditorError.invalidChange }
    let creation = ElementID(change: authored.id, index: 2), neighbor = NodeID.inserted(creation: creation, path: [])
    var operations: [WritingOperation] = [.structure(.insertNode(value: .object(["id": .string("unobserved"), "type": .string("paragraph"), "content": .array([])]),
        identity: neighbor, collection: .root, placement: creation, after: nil))]
    operations += original.map { operation in
        if case .text(.spliceBoundary(let source, let destination, let edge, _, let members)) = operation {
            return .text(.spliceBoundary(source: source, destination: destination, edge: edge, before: neighbor, members: members))
        }
        return operation
    }
    var changes = [WritingChange(id: authored.id, body: .edit(operations), observed: authored.observed)]
    if inactive { changes.append(WritingChange(id: ChangeID(counter: 2, actor: "a"), body: .setActive(target: authored.id, active: false), observed: [authored.id])) }
    let accepted = try receiver.save(), receipt = receiver.syncState
    #expect(throws: EditorError.invalidChange) { try receiver.receive(WritingBatch(documentID: receiver.documentID, epoch: receiver.epoch, baseline: baseline, changes: changes, version: 5)) }
    #expect(try receiver.save() == accepted && receiver.syncState == receipt && receiver.mergeRecovery == nil)
}
