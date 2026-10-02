import Foundation
import Testing
@testable import BlockEditorCore

// The same literal cut-group oracle that fails the v4 move-only witness.
// A v5 descriptor authors the complete birth chain without a suffix move.
private func spliceWitnessSession(_ actor: String, _ document: Document) throws -> WritingSession {
    try WritingSession(documentID: "splice-witness", actorID: actor, epoch: "splice-v5",
                       document: document, protocolVersion: 5)
}
private func spliceAuthoredRestore(_ change: WritingChange, baseline: Document, actor: String) throws -> WritingSession {
    let batch = WritingBatch(documentID: "splice-witness", epoch: "splice-v5", baseline: baseline,
                             changes: [change], version: 5)
    var saved = try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(batch)).object!
    saved["localHistory"] = .object(["actorID": .string(actor),
        "undo": try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode([change.id])),
        "redo": .array([])])
    return try WritingSession.restore(canonicalEncoder().encode(JSONValue.object(saved)), actorID: actor)
}
private func spliceImportedNode(_ label: String) -> JSONValue {
    .object(["id": .string(label), "type": .string("paragraph"),
        "content": .array([textNode("X", marks: [.object(["type": .string("bold")])])]),
        "consumer": .object(["id": .string("opaque-consumer"), "children": .array([.object(["id": .string("opaque-child")])])])])
}
private func explicitGroupSplice(_ actor: String, cut: Int, baseline: Document) throws -> (WritingSession, NodeID, NodeID, JSONValue) {
    let builder = try spliceWitnessSession(actor, baseline)
    let root = try builder.node(at: NodeAddress("p"))
    _ = try builder.splitParagraph(at: TextAddress("p"), range: cut..<cut, newBlockID: "paste-tail")
    let split = try #require(builder.changes().changes.first)
    guard case .edit(var operations) = split.body else { throw EditorError.invalidChange }
    let tail = NodeID.inserted(creation: ElementID(change: split.id, index: 0), path: [])
    let middlePlacement = ElementID(change: split.id, index: 1)
    let middle = NodeID.inserted(creation: middlePlacement, path: [])
    let imported = spliceImportedNode("paste-imported")
    let splitEdge = try #require(operations.compactMap { operation -> WritingEdge? in
        if case .text(.splitBoundary(_, _, let edge, _)) = operation { return edge }; return nil
    }.first)
    operations = operations.compactMap { operation in
        switch operation {
        case .structure(.insertNode): return nil
        case .text(.splitBoundary): return nil
        default: return operation
        }
    }
    let tailValue: JSONValue = .object(["id": .string("paste-tail"), "type": .string("paragraph"), "content": .array([])])
    // Roots share one allocator and form one immutable birth chain. Text pins
    // and transfers are retained verbatim from the public split command above.
    operations.insert(contentsOf: [
        .structure(.insertNode(value: imported, identity: middle, collection: .root, placement: middlePlacement, after: .initial(root))),
        .structure(.insertNode(value: tailValue, identity: tail, collection: .root, placement: ElementID(change: split.id, index: 0), after: .edit(middlePlacement)))], at: 0)
    operations.append(.text(.spliceBoundary(source: WritingField(node: root, name: "content"),
        destination: WritingField(node: tail, name: "content"), edge: splitEdge,
        before: nil, members: [middle, tail])))
    let candidate = WritingChange(id: split.id, body: .edit(operations), observed: split.observed)
    return (try spliceAuthoredRestore(candidate, baseline: baseline, actor: actor), tail, middle, imported)
}

