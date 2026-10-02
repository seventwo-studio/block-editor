import BlockEditorCore
import Foundation
import Testing

private let retainedRef: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("external"),
    "label": .string("Task"), "host": .object(["id": .string("opaque-reference")])])
private let retainedClipboard = WritingClipboard(parts: [
    .inline([textNode("東京😀", marks: [.object(["type": .string("bold")])])]),
    .node(value: .object(["id": .string("import"), "type": .string("toggle"), "summary": .array([retainedRef]),
        "children": .array([.object(["id": .string("child"), "type": .string("paragraph"), "content": .array([textNode("nested")]),
            "host": .object(["id": .string("opaque-child")])])]), "host": .object(["id": .string("opaque-import")])]), kind: "block"),
    .inline([retainedRef])
])
private func retainedPasteSession(_ actor: String, version: Int = 6, plainEndpoint: Bool = false) throws -> WritingSession {
    try WritingSession(documentID: "retained-paste", actorID: actor, epoch: "retained-epoch", document: Document(blocks: [
        Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("ab")]), "host": .object(["id": .string("opaque-start")])]),
        Block(fields: ["id": .string("middle"), "type": .string("divider"), "host": .object(["id": .string("opaque-middle")])]),
        Block(fields: ["id": .string("q"), "type": .string("paragraph"), "content": .array(plainEndpoint ? [textNode("Taskcd")] : [retainedRef, textNode("cd", marks: [.object(["type": .string("italic")])])]),
            "host": .object(["id": .string("opaque-end")])]),
        try Block.paragraph(id: "outside", text: "outside")
    ]), protocolVersion: version)
}

@Test(arguments: ["a", "z"], [false, true])
func retainedPasteKeepsBothOpaqueOwnersAndOneAuthorUndo(actor: String, reversed: Bool) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let prefixID = try a.node(at: NodeAddress("p")), endpointID = try a.node(at: NodeAddress("q"))
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    _ = try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "X")
    let range = WritingTextRange(start: reversed ? last : first, end: reversed ? first : last)
    let caret = try a.pasteSelection(retainedClipboard, replacing: range)
    #expect(a.changes().changes.count == 1)
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1", "q", "outside"])
    #expect(try a.node(at: NodeAddress("p")) == prefixID); #expect(try a.node(at: NodeAddress("q")) == endpointID)
    #expect(try a.text(at: TextAddress("p")) == "a東京😀")
    #expect(try a.text(at: TextAddress("q")) == "TaskXcdR")
    #expect(a.document.blocks[0].fields["host"] == .object(["id": .string("opaque-start")]))
    #expect(a.document.blocks[2].fields["host"] == .object(["id": .string("opaque-end")]))
    #expect(a.document.blocks[1].fields["summary"] == .array([retainedRef]))
    #expect(a.document.blocks[1].fields["children"]?.array?.first?["id"] == .string("paste-\(actor)-1-2"))
    #expect(try a.resolve(caret).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q", "outside"])
    #expect(try reopened.text(at: TextAddress("p")) == "abX"); #expect(try reopened.text(at: TextAddress("q")) == "TaskcdR")
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteAtZeroUsesOriginalEndpointAndNoBlankPrefix(actor: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let endpoint = try a.node(at: NodeAddress("q"))
    let first = try a.position(at: TextAddress("p"), offset: 0), last = try a.position(at: TextAddress("q"), offset: 4)
    let clipboard = WritingClipboard(parts: [retainedClipboard.parts[1], retainedClipboard.parts[2]])
    let caret = try a.pasteSelection(clipboard, replacing: WritingTextRange(start: first, end: last))
    #expect(a.document.blocks.map(\.id) == ["paste-\(actor)-1-1", "q", "outside"])
    #expect(try a.node(at: NodeAddress("q")) == endpoint)
    #expect(try a.text(at: TextAddress("q")) == "Taskcd")
    #expect(a.document.blocks[1].fields["host"] == .object(["id": .string("opaque-end")]))
    #expect(try a.resolve(caret).offset == 4)
    try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q", "outside"])
    try reopened.redo(); #expect(reopened.document == accepted)
}

