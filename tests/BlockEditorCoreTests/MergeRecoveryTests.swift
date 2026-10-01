import BlockEditorCore
import Foundation
import Testing

private func recoverySession(_ actor: String, _ baseline: Document) throws -> EditorSession {
    try EditorSession(documentID: "recovery", actorID: actor, document: baseline, collaborationVersion: 2)
}
private func recoveryToggle(_ id: String, children: [JSONValue] = []) throws -> Block {
    try Block(fields: ["id": .string(id), "type": .string("toggle"),
        "summary": .array([textNode(id)]), "children": .array(children)])
}
private func recoveryParagraph(_ text: String) throws -> JSONValue {
    .object(try Block.paragraph(id: "same", text: text).fields)
}
private func pending(_ session: EditorSession, _ batch: ChangeBatch) throws -> MergeRecovery {
    do { try session.receive(batch); Issue.record("Conflicting union was accepted") }
    catch EditorError.mergeRecoveryRequired(let proposal) { return proposal }
    return try #require(session.mergeRecovery)
}
private func collision() throws -> (EditorSession, EditorSession, NodeID, NodeID, NodeCollection) {
    let baseline = try Document(blocks: [recoveryToggle("parent"), recoveryToggle("destination")])
    let a = try recoverySession("a", baseline), b = try recoverySession("b", baseline)
    let source = NodeCollection(owner: try a.node(at: NodeAddress("parent")), field: "children")
    let target = NodeCollection(owner: try a.node(at: NodeAddress("destination")), field: "children")
    let first = try a.insertNode(recoveryParagraph("café 😀 Alice"), into: source)
    let second = try b.insertNode(recoveryParagraph("世界 Bob"), into: source)
    return (a, b, first, second, target)
}

@Test func recoveryRepairPreservesBothAuthorsAndSurvivesRestartAndRemoteUndo() throws {
    let (a, b, first, second, target) = try collision()
    let ownSave = try a.save(), ownReceipts = a.syncState
    let proposal = try pending(a, b.changes())
    #expect(try proposal == pending(b, a.changes()))
    #expect(proposal.reason == .identityConflict)
    #expect(try a.save() == ownSave)
    #expect(a.syncState == ownReceipts)
    #expect(throws: EditorError.mergeRecoveryRequired(proposal)) { try a.undo() }
    // Accepted history and transport recovery are stored independently, with no network.
    let exported = try JSONEncoder().encode(proposal)
    let restarted = try EditorSession.restore(ownSave, actorID: "a")
    #expect(restarted.mergeRecovery == nil)
    let recovered = try JSONDecoder().decode(MergeRecovery.self, from: exported)
    #expect(try pending(restarted, recovered.batch) == proposal)
    try restarted.repairMerge([.move(identity: second, collection: target)])
    #expect(restarted.mergeRecovery == nil)
    try b.receive(restarted.changes()); try restarted.receive(b.changes())
    #expect(try restarted.document == b.document)
    #expect(try restarted.text(at: restarted.textAddress(of: first)) == "café 😀 Alice")
    #expect(try restarted.text(at: restarted.textAddress(of: second)) == "世界 Bob")
    #expect(try restarted.address(of: first) == NodeAddress("parent", path: ["children", "same"]))
    #expect(try restarted.address(of: second) == NodeAddress("destination", path: ["children", "same"]))
    #expect(restarted.changes(since: b.syncState).changes.isEmpty)
    let saved = try EditorSession.restore(restarted.save(), actorID: "a")
    // Undoing the repair would recreate a collision; it retains a recoverable union.
    #expect(throws: EditorError.self) { try saved.undo() }
    #expect(saved.mergeRecovery?.reason == .identityConflict)
    #expect(try saved.document == restarted.document)
    // The original author can independently undo their insertion without losing Alice.
    try b.undo(); try restarted.receive(b.changes())
    #expect(try restarted.text(at: restarted.textAddress(of: first)) == "café 😀 Alice")
    // Alice's independent move retains the container, while Bob's seed text is undone.
    #expect(try restarted.address(of: second) == NodeAddress("destination", path: ["children", "same"]))
    #expect(try restarted.text(at: restarted.textAddress(of: second)).isEmpty)
}

