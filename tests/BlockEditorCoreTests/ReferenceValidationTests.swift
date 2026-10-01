import BlockEditorCore
import Foundation
import Testing

@Test(arguments: [1, 2])
func reservedSeedReferencesRejectAtomically(version: Int) throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "P😀")])
    let changeID = ChangeID(counter: 2, actor: "remote")
    let address = TextAddress("p", identity: version == 2 ? .baseline(blockID: "p", path: []) : nil)
    let next = ElementID(change: changeID, index: 0)
    let absent = ElementID(change: ChangeID(counter: 0, actor: ""), index: 99)
    let forged = ElementID(change: ChangeID(counter: 0, actor: "forged"), index: 0)
    let emptyActor = ElementID(change: ChangeID(counter: 1, actor: ""), index: 0)
    let lost = try Block.paragraph(id: "lost", text: "Must not disappear")
    var invalid: [Mutation] = [
        .insertText(address: address, atoms: [TextAtom(id: next, after: absent, node: textNodeForReferenceTest("X"))]),
        .insertText(address: address, atoms: [TextAtom(id: next, after: forged, node: textNodeForReferenceTest("X"))]),
        .insertText(address: address, atoms: [TextAtom(id: next, after: emptyActor, node: textNodeForReferenceTest("X"))]),
        .deleteText(address: address, ids: [absent]),
        .formatText(address: address, ids: [absent], markType: "bold", mark: .object(["type": .string("bold")])),
    ]
    if version == 1 {
        invalid.append(.insertBlock(block: lost, placement: next, after: absent))
    } else {
        invalid.append(.insertNode(value: .object(lost.fields),
            identity: .inserted(creation: next, path: []), collection: .root, placement: next,
            after: .edit(ElementID(change: ChangeID(counter: 0, actor: ""), index: 0))))
    }
    for mutation in invalid {
        let session = try EditorSession(documentID: "seed-references", actorID: "local", document: document, collaborationVersion: version)
        let saved = try session.save(), receipts = session.syncState
        var prepared = false
        session.onWillReceive = { prepared = true }
        #expect(throws: EditorError.invalidChange) {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: document,
                changes: [Change(id: changeID, body: .edit([mutation]))], version: version))
        }
        #expect(try session.save() == saved)
        #expect(session.syncState == receipts)
        #expect(try session.document == document)
        #expect(session.mergeRecovery == nil)
        #expect(!prepared)
    }
}

@Test(arguments: [1, 2]) func knownUndoTargetsMustBeEdits(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "P")])
    let source = try EditorSession(documentID: "undo-kind", actorID: "remote", document: baseline, collaborationVersion: version)
    try source.setText(at: TextAddress("p"), to: "Changed")
    try source.undo()
    let session = try EditorSession(documentID: source.documentID, actorID: "local", document: baseline, collaborationVersion: version)
    try session.receive(source.changes())
    let saved = try session.save(), receipts = session.syncState
    let undo = try #require(source.changes().changes.last)
    #expect(throws: EditorError.invalidChange) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline,
            changes: [Change(id: ChangeID(counter: 3, actor: "remote"), body: .setActive(target: undo.id, active: true))], version: version))
    }
    #expect(try session.save() == saved)
    #expect(session.syncState == receipts)
    let reversed = try EditorSession(documentID: source.documentID, actorID: "reversed", document: baseline, collaborationVersion: version)
    let reversedSave = try reversed.save()
    #expect(throws: EditorError.invalidChange) {
        try reversed.receive(ChangeBatch(documentID: reversed.documentID, baseline: baseline, changes: [
            Change(id: ChangeID(counter: 3, actor: "remote"), body: .setActive(target: undo.id, active: true)),
        ] + source.changes().changes.reversed(), version: version))
    }
    #expect(try reversed.save() == reversedSave)
    #expect(reversed.syncState.received.isEmpty)
}

private func textNodeForReferenceTest(_ value: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(value), "marks": .array([])])
}