@Test func retainedPasteDoesNotUpgradeOrAdmitMixedEpochs() throws {
    for version in [4, 5] {
        let old = try retainedPasteSession("a", version: version), next = try retainedPasteSession("b")
        let before = try old.save(), receipt = old.syncState, nextBefore = try next.save(), nextReceipt = next.syncState
        #expect(throws: EditorError.unsupportedVersion(6)) { try old.receive(next.changes()) }
        #expect(throws: EditorError.unsupportedVersion(version)) { try next.receive(old.changes()) }
        #expect(try old.save() == before && old.syncState == receipt)
        #expect(try next.save() == nextBefore && next.syncState == nextReceipt)
        #expect(try WritingSession.restore(before, actorID: "a").protocolVersion == version)
    }
}

@Test(arguments: ["a", "z"], ["source-before", "source-after", "endpoint-before", "endpoint-after"])
func retainedPasteConcurrentSplitsOrderRetainedEndpointGroup(actor: String, scenario: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let endpoint = try a.node(at: NodeAddress("q"))
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    let sourceCut = scenario.hasPrefix("source"), cut = scenario.hasSuffix("before") ? 0 : (sourceCut ? 2 : 6)
    let address = TextAddress(sourceCut ? "p" : "q")
    _ = try b.splitParagraph(at: address, range: cut..<cut, newBlockID: "peer-tail")
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == (scenario == "source-before"
        ? ["p", "peer-tail", "paste-\(actor)-1-1", "q", "outside"] : ["p", "paste-\(actor)-1-1", "q", "peer-tail", "outside"]))
    #expect(try a.text(at: TextAddress("p")) == (scenario == "source-before" ? "" : "a東京😀"))
    #expect(try a.text(at: TextAddress("q")) == (scenario == "endpoint-before" ? "Task" : "Taskcd"))
    #expect(try a.text(at: TextAddress("peer-tail")) == (scenario == "source-before" ? "a東京😀" : scenario == "endpoint-before" ? "cd" : ""))
    #expect(try a.node(at: NodeAddress("q")) == endpoint)
    #expect(a.document.blocks.first(where: { $0.id == "q" })?.fields["host"] == .object(["id": .string("opaque-end")]))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document == b.document)
    #expect(reopened.document.blocks.map(\.id) == (sourceCut ? ["p", "peer-tail", "middle", "q", "outside"] : ["p", "middle", "q", "peer-tail", "outside"]))
    #expect(try reopened.text(at: address) == (cut == 0 ? "" : (sourceCut ? "ab" : "Taskcd")))
    #expect(try reopened.text(at: TextAddress("peer-tail")) == (cut == 0 ? (sourceCut ? "ab" : "Taskcd") : ""))
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], [false, true])
func retainedPasteOverlappingEndpointExportsAndEitherAuthorRepairs(actor: String, repairPeer: Bool) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    _ = try b.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    let own = a.changes(), peer = b.changes(), savedA = try a.save(), receiptA = a.syncState
    let savedB = try b.save(), receiptB = b.syncState
    #expect(throws: WritingSessionError.self) { try a.receive(peer) }
    #expect(throws: WritingSessionError.self) { try b.receive(own) }
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    #expect(try a.save() == savedA && a.syncState == receiptA)
    #expect(try b.save() == savedB && b.syncState == receiptB)
    let original = repairPeer ? b : a, reopened = try WritingSession.restore(original.save(), actorID: repairPeer ? "m" : actor)
    let proposal = try #require(original.mergeRecovery), target = try #require((repairPeer ? peer : own).changes.first?.id)
    let exported = try #require(try original.exportRecovery())
    #expect(throws: WritingSessionError.self) { try reopened.restoreRecovery(exported) }
    #expect(reopened.mergeRecovery == proposal)
    try reopened.repairUndo(target)
    let other = repairPeer ? a : b
    try other.receive(reopened.changes()); try other.receive(reopened.changes())
    #expect(other.document == reopened.document)
    #expect(reopened.mergeRecovery == nil)
    let surviving = repairPeer ? actor : "m"
    #expect(reopened.document.blocks.map(\.id) == ["p", "paste-\(surviving)-1-1", "q", "outside"])
    #expect(reopened.document.blocks[2].fields["host"] == .object(["id": .string("opaque-end")]))
    let accepted = try WritingSession.restore(reopened.save(), actorID: repairPeer ? "m" : actor)
    #expect(accepted.document == reopened.document && accepted.mergeRecovery == nil)
}