@Test func rejectedRepairsAndMalformedPayloadsLeaveThePendingUnionAndReceiptsIntact() throws {
    let (a, b, _, second, target) = try collision()
    let proposal = try pending(a, b.changes()), saved = try a.save(), receipt = a.syncState
    let wrong = NodeCollection(owner: .baseline(blockID: "missing", path: []), field: "children")
    #expect(throws: EditorError.self) { try a.repairMerge([.move(identity: second, collection: wrong)]) }
    a.allowedBlockTypes = ["paragraph"]
    #expect(throws: EditorError.restrictedBlock("toggle")) {
        try a.repairMerge([.wrap(identity: second, container: recoveryToggle("wrapper"), field: "children")])
    }
    #expect(throws: EditorError.unsupportedVersion(1)) {
        try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
            changes: [], version: 1))
    }
    let id = ChangeID(counter: 99, actor: "bad")
    #expect(throws: EditorError.invalidChange) {
        try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
            changes: [Change(id: id, body: .edit([.deleteBlock(blockID: "parent")]))], version: 2))
    }
    let placement = ElementID(change: id, index: 0), missing = ElementID(change: id, index: 1)
    #expect(throws: EditorError.invalidChange) {
        try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
            changes: [Change(id: id, body: .edit([.moveNode(identity: second, collection: target,
                placement: placement, after: .edit(missing))]))], version: 2))
    }
    let root = NodeID.inserted(creation: placement, path: [])
    let absent = NodeID.inserted(creation: placement, path: ["children", "absent"])
    let prefix = Mutation.insertNode(value: .object(try recoveryToggle("new", children: [recoveryParagraph("Original")]).fields),
        identity: root, collection: .root, placement: placement, after: nil)
    let impossible: [Mutation] = [
        .insertNode(value: try recoveryParagraph("Invisible"), identity: .inserted(creation: missing, path: []),
            collection: .root, placement: missing, after: .initial(root)),
        .insertNode(value: try recoveryParagraph("Invisible"), identity: .inserted(creation: missing, path: []),
            collection: NodeCollection(owner: absent, field: "children"), placement: missing, after: nil),
        .moveNode(identity: second, collection: NodeCollection(owner: absent, field: "children"), placement: missing, after: nil),
        .insertText(address: TextAddress("@bad/99/0", path: ["children", "absent", "content"], identity: absent),
            atoms: [TextAtom(id: missing, after: nil, node: textNode("X"))]),
    ]
    var malformedPrepared = false
    a.onWillReceive = { malformedPrepared = true }
    for suffix in impossible {
        #expect(throws: EditorError.invalidChange) {
            try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
                changes: [Change(id: id, body: .edit([prefix, suffix]))], version: 2))
        }
        #expect(a.mergeRecovery == proposal)
        #expect(try a.save() == saved)
        #expect(a.syncState == receipt)
        #expect(!malformedPrepared)
    }
    if case .inserted(let creation, _) = second {
        let absentPrior = NodeID.inserted(creation: creation, path: ["children", "missing"])
        #expect(throws: EditorError.invalidChange) {
            try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
                changes: [Change(id: id, body: .edit([.deleteNodes(identities: [absentPrior])]))], version: 2))
        }
        #expect(!malformedPrepared)
    }
    let summary = try a.textAddress(of: a.node(at: NodeAddress("parent")), field: "summary")
    #expect(throws: EditorError.invalidChange) {
        try a.receive(ChangeBatch(documentID: a.documentID, baseline: a.baseline,
            changes: [Change(id: id, body: .edit([.insertText(address: summary, atoms: [
                TextAtom(id: placement, after: ElementID(change: ChangeID(counter: 0, actor: ""), index: 99), node: textNode("X")),
            ])]))], version: 2))
    }
    #expect(!malformedPrepared)
    #expect(a.mergeRecovery == proposal)
    #expect(try a.save() == saved)
    #expect(a.syncState == receipt)
    var prepared = false, reentryRejected = false
    a.onWillReceive = {
        prepared = true
        #expect((try? a.save()) == saved)
        do { try a.repairMerge([.move(identity: second, collection: target)]) }
        catch { reentryRejected = (error as? EditorError) == .invalidChange }
    }
    try a.repairMerge([.move(identity: second, collection: target)])
    #expect(a.mergeRecovery == nil)
    #expect(prepared && reentryRejected)
}

