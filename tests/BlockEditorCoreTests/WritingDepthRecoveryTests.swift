import BlockEditorCore
import Foundation
import Testing

private let depthReference: JSONValue = .object([
    "type": .string("entity-ref"), "entityType": .string("task"),
    "entityId": .string("external-task"), "label": .string("Task"),
    "consumer": .object(["id": .string("opaque-reference")])
])

private func depthLeaf(_ prefix: String, peerText: Bool = false) -> JSONValue {
    .object([
        "id": .string("\(prefix)-leaf"), "type": .string("paragraph"),
        "content": .array([textNode((peerText ? "R" : "") + "café 東京😀", marks: [.object(["type": .string("bold")])]), depthReference]),
        // Six JSON edges from the block to this scalar. Opaque payload counts
        // toward the public document limit without becoming a schema child.
        "consumer": .object(["children": .array([.object([
            "opaque": .object(["value": .object(["text": .string("keep"), "id": .string("metadata-only")])])
        ])])])
    ])
}

private func depthChain(_ prefix: String, levels: Int, peerText: Bool = false, nested: JSONValue? = nil) -> JSONValue {
    var value = depthLeaf(prefix, peerText: peerText)
    for index in (0..<levels).reversed() {
        var children = [value]
        if index == levels - 1, let nested { children.insert(nested, at: 0) }
        value = .object([
            "id": .string("\(prefix)-\(index)"), "type": .string("toggle"),
            "summary": .array([textNode("\(prefix) 東京😀")]), "children": .array(children),
            "host": .object(["id": .string("opaque-\(prefix)-\(index)")])
        ])
    }
    return value
}

private func depthValueDepth(_ value: JSONValue) -> Int {
    var maximum = 0, pending = [(value, 0)]
    while let (value, depth) = pending.popLast() {
        maximum = max(maximum, depth)
        if let fields = value.object { pending.append(contentsOf: fields.values.map { ($0, depth + 1) }) }
        else if let values = value.array { pending.append(contentsOf: values.map { ($0, depth + 1) }) }
    }
    return maximum
}