@Test func retainedPasteNewWireCannotBeSpoofedIntoFiveOrMissingCohortAdmitted() throws {
    let a = try retainedPasteSession("a"), b = try retainedPasteSession("b"), old = try retainedPasteSession("b", version: 5)
    _ = try a.replaceText(at: TextAddress("outside"), range: 7..<7, with: "東京")
    let predecessor = a.changes()
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    let complete = a.changes(), latest = try #require(complete.changes.last)
    let spoofed = WritingBatch(documentID: complete.documentID, epoch: complete.epoch, baseline: complete.baseline,
        changes: complete.changes, version: 5)
    let oldSave = try old.save(), oldReceipt = old.syncState
    #expect(throws: EditorError.invalidChange) { try old.receive(spoofed) }
    #expect(try old.save() == oldSave && old.syncState == oldReceipt && old.mergeRecovery == nil)
    #expect(throws: EditorError.invalidChange) { try WritingSession.restore(JSONEncoder().encode(spoofed), actorID: "b") }
    let accepted = try b.save(), receipt = b.syncState
    let delta = WritingBatch(documentID: complete.documentID, epoch: complete.epoch, baseline: complete.baseline, changes: [latest], version: 6)
    #expect(throws: WritingSessionError.self) { try b.receive(delta) }
    #expect(try b.save() == accepted && b.syncState == receipt)
    let exported = try #require(try b.exportRecovery()), reopened = try WritingSession.restore(accepted, actorID: "b")
    #expect(throws: WritingSessionError.self) { try reopened.restoreRecovery(exported) }
    try reopened.receive(predecessor); try reopened.receive(delta)
    #expect(reopened.mergeRecovery == nil && reopened.document == a.document)
}

@Test(arguments: ["a", "z"])
func retainedPasteAfterOrdinarySourceMoveUsesLiveOrderNotRgaAfterAncestry(actor: String) throws {
    let a = try retainedPasteSession(actor)
    let source = try a.node(at: NodeAddress("p"))
    _ = try a.move(WritingSelection(nodes: [source]), into: .root)
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    let caret = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-2-1", "q", "outside"])
    #expect(try a.text(at: TextAddress("p")) == "a東京😀")
    #expect(try a.text(at: TextAddress("q")) == "Taskcd")
    #expect(try a.resolve(caret).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q", "outside"])
    try reopened.redo(); #expect(reopened.document == accepted)
}

@Test func retainedPasteCannotClaimGloballyKnownButUnobservedEndpointAtom() throws {
    let a = try retainedPasteSession("a"), b = try retainedPasteSession("b"), c = try retainedPasteSession("c")
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    let peer = b.changes(); try a.receive(peer); try c.receive(peer)
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    let latest = try #require(a.changes().changes.last)
    let forged = WritingChange(id: latest.id, body: latest.body, observed: [])
    let batch = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [forged], version: 6)
    let accepted = try c.save(), receipt = c.syncState
    #expect(throws: EditorError.invalidChange) { try c.receive(batch) }
    #expect(try c.save() == accepted && c.syncState == receipt && c.mergeRecovery == nil)
    try c.receive(a.changes()); #expect(c.document == a.document)
}