@Test(arguments: ["a", "z"], [1, 2])
func pasteSpliceExplicitGroupKeepsConcurrentCutsInBoundaryOrder(pasteActor: String, pasteCut: Int) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let (paste, tail, middle, imported) = try explicitGroupSplice(pasteActor, cut: pasteCut, baseline: baseline)
    let peer = try spliceWitnessSession("m", baseline)
    let peerCut = pasteCut == 1 ? 2 : 1
    _ = try peer.splitParagraph(at: TextAddress("p"), range: peerCut..<peerCut, newBlockID: "peer-tail")
    #expect(paste.document.blocks.map(\.id) == ["p", "paste-imported", "paste-tail"])
    #expect(paste.changes().changes.count == 1)
    #expect(paste.document.blocks[1].fields == imported.object)
    let pasteBatch = paste.changes(), peerBatch = peer.changes()
    try paste.receive(peerBatch); try peer.receive(pasteBatch)
    try paste.receive(peerBatch); try peer.receive(pasteBatch)
    #expect(paste.document == peer.document)
    let expectedIDs = pasteCut == 1 ? ["p", "paste-imported", "paste-tail", "peer-tail"] : ["p", "peer-tail", "paste-imported", "paste-tail"]
    let expectedText = pasteCut == 1 ? ["a", "X", "b", "cd"] : ["a", "b", "X", "cd"]
    #expect(paste.document.blocks.map(\.id) == expectedIDs)
    #expect(paste.document.blocks.map(\.text) == expectedText)
    #expect(try paste.address(of: middle).blockID == "paste-imported")
    #expect(paste.document.blocks.first(where: { $0.id == "paste-imported" })?.fields == imported.object)

    // Independent author-history branch: Undo the peer cut, then restore it.
    let peerUndo = try WritingSession.restore(peer.save(), actorID: "m")
    let pasteForPeerUndo = try WritingSession.restore(paste.save(), actorID: pasteActor)
    try peerUndo.undo(); try pasteForPeerUndo.receive(peerUndo.changes())
    #expect(peerUndo.document == pasteForPeerUndo.document)
    #expect(peerUndo.document.blocks.map(\.id) == ["p", "paste-imported", "paste-tail"])
    #expect(peerUndo.document.blocks.map(\.text) == (pasteCut == 1 ? ["a", "X", "bcd"] : ["ab", "X", "cd"]))
    try peerUndo.redo(); try pasteForPeerUndo.receive(peerUndo.changes())
    #expect(peerUndo.document == pasteForPeerUndo.document)
    #expect(peerUndo.document.blocks.map(\.id) == expectedIDs)

    let caret = try peer.replaceText(at: tail.textAddress("content"), range: 0..<0, with: "東京😀")
    try paste.receive(peer.changes())
    let reopened = try WritingSession.restore(paste.save(), actorID: pasteActor)
    try reopened.undo()
    let undoText = pasteCut == 1 ? ["a東京😀b", "cd"] : ["a", "b東京😀cd"]
    #expect(reopened.document.blocks.map(\.text) == undoText)
    #expect(!reopened.canUndo && reopened.canRedo)
    #expect(try reopened.resolve(caret).offset == (pasteCut == 1 ? "a東京😀" : "b東京😀").utf16.count)
    try peer.receive(reopened.changes()); #expect(peer.document == reopened.document)
    try reopened.redo(); try peer.receive(reopened.changes()); try peer.receive(reopened.changes())
    #expect(peer.document == reopened.document)
    #expect(reopened.document.blocks.map(\.id) == expectedIDs)
    #expect(reopened.document.blocks.first(where: { $0.id == "paste-imported" })?.fields == imported.object)
    let fresh = try spliceWitnessSession("reader", baseline)
    try fresh.receive(reopened.changes()); #expect(fresh.document == reopened.document)
}

@Test func structuralPasteAtFieldStartMustRetainCompleteFirstNodeAndAvoidIncidentalBlankPrefix() throws {
    let source = try Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNode("abcd")]), "consumer": .object(["id": .string("source-owner")])])
    let baseline = try Document(blocks: [source]), actor = "a", id = ChangeID(counter: 1, actor: actor)
    let placement = ElementID(change: id, index: 0), node = NodeID.inserted(creation: placement, path: [])
    let imported = spliceImportedNode("paste-imported")
    let change = WritingChange(id: id, body: .edit([.structure(.insertNode(value: imported, identity: node,
        collection: .root, placement: placement, after: nil))]), observed: [])
    let paste = try spliceAuthoredRestore(change, baseline: baseline, actor: actor)
    #expect(paste.document.blocks.map(\.id) == ["paste-imported", "p"])
    #expect(paste.document.blocks[0].fields == imported.object)
    #expect(paste.document.blocks[1] == source)
    #expect(paste.changes().changes.count == 1)
    let peer = try spliceWitnessSession("b", baseline)
    try peer.replaceText(at: TextAddress("p"), range: 0..<0, with: "東京😀")
    try peer.receive(paste.changes()); try paste.receive(peer.changes())
    #expect(paste.document == peer.document)
    let reopened = try WritingSession.restore(paste.save(), actorID: actor)
    try reopened.undo(); #expect(reopened.document.blocks.map(\.id) == ["p"])
    #expect(reopened.document.blocks[0].text == "東京😀abcd")
    #expect(reopened.document.blocks[0].fields["consumer"] == source.fields["consumer"])
    try reopened.redo(); #expect(reopened.document.blocks[0].fields == imported.object)
}