@Test(arguments: [false, true])
func legacySeedNamespaceFollowsTheTextActuallyInitialized(initialized: Bool) throws {
    let baseline = try Document(blocks: [])
    let session = try EditorSession(documentID: "legacy-seed-replacement", actorID: "local", document: baseline)
    let first = ChangeID(counter: 1, actor: "remote"), replacement = ChangeID(counter: 2, actor: "remote")
    let address = TextAddress("p"), anchor = ElementID(change: ChangeID(counter: 0, actor: ""), index: 2)
    var edits: [Mutation] = [.insertBlock(block: try .paragraph(id: "p", text: "ABC"),
        placement: ElementID(change: first, index: 0), after: nil)]
    if initialized {
        edits.append(.formatText(address: address, ids: [ElementID(change: ChangeID(counter: 0, actor: ""), index: 0)],
            markType: "bold", mark: .object(["type": .string("bold")])))
    }
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [
        Change(id: first, body: .edit(edits)),
        Change(id: replacement, body: .edit([.insertBlock(block: try .paragraph(id: "p", text: "Q"),
            placement: ElementID(change: replacement, index: 0), after: nil)])),
    ]))
    let id = ChangeID(counter: 3, actor: "remote")
    let batch = ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [
        Change(id: id, body: .edit([.insertText(address: address, atoms: [
            TextAtom(id: ElementID(change: id, index: 0), after: anchor, node: textNodeForReferenceTest("X")),
        ])])),
    ])
    if initialized {
        try session.receive(batch)
        #expect(try session.text(at: address) == "ABCX")
        #expect(try EditorSession.restore(session.save(), actorID: "local").document == session.document)
    } else {
        let saved = try session.save(), receipts = session.syncState
        #expect(throws: EditorError.invalidChange) { try session.receive(batch) }
        #expect(try session.save() == saved)
        #expect(session.syncState == receipts)
    }
}

@Test(arguments: [1, 2])
func seedAnchorsPreserveUnicodeReferencesAndTombstones(version: Int) throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityId": .string("e"),
        "entityType": .string("note"), "label": .string("Long reference")])
    let baseline = try Document(blocks: [Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNodeForReferenceTest("P😀"), reference])])])
    let source = try EditorSession(documentID: "seed-valid", actorID: "source", document: baseline, collaborationVersion: version)
    let address = TextAddress("p", identity: version == 2 ? .baseline(blockID: "p", path: []) : nil)
    let id = ChangeID(counter: 1, actor: "remote")
    func seed(_ index: Int) -> ElementID { ElementID(change: ChangeID(counter: 0, actor: ""), index: index) }
    try source.receive(ChangeBatch(documentID: source.documentID, baseline: baseline, changes: [
        Change(id: id, body: .edit([
            .deleteText(address: address, ids: [seed(1)]),
            .insertText(address: address, atoms: [
                TextAtom(id: ElementID(change: id, index: 0), after: seed(1), node: textNodeForReferenceTest("X")),
                TextAtom(id: ElementID(change: id, index: 1), after: seed(2), node: textNodeForReferenceTest("Y")),
            ]),
            .formatText(address: address, ids: [seed(0)], markType: "bold", mark: .object(["type": .string("bold")])),
        ])),
    ], version: version))
    #expect(try source.text(at: address) == "PXLong referenceY")
    #expect(try source.document.blocks[0].fields["content"]?.array?.contains(reference) == true)
    #expect(try source.document.blocks[0].fields["content"]?.array?.first?["marks"] == .array([.object(["type": .string("bold")])]))
    // The reference label is many characters but occupies one seed atom.
    let saved = try source.save()
    #expect(throws: EditorError.invalidChange) {
        try source.receive(ChangeBatch(documentID: source.documentID, baseline: baseline, changes: [
            Change(id: ChangeID(counter: 2, actor: "remote"), body: .edit([.deleteText(address: address, ids: [seed(3)])])),
        ], version: version))
    }
    #expect(try source.save() == saved)
    #expect(try EditorSession.restore(saved, actorID: "source").document == source.document)
}