@Test(arguments: ["a", "z"])
func retainedPasteAcceptsObservedRoleSourceAndRejectsErasedRoleCohort(actor: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    try a.convertBlock(at: TextAddress("p"), offset: 0, to: WritingBlockTarget(type: "list", style: "ordered"))
    try b.receive(a.changes())
    try b.enterListItem(at: TextAddress("p", path: ["items", "p-item", "content"]), range: 1..<1, newItemID: "role-peer")
    try a.receive(b.changes()); try a.undo(); try b.receive(a.changes())
    let before = a.changes(), roleIdentity = try a.node(at: NodeAddress("role-peer"))
    let first = try a.position(at: TextAddress("role-peer"), offset: 0), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    #expect(a.document.blocks.map(\.id) == ["p", "role-peer", "paste-\(actor)-4-1", "q", "outside"])
    #expect(try a.node(at: NodeAddress("role-peer")) == roleIdentity)
    #expect(try a.text(at: TextAddress("role-peer")) == "東京😀")
    #expect(try a.text(at: TextAddress("q")) == "Taskcd")
    let latest = try #require(a.changes().changes.last), forged = WritingChange(id: latest.id, body: latest.body, observed: [])
    let snapshot = try b.save(), receipt = b.syncState
    #expect(throws: EditorError.invalidChange) {
        try b.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [forged], version: 6))
    }
    #expect(try b.save() == snapshot && b.syncState == receipt && b.mergeRecovery == nil)
    try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "role-peer", "middle", "q", "outside"])
    #expect(try reopened.text(at: TextAddress("role-peer")) == "b")
    #expect(reopened.changes().changes.filter { $0.id < latest.id } == before.changes)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteBaselineRoleRequiresObservedRetirement(actor: String) throws {
    let baseline = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("ordered"),
        "items": .array([.object(["id": .string("first"), "content": .array([textNode("keep")])]),
            .object(["id": .string("role-peer"), "content": .array([]), "host": .object(["id": .string("opaque-role")])])])]),
        Block(fields: ["id": .string("q"), "type": .string("paragraph"), "content": .array([retainedRef, textNode("cd")]),
            "host": .object(["id": .string("opaque-end")])])])
    let a = try WritingSession(documentID: "baseline-role", actorID: actor, epoch: "role-six", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "baseline-role", actorID: "m", epoch: "role-six", document: baseline, protocolVersion: 6)
    try b.enterListItem(at: TextAddress("list", path: ["items", "role-peer", "content"]), range: 0..<0, newItemID: "unused")
    try a.receive(b.changes())
    let identity = try a.node(at: NodeAddress("role-peer")), first = try a.position(at: TextAddress("role-peer"), offset: 0)
    let last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    #expect(try a.node(at: NodeAddress("role-peer")) == identity)
    #expect(a.document.blocks.first(where: { $0.id == "role-peer" })?.fields["host"] == .object(["id": .string("opaque-role")]))
    let latest = try #require(a.changes().changes.last), forged = WritingChange(id: latest.id, body: latest.body, observed: [])
    let accepted = try b.save(), receipt = b.syncState
    #expect(throws: EditorError.invalidChange) {
        try b.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: baseline, changes: [forged], version: 6))
    }
    #expect(try b.save() == accepted && b.syncState == receipt && b.mergeRecovery == nil)
    try b.receive(a.changes()); #expect(b.document == a.document)
    let reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); #expect(try reopened.node(at: NodeAddress("role-peer")) == identity)
    #expect(try reopened.text(at: TextAddress("role-peer")) == "")
    try reopened.redo(); #expect(reopened.document == a.document)
}