@Test func recoveryAccumulatesReorderedAdditionalEditsWithoutAcknowledgingThem() throws {
    let (a, b, _, second, target) = try collision()
    let baseline = a.baseline, c = try recoverySession("c", baseline), d = try recoverySession("d", baseline)
    let source = NodeCollection(owner: try c.node(at: NodeAddress("parent")), field: "children")
    _ = try c.insertNode(recoveryParagraph("third"), into: source)
    let batches = [a.changes(), b.changes(), c.changes()]
    let observer = try recoverySession("observer", baseline)
    try observer.receive(batches[0])
    for batch in batches.dropFirst().reversed() { _ = try pending(observer, batch); _ = try pending(observer, batch) }
    try d.receive(batches[0])
    for batch in batches.dropFirst() { _ = try pending(d, batch) }
    #expect(observer.mergeRecovery == d.mergeRecovery)
    #expect(observer.syncState.received == Set(batches[0].changes.map(\.id)))
    let third = try c.node(at: NodeAddress("parent", path: ["children", "same"]))
    // Resolve both collisions in one atomic author transaction, with host-chosen containers.
    try observer.repairMerge([.move(identity: second, collection: target),
        .wrap(identity: third, container: recoveryToggle("third-author"), field: "children")])
    try d.receive(observer.changes())
    #expect(try d.document == observer.document)
    #expect(try observer.text(at: observer.textAddress(of: third)) == "third")
    #expect(try observer.document.blocks.map(\.id).contains("third-author"))
}

@Test func simultaneousRepairsConvergeAndUndoKeepsTheOtherRepair() throws {
    let (a, b, _, second, target) = try collision()
    _ = try pending(a, b.changes()); _ = try pending(b, a.changes())
    try a.repairMerge([.move(identity: second, collection: target)])
    try b.repairMerge([.wrap(identity: second, container: recoveryToggle("bob-wrapper"), field: "children")])
    let aChanges = a.changes(), bChanges = b.changes()
    try a.receive(bChanges); try b.receive(aChanges); try a.receive(bChanges)
    #expect(try a.document == b.document)
    #expect(try a.address(of: second) == NodeAddress("bob-wrapper", path: ["children", "same"]))
    try a.undo(); try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(try a.address(of: second) == NodeAddress("bob-wrapper", path: ["children", "same"]))
    #expect(try a.text(at: a.textAddress(of: second)) == "世界 Bob")
}

@Test func requiredContentRepairAdmitsFailedAuthorUndoWithoutDroppingRemoteMetadata() throws {
    let baseline = try Document(blocks: []), a = try recoverySession("a", baseline), b = try recoverySession("b", baseline)
    let math = try a.insertNode(.object(["id": .string("math"), "type": .string("math"), "expression": .string("x+y"),
        "extension": .object(["remote": .bool(false)])]), into: .root)
    try b.receive(a.changes())
    try b.setNodeField(math, path: ["extension", "remote"], value: .bool(true))
    try a.receive(b.changes())
    let before = try a.save(), receipt = a.syncState
    #expect(throws: EditorError.self) { try a.undo() }
    let proposal = try #require(a.mergeRecovery)
    #expect(proposal.reason == .schemaConstraint)
    #expect(try a.save() == before)
    #expect(a.syncState == receipt)
    let restored = try EditorSession.restore(before, actorID: "a")
    _ = try pending(restored, proposal.batch)
    try restored.repairMerge([.text(identity: math, field: "expression", text: "restored x+y")])
    try b.receive(restored.changes())
    #expect(try b.document == restored.document)
    #expect(try restored.document.blocks.first?.fields["extension"] == .object(["remote": .bool(true)]))
    #expect(try restored.document.blocks.first?.fields["expression"] == .string("restored x+y"))
    // Reconciled undo state does not retry the original insertion as its latest action.
    #expect(throws: EditorError.self) { try restored.undo() }
    #expect(restored.mergeRecovery?.reason == .schemaConstraint)
}

@Test func recoveryTextEditsRetainUnicodeMarksAndAtomicReferences() throws {
    let (a, b, first, second, target) = try collision()
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("ref"),
        "entityType": .string("note"), "label": .string("Reference")])
    try a.setInline(at: a.textAddress(of: first), nodes: [textNode("café 😀", marks: [.object(["type": .string("bold")])]), reference])
    _ = try pending(a, b.changes())
    let proposal = a.mergeRecovery, before = try a.save()
    #expect(throws: EditorError.invalidRange) {
        try a.repairMerge([.move(identity: second, collection: target),
            .text(identity: first, field: "content", text: "café 😀RefeXrence")])
    }
    #expect(a.mergeRecovery == proposal)
    #expect(try a.save() == before)
    try a.repairMerge([.move(identity: second, collection: target),
        .text(identity: first, field: "content", text: "café 😀!Reference")])
    try b.receive(a.changes())
    #expect(try a.document == b.document)
    let content = try a.document.blocks.first { $0.id == "parent" }?.fields["children"]?.array?.first?["content"]?.array
    #expect(content?.contains(reference) == true)
    #expect(content?.first?["marks"]?.array == [.object(["type": .string("bold")])])
    #expect(try a.text(at: a.textAddress(of: first)) == "café 😀!Reference")
}