@Test(arguments: [1, 2])
func sameTransactionCreationSeedsRemainValid(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Original")])
    let session = try EditorSession(documentID: "seed-created", actorID: "local", document: baseline, collaborationVersion: version)
    let id = ChangeID(counter: 1, actor: "remote"), creation = ElementID(change: ChangeID(counter: 1, actor: "remote"), index: 0)
    let node = NodeID.inserted(creation: creation, path: [])
    let block = try Block.paragraph(id: "new", text: "😀")
    let address = version == 1 ? TextAddress("new") : TextAddress("@remote/1/0", identity: node)
    let insert: Mutation = version == 1
        ? .insertBlock(block: block, placement: creation, after: ElementID(change: ChangeID(counter: 0, actor: ""), index: 0))
        : .insertNode(value: .object(block.fields), identity: node, collection: .root, placement: creation,
            after: .initial(.baseline(blockID: "p", path: [])))
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [
        Change(id: id, body: .edit([insert, .insertText(address: address, atoms: [
            TextAtom(id: ElementID(change: id, index: 1), after: ElementID(change: ChangeID(counter: 0, actor: ""), index: 0),
                node: textNodeForReferenceTest("X")),
        ])])),
    ], version: version))
    #expect(try session.document.blocks.map(\.id) == ["p", "new"])
    #expect(try session.text(at: address) == "😀X")
}

@Test func knownCreationSeedsValidateWhileTheirParentIsMissing() throws {
    let baseline = try Document(blocks: [])
    let parentChange = ChangeID(counter: 1, actor: "remote"), childChange = ChangeID(counter: 2, actor: "remote")
    let parentCreation = ElementID(change: parentChange, index: 0), childCreation = ElementID(change: childChange, index: 0)
    let parent = NodeID.inserted(creation: parentCreation, path: []), child = NodeID.inserted(creation: childCreation, path: [])
    let parentBlock = try Block(fields: ["id": .string("parent"), "type": .string("toggle"),
        "summary": .array([textNodeForReferenceTest("Parent")]), "children": .array([])])
    let childBlock = try Block.paragraph(id: "child", text: "😀")
    let parentEdit = Change(id: parentChange, body: .edit([.insertNode(value: .object(parentBlock.fields),
        identity: parent, collection: .root, placement: parentCreation, after: nil)]))
    let childEdit = Change(id: childChange, body: .edit([.insertNode(value: .object(childBlock.fields),
        identity: child, collection: NodeCollection(owner: parent, field: "children"), placement: childCreation, after: nil)]))
    let address = TextAddress("@remote/2/0", identity: child)
    let session = try EditorSession(documentID: "seed-missing-parent", actorID: "local", document: baseline, collaborationVersion: 2)
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [childEdit], version: 2))
    let saved = try session.save()
    let textID = ChangeID(counter: 3, actor: "remote")
    func edit(_ index: Int) -> Change {
        Change(id: textID, body: .edit([.insertText(address: address, atoms: [
            TextAtom(id: ElementID(change: textID, index: 0), after: ElementID(change: ChangeID(counter: 0, actor: ""), index: index),
                node: textNodeForReferenceTest("X")),
        ])]))
    }
    #expect(throws: EditorError.invalidChange) {
        try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [edit(1)], version: 2))
    }
    #expect(try session.save() == saved)
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [edit(0)], version: 2))
    #expect(try session.document == baseline)
    try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: [parentEdit], version: 2))
    #expect(try session.text(at: address) == "😀X")
    let peer = try EditorSession(documentID: session.documentID, actorID: "peer", document: baseline, collaborationVersion: 2)
    try peer.receive(ChangeBatch(documentID: peer.documentID, baseline: baseline, changes: [edit(0), childEdit, parentEdit], version: 2))
    #expect(try peer.document == session.document)
    #expect(try EditorSession.restore(session.save(), actorID: "local").document == session.document)
}

@Test(arguments: [1, 2])
func undoOfMissingEditRemainsValidUntilItsCausalTargetArrives(version: Int) throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Original")])
    let source = try EditorSession(documentID: "undo-delayed", actorID: "remote", document: baseline, collaborationVersion: version)
    try source.setText(at: TextAddress("p"), to: "Edited"); try source.undo()
    let changes = source.changes().changes
    let peer = try EditorSession(documentID: source.documentID, actorID: "peer", document: baseline, collaborationVersion: version)
    try peer.receive(ChangeBatch(documentID: peer.documentID, baseline: baseline, changes: [changes[1]], version: version))
    #expect(try peer.document == baseline)
    try peer.receive(ChangeBatch(documentID: peer.documentID, baseline: baseline, changes: [changes[0]], version: version))
    #expect(try peer.document == source.document)
    try source.redo(); try peer.receive(source.changes())
    #expect(try peer.text(at: TextAddress("p")) == "Edited")
    #expect(try EditorSession.restore(peer.save(), actorID: "peer").document == source.document)
}