@Test func retainedPasteCannotRankFromGloballyKnownButUnobservedSourceAnchor() throws {
    let a = try retainedPasteSession("a"), b = try retainedPasteSession("b"), c = try retainedPasteSession("c")
    _ = try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "X")
    let peer = b.changes(); try a.receive(peer); try c.receive(peer)
    let first = try a.position(at: TextAddress("p"), offset: 2), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    let latest = try #require(a.changes().changes.last)
    let forged = WritingChange(id: latest.id, body: latest.body, observed: [])
    let batch = WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [forged], version: 6)
    let accepted = try c.save(), receipt = c.syncState
    #expect(throws: EditorError.invalidChange) { try c.receive(batch) }
    #expect(try c.save() == accepted && c.syncState == receipt && c.mergeRecovery == nil)
    try c.receive(a.changes()); #expect(c.document == a.document)
}

@Test(arguments: ["a", "z"])
func retainedPasteConcurrentHeadingPreservesEndpointSchemaAndUndo(actor: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    try b.convertBlock(at: TextAddress("q"), offset: 4, to: WritingBlockTarget(type: "heading", level: 2))
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    let endpoint = try #require(a.document.blocks.first(where: { $0.id == "q" }))
    #expect(endpoint.type == "heading" && endpoint.fields["level"] == .number(2))
    #expect(endpoint.fields["host"] == .object(["id": .string("opaque-end")]))
    #expect(try a.text(at: TextAddress("q")) == "Taskcd")
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q", "outside"])
    #expect(reopened.document.blocks[2].type == "heading" && reopened.document.blocks[2].fields["level"] == .number(2))
    #expect(try reopened.text(at: TextAddress("q")) == "Taskcd")
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteRichReferenceCannotFlattenThroughConcurrentCode(actor: String) throws {
    let a = try retainedPasteSession(actor, plainEndpoint: true), b = try retainedPasteSession("m", plainEndpoint: true)
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    try b.convertBlock(at: TextAddress("q"), offset: 4, to: WritingBlockTarget(type: "code"))
    let own = a.changes(), peer = b.changes(), accepted = try a.save(), receipt = a.syncState
    #expect(throws: WritingSessionError.self) { try a.receive(peer) }
    #expect(throws: WritingSessionError.self) { try b.receive(own) }
    #expect(a.mergeRecovery?.reason == .schemaConstraint && b.mergeRecovery?.reason == .schemaConstraint)
    #expect(try a.save() == accepted && a.syncState == receipt)
    let exported = try #require(try a.exportRecovery()), reopened = try WritingSession.restore(accepted, actorID: actor)
    #expect(throws: WritingSessionError.self) { try reopened.restoreRecovery(exported) }
    try reopened.repairUndo(try #require(own.changes.first?.id))
    try b.receive(reopened.changes()); try b.receive(reopened.changes())
    #expect(b.document == reopened.document)
    #expect(reopened.document.blocks.first(where: { $0.id == "q" })?.type == "code")
    #expect(reopened.document.blocks.first(where: { $0.id == "q" })?.fields["code"] == .string("Taskcd"))
    #expect(reopened.document.blocks.first(where: { $0.id == "q" })?.fields["host"] == .object(["id": .string("opaque-end")]))
}

@Test(arguments: ["a", "z"])
func retainedPasteInsideObservedInsertedToggleKeepsNestedInitialProofs(actor: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let nested: JSONValue = .object(["id": .string("nested"), "type": .string("toggle"), "summary": .array([textNode("owner")]),
        "host": .object(["id": .string("opaque-nested")]), "children": .array([
            .object(["id": .string("left"), "type": .string("paragraph"), "content": .array([textNode("ab")]), "host": .string("left-meta")]),
            .object(["id": .string("right"), "type": .string("paragraph"), "content": .array([retainedRef, textNode("cd")]), "host": .string("right-meta")])])])
    try b.insertCollectionNodes([nested], into: .root)
    try a.receive(b.changes())
    let left = TextAddress("nested", path: ["children", "left", "content"]), right = TextAddress("nested", path: ["children", "right", "content"])
    let endpoint = try a.node(at: NodeAddress("nested", path: ["children", "right"]))
    let first = try a.position(at: left, offset: 1), last = try a.position(at: right, offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    #expect(try a.node(at: NodeAddress("nested", path: ["children", "right"])) == endpoint)
    #expect(try a.text(at: left) == "a東京😀"); #expect(try a.text(at: right) == "Taskcd")
    let owner = try #require(a.document.blocks.first(where: { $0.id == "nested" }))
    #expect(owner.fields["host"] == .object(["id": .string("opaque-nested")]))
    #expect(owner.fields["children"]?.array?.map { $0["id"]?.string } == ["left", "paste-\(actor)-2-1", "right"])
    #expect(owner.fields["children"]?.array?.last?["host"] == .string("right-meta"))
    let latest = try #require(a.changes().changes.last), forged = WritingChange(id: latest.id, body: latest.body, observed: [])
    let acceptedB = try b.save(), receiptB = b.syncState
    #expect(throws: EditorError.invalidChange) {
        try b.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [forged], version: 6))
    }
    #expect(try b.save() == acceptedB && b.syncState == receiptB && b.mergeRecovery == nil)
    try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.first(where: { $0.id == "nested" })?.fields == nested.object)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], [false, true])