@Test(arguments: [17, 20, 24]) func depthLimitUnionCanBeRepairedWithoutChangingExistingIDsOrContent(levels: Int) throws {
    func chain(_ prefix: String) throws -> Block {
        var value: JSONValue = .object(try Block.paragraph(id: "leaf", text: prefix).fields)
        for index in (0..<levels).reversed() { value = .object(try recoveryToggle("\(prefix)-\(index)", children: [value]).fields) }
        return try Block(fields: value.object!)
    }
    let baseline = try Document(blocks: [chain("A"), chain("B"), chain("C")])
    let a = try recoverySession("a", baseline), b = try recoverySession("b", baseline)
    let A = try a.node(at: NodeAddress("A-0")), B = try a.node(at: NodeAddress("B-0"))
    func deepest(_ prefix: String) -> NodeAddress { NodeAddress("\(prefix)-0", path: (1..<levels).flatMap { ["children", "\(prefix)-\($0)"] }) }
    try a.moveNode(A, into: NodeCollection(owner: a.node(at: deepest("B")), field: "children"))
    try b.moveNode(B, into: NodeCollection(owner: b.node(at: deepest("C")), field: "children"))
    let proposal = try pending(a, b.changes())
    #expect(proposal.reason == .schemaConstraint)
    #expect(try proposal == pending(b, a.changes()))
    try a.repairMerge([.move(identity: A, collection: .root)])
    try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(try a.address(of: A) == NodeAddress("A-0"))
    for prefix in ["A", "B", "C"] { #expect(String(decoding: try a.document.json(), as: UTF8.self).contains("\"text\":\"\(prefix)\"")) }
}

@Test func oversizedDocumentAndCapacityErrorsKeepEveryUnappliedChangeRecoverable() throws {
    let baseline = try Document(blocks: []), a = try recoverySession("a", baseline), b = try recoverySession("b", baseline), c = try recoverySession("c", baseline)
    func opaque(_ id: String, size: Int) -> JSONValue {
        .object(["id": .string(id), "type": .string("extension-block"), "blob": .string(String(repeating: "x", count: size))])
    }
    _ = try a.insertNode(opaque("a", size: 31_500_000), into: .root)
    _ = try b.insertNode(opaque("b", size: 31_500_000), into: .root)
    _ = try c.insertNode(opaque("c", size: 2_000_000), into: .root)
    let saved = try a.save(), receipt = a.syncState
    let proposal = try pending(a, b.changes())
    #expect(proposal.reason == .schemaConstraint)
    #expect(proposal.batch.changes.count == 2)
    let additional = c.changes()
    #expect(throws: EditorError.recoveryCapacityExceeded) { try a.receive(additional) }
    #expect(a.mergeRecovery == proposal)
    #expect(a.syncState == receipt)
    #expect(try a.save() == saved)
    // The host archives accepted state, pending union and the rejected input before
    // choosing an explicit partition/cutover; there is no acknowledgement or truncation.
    let archived = try JSONEncoder().encode([proposal.batch, additional])
    let retained = try JSONDecoder().decode([ChangeBatch].self, from: archived)
    #expect(retained.flatMap(\.changes).count == 3)
    let restored = try EditorSession.restore(saved, actorID: "a")
    #expect(try pending(restored, retained[0]) == proposal)
    #expect(throws: EditorError.recoveryCapacityExceeded) { try restored.receive(retained[1]) }
    #expect(restored.syncState == receipt)
}

@Test func rootCountLimitUnionRepairsIntoAnExistingContainerWithoutDroppingBlocks() throws {
    var blocks = try (0..<9998).map { try Block.paragraph(id: "p-\($0)") }
    blocks.append(try recoveryToggle("bucket"))
    let baseline = try Document(blocks: blocks), a = try recoverySession("a", baseline), b = try recoverySession("b", baseline)
    let first = try a.insertNode(.object(try Block.paragraph(id: "first", text: "Alice").fields), into: .root)
    let second = try b.insertNode(.object(try Block.paragraph(id: "second", text: "Bob").fields), into: .root)
    #expect(try a.document.blocks.count == 10_000)
    _ = try pending(a, b.changes())
    let bucket = NodeID.baseline(blockID: "bucket", path: [])
    try a.repairMerge([.move(identity: second, collection: NodeCollection(owner: bucket, field: "children"))])
    try b.receive(a.changes())
    #expect(try a.document == b.document)
    #expect(try a.document.blocks.count == 10_000)
    #expect(try a.text(at: a.textAddress(of: first)) == "Alice")
    #expect(try a.text(at: a.textAddress(of: second)) == "Bob")
}