private func depthBlocks(_ values: [JSONValue]) throws -> [Block] {
    try values.map { try Block(fields: #require($0.object)) }
}
private func depthDeepest(_ prefix: String, levels: Int) -> NodeAddress {
    NodeAddress("\(prefix)-0", path: (1..<levels).flatMap { ["children", "\(prefix)-\($0)"] })
}
private func depthLeafAddress(_ prefix: String, levels: Int) -> NodeAddress {
    let parent = depthDeepest(prefix, levels: levels)
    return NodeAddress(parent.blockID, path: parent.path + ["children", "\(prefix)-leaf"])
}
private func depthPending(_ session: WritingSession, _ batch: WritingBatch) throws -> WritingRecovery {
    do { try session.receive(batch); Issue.record("Over-depth union unexpectedly accepted") }
    catch WritingSessionError.recoveryRequired(let proposal) { return proposal }
    return try #require(session.mergeRecovery)
}

@Test(arguments: [4, 5], [("a", 15), ("a", 16), ("z", 15), ("z", 16)])
func writingDepthBoundaryKeepsOriginsAndPeerAtomsThroughExplicitRecovery(version: Int, scenario: (String, Int)) throws {
    let (actor, cLevels) = scenario
    let sibling = try Block(fields: ["id": .string("keep"), "type": .string("paragraph"),
        "content": .array([depthReference]), "consumer": .object(["id": .string("keep-opaque")])])
    let baseline = try Document(blocks: depthBlocks([
        depthChain("A", levels: 16), depthChain("B", levels: 16), depthChain("C", levels: cLevels)
    ]) + [sibling])
    let a = try WritingSession(documentID: "depth-\(version)-\(actor)-\(cLevels)", actorID: actor,
        epoch: "depth-limit-\(version)", document: baseline, protocolVersion: version)
    let b = try WritingSession(documentID: a.documentID, actorID: "m", epoch: a.epoch,
        document: baseline, protocolVersion: version)
    let A = try a.node(at: NodeAddress("A-0")), B = try b.node(at: NodeAddress("B-0"))
    let leaf = try b.node(at: depthLeafAddress("A", levels: 16))
    let collectionB = NodeCollection(owner: try a.node(at: depthDeepest("B", levels: 16)), field: "children")
    let collectionC = NodeCollection(owner: try b.node(at: depthDeepest("C", levels: cLevels)), field: "children")
    _ = try a.move(WritingSelection(nodes: [A]), into: collectionB)
    _ = try b.move(WritingSelection(nodes: [B]), into: collectionC)
    let peerCaret = try b.replaceText(at: b.textAddress(of: leaf), range: 0..<0, with: "R")
    let union = depthChain("C", levels: cLevels, nested: depthChain("B", levels: 16,
        nested: depthChain("A", levels: 16, peerText: true)))
    // This literal tree measures the public generic JSON depth, independently
    // of the engine's schema/placement projection. Each toggle adds two edges.
    #expect(depthValueDepth(union) == (cLevels == 15 ? 100 : 102))
    let originalMove = ChangeID(counter: 1, actor: actor)
    if cLevels == 15 {
        let expected = try Document(blocks: depthBlocks([union]) + [sibling])
        try a.receive(b.changes()); try b.receive(a.changes())
        try b.receive(a.changes()); try a.receive(b.changes())
        #expect(a.document == expected); #expect(b.document == expected)
        #expect(try a.node(at: a.address(of: A)) == A)
        #expect(try a.node(at: a.address(of: B)) == B)
        #expect(try a.resolve(peerCaret).offset == 1)
        let reopened = try WritingSession.restore(a.save(), actorID: actor)
        try reopened.undo()
        let rollback = try Document(blocks: depthBlocks([
            depthChain("A", levels: 16, peerText: true),
            depthChain("C", levels: cLevels, nested: depthChain("B", levels: 16))
        ]) + [sibling])
        #expect(reopened.document == rollback)
        try b.receive(reopened.changes()); #expect(b.document == rollback)
        try reopened.redo(); try b.receive(reopened.changes())
        #expect(reopened.document == expected); #expect(b.document == expected)
        return
    }
    #expect(throws: EditorError.invalidDocument("Document nesting exceeds 100")) {
        _ = try Document(blocks: depthBlocks([union]) + [sibling])
    }
    let savedA = try a.save(), savedB = try b.save(), receiptA = a.syncState, receiptB = b.syncState
    let pendingA = try depthPending(a, b.changes()), pendingB = try depthPending(b, a.changes())
    #expect(pendingA == pendingB); #expect(pendingA.reason == .schemaConstraint)
    #expect(pendingA.batch.changes.count == 3)
    #expect(try a.save() == savedA); #expect(try b.save() == savedB)
    #expect(a.syncState == receiptA); #expect(b.syncState == receiptB)
    #expect(try depthPending(a, b.changes()) == pendingA)
    let exported = try #require(try a.exportRecovery())
    let restored = try WritingSession.restore(savedA, actorID: actor)
    do { try restored.restoreRecovery(exported); Issue.record("Restored invalid union accepted") }
    catch WritingSessionError.recoveryRequired(let proposal) { #expect(proposal == pendingA) }
    #expect(try restored.save() == savedA); #expect(restored.syncState == receiptA)
    // Only this author's move is disabled. Peer placements and original rich
    // atoms stay in the union, rather than being removed to fit the limit.
    try restored.repairUndo(originalMove)
    let repaired = try Document(blocks: depthBlocks([
        depthChain("A", levels: 16, peerText: true),
        depthChain("C", levels: cLevels, nested: depthChain("B", levels: 16))
    ]) + [sibling])
    #expect(restored.document == repaired); #expect(restored.mergeRecovery == nil)
    #expect(try restored.node(at: NodeAddress("A-0")) == A)
    #expect(try restored.node(at: restored.address(of: B)) == B)
    #expect(try restored.node(at: restored.address(of: leaf)) == leaf)
    #expect(try restored.resolve(peerCaret).offset == 1)
    let batch = restored.changes(), reversed = WritingBatch(documentID: batch.documentID, epoch: batch.epoch,
        baseline: batch.baseline, changes: Array(batch.changes.reversed()), version: version)
    try b.receive(reversed); try b.receive(batch); try b.receive(reversed)
    #expect(b.document == repaired); #expect(b.mergeRecovery == nil)
    let accepted = try restored.save(), receipt = restored.syncState
    #expect(receipt.received.count == 4)
    // A redo that would exceed the real depth limit must remain a separate
    // proposal. Restart and explicit repair preserve all five original records.
    do { try restored.redo(); Issue.record("Over-depth redo accepted") }
    catch WritingSessionError.recoveryRequired(let proposal) { #expect(proposal.batch.changes.count == 5) }
    #expect(try restored.save() == accepted); #expect(restored.syncState == receipt)
    let undoPending = try #require(try restored.exportRecovery())
    let reopened = try WritingSession.restore(accepted, actorID: actor)
    do { try reopened.restoreRecovery(undoPending); Issue.record("Over-depth redo accepted after restart") }
    catch WritingSessionError.recoveryRequired { }
    try reopened.repairUndo(originalMove)
    #expect(reopened.document == repaired); #expect(reopened.syncState.received.count == 6)
    try b.receive(reopened.changes()); try b.receive(reopened.changes())
    #expect(b.document == repaired); #expect(try b.resolve(peerCaret).offset == 1)
}