func retainedPasteLaterEndpointMoveStaysAuthoritativeThroughOwnUndo(actor: String, acrossContainer: Bool) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let endpoint = try a.node(at: NodeAddress("q"))
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(start: first, end: last))
    try b.receive(a.changes())
    if acrossContainer {
        let container: JSONValue = .object(["id": .string("container"), "type": .string("toggle"), "summary": .array([textNode("host")]), "children": .array([])])
        let added = try b.insertCollectionNodes([container], into: .root, after: b.node(at: NodeAddress("outside")))
        let owner = try #require(added.nodes.first)
        try b.move(WritingSelection(nodes: [endpoint]), into: NodeCollection(owner: owner, field: "children"))
    } else {
        try b.move(WritingSelection(nodes: [endpoint]), into: .root, after: b.node(at: NodeAddress("outside")))
    }
    try a.receive(b.changes()); try a.receive(b.changes())
    #expect(a.document == b.document)
    let location = acrossContainer ? NodeAddress("container", path: ["children", "q"]) : NodeAddress("q")
    #expect(try a.address(of: endpoint) == location)
    #expect(try a.text(at: a.textAddress(of: endpoint)) == "Taskcd")
    if !acrossContainer { #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1", "outside", "q"]) }
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(try reopened.address(of: endpoint) == location)
    #expect(try reopened.text(at: reopened.textAddress(of: endpoint)) == "Taskcd")
    #expect(try reopened.text(at: TextAddress("p")) == "ab")
    #expect(reopened.document.blocks.contains(where: { $0.id == "middle" }))
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteSequentialReuseKeepsOneStepHistory(actor: String) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    let endpoint = try a.node(at: NodeAddress("q"))
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("q"), offset: 4)))
    let first = a.document
    try b.receive(a.changes())
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("q"), offset: 4)))
    #expect(a.changes().changes.count == 2)
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-2-1", "q", "outside"])
    #expect(try a.node(at: NodeAddress("q")) == endpoint)
    #expect(try a.text(at: TextAddress("p")) == "a東京😀" && a.text(at: TextAddress("q")) == "Taskcd")
    try b.receive(a.changes()); try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(reopened.document == first && b.document == first)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteCanReuseObservedOrdinarySplitTail(actor: String) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd"), Block.paragraph(id: "outside", text: "outside")])
    let a = try WritingSession(documentID: "split-reuse", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "split-reuse", actorID: "m", epoch: "e", document: baseline, protocolVersion: 6)
    _ = try a.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    let first = a.document, endpoint = try a.node(at: NodeAddress("q"))
    let clipboard = WritingClipboard(parts: [.inline([textNode("L")]),
        .node(value: .object(["id": .string("import"), "type": .string("divider"), "host": .string("keep")]), kind: "block"), .inline([textNode("T")])])
    _ = try a.pasteSelection(clipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("q"), offset: 1)))
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-2-1", "q", "outside"])
    #expect(try a.node(at: NodeAddress("q")) == endpoint)
    #expect(try a.text(at: TextAddress("p")) == "aL" && a.text(at: TextAddress("q")) == "Td")
    try b.receive(a.changes()); try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(reopened.document == first && b.document == first)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"], [false, true])
func retainedPasteDifferentLaterSourceKeepsEarlierImportedMember(actor: String, concurrentCut: Bool) throws {
    let a = try retainedPasteSession(actor), b = try retainedPasteSession("m")
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("q"), offset: 4)))
    let oldImport = try a.node(at: NodeAddress("paste-\(actor)-1-1"))
    let earlier = try #require(a.document.blocks.first(where: { $0.id == "paste-\(actor)-1-1" }))
    _ = try a.insertCollectionNodes([.object(["id": .string("r"), "type": .string("paragraph"), "content": .array([textNode("rs")]), "host": .string("r-meta")])], into: .root, after: oldImport)
    let beforeLatest = a.document
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("r"), offset: 1), end: a.position(at: TextAddress("q"), offset: 4)))
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1", "r", "paste-\(actor)-3-1", "q", "outside"])
    #expect(a.document.blocks[1] == earlier)
    #expect(try a.text(at: TextAddress("r")) == "r東京😀" && a.text(at: TextAddress("q")) == "Taskcd")
    if concurrentCut { _ = try b.splitParagraph(at: TextAddress("p"), range: 0..<0, newBlockID: "peer-tail") }
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == (concurrentCut
        ? ["p", "peer-tail", "paste-\(actor)-1-1", "r", "paste-\(actor)-3-1", "q", "outside"]
        : ["p", "paste-\(actor)-1-1", "r", "paste-\(actor)-3-1", "q", "outside"]))
    #expect(a.document.blocks.first(where: { $0.id == "paste-\(actor)-1-1" }) == earlier)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    if !concurrentCut { #expect(reopened.document == beforeLatest) }
    #expect(!reopened.document.blocks.contains(where: { $0.id == "paste-\(actor)-3-1" }))
    #expect(reopened.document.blocks.first(where: { $0.id == "paste-\(actor)-1-1" }) == earlier)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test func retainedPasteCannotRankFromUnobservedSourcePinEvenWithBaselineEdge() throws {
    let a = try retainedPasteSession("a"), b = try retainedPasteSession("b"), c = try retainedPasteSession("c")
    _ = try b.replaceText(at: TextAddress("p"), range: 1..<1, with: "X")
    try a.receive(b.changes()); try c.receive(b.changes())
    let clipboard = WritingClipboard(parts: [retainedClipboard.parts[1], retainedClipboard.parts[2]])
    _ = try a.pasteSelection(clipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 2), end: a.position(at: TextAddress("q"), offset: 4)))
    let latest = try #require(a.changes().changes.last)
    guard case .edit(let operations) = latest.body else { Issue.record("Expected paste edit"); return }
    let endpoint = try c.position(at: TextAddress("p"), offset: 2)
    let baselineBoundary = try #require(endpoint.anchor)
    #expect(baselineBoundary.element.change.counter == 0)
    var replaced = false
    let body = operations.map { operation -> WritingOperation in
        guard case .text(.rangeSpliceBoundary(let splice)) = operation else { return operation }
        replaced = true
        return .text(.rangeSpliceBoundary(WritingRangeSplice(source: splice.source, destination: splice.destination,
            edge: .before(baselineBoundary), before: splice.before, members: splice.members,
            sourcePlacement: splice.sourcePlacement, endpointPlacement: splice.endpointPlacement,
            destinationPlacement: splice.destinationPlacement, endpointKeys: splice.endpointKeys)))
    }
    #expect(replaced)
    let forged = WritingChange(id: latest.id, body: .edit(body), observed: [])
    let accepted = try c.save(), receipt = c.syncState
    #expect(throws: EditorError.invalidChange) {
        try c.receive(WritingBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [forged], version: 6))
    }
    #expect(try c.save() == accepted && c.syncState == receipt && c.mergeRecovery == nil)
    try c.receive(a.changes()); #expect(c.document == a.document)
}

@Test(arguments: ["a", "z"])
func retainedPasteEndpointRoleKeepsOpaqueIdentityThroughHistory(actor: String) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "ab"),
        Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("unordered"), "items": .array([
            .object(["id": .string("keep"), "content": .array([textNode("keep")])]),
            .object(["id": .string("exited"), "content": .array([]), "host": .string("endpoint-meta")])])]),
        Block.paragraph(id: "outside", text: "outside")])
    let a = try WritingSession(documentID: "endpoint-role", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "endpoint-role", actorID: "m", epoch: "e", document: baseline, protocolVersion: 6)
    _ = try b.enterListItem(at: TextAddress("list", path: ["items", "exited", "content"]), range: 0..<0, newItemID: "unused")
    try a.receive(b.changes())
    let original = a.document, endpoint = try a.node(at: NodeAddress("exited"))
    _ = try a.pasteSelection(retainedClipboard, replacing: WritingTextRange(
        start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("exited"), offset: 0)))
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-2-1", "exited", "outside"])
    #expect(try a.node(at: NodeAddress("exited")) == endpoint)
    #expect(a.document.blocks[2].fields["host"] == .string("endpoint-meta"))
    #expect(try a.text(at: TextAddress("exited")) == "Task")
    try b.receive(a.changes()); try b.receive(a.changes()); #expect(b.document == a.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(reopened.document == original && b.document == original)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"])
func retainedPasteSupersededEndpointContainerDoesNotClaimOldSourceGroup(actor: String) throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "abcd")])
    let a = try WritingSession(documentID: "moved-reuse", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    _ = try a.splitParagraph(at: TextAddress("p"), range: 2..<2, newBlockID: "q")
    let endpoint = try a.node(at: NodeAddress("q"))
    let container: JSONValue = .object(["id": .string("container"), "type": .string("toggle"), "summary": .array([textNode("host")]),
        "children": .array([.object(["id": .string("r"), "type": .string("paragraph"), "content": .array([textNode("rs")])])])])
    let added = try a.insertCollectionNodes([container], into: .root, after: endpoint)
    let owner = try #require(added.nodes.first), child = try a.node(at: NodeAddress("container", path: ["children", "r"]))
    try a.move(WritingSelection(nodes: [endpoint]), into: NodeCollection(owner: owner, field: "children"), after: child)
    let left = TextAddress("container", path: ["children", "r", "content"]), right = TextAddress("container", path: ["children", "q", "content"])
    let clipboard = WritingClipboard(parts: [.inline([textNode("L")]),
        .node(value: .object(["id": .string("import"), "type": .string("divider")]), kind: "block"), .inline([textNode("T")])])
    _ = try a.pasteSelection(clipboard, replacing: WritingTextRange(start: a.position(at: left, offset: 1), end: a.position(at: right, offset: 1)))
    let beforeSplit = a.document
    _ = try a.splitParagraph(at: TextAddress("p"), range: 1..<1, newBlockID: "p-tail")
    #expect(a.document.blocks.map(\.id) == ["p", "p-tail", "container"])
    #expect(try a.text(at: TextAddress("p")) == "a" && a.text(at: TextAddress("p-tail")) == "b")
    #expect(a.document.blocks[2].fields["children"]?.array?.map { $0["id"]?.string } == ["r", "paste-\(actor)-4-1", "q"])
    #expect(try a.address(of: endpoint) == NodeAddress("container", path: ["children", "q"]))
    #expect(try a.text(at: left) == "rL" && a.text(at: right) == "Td")
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); #expect(reopened.document == beforeSplit)
    try reopened.redo(); #expect(reopened.document == accepted)
}
