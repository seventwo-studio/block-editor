import BlockEditorCore
import Foundation
import Testing

private let mixedReference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"),
    "entityId": .string("external"), "label": .string("Task"), "consumer": .object(["id": .string("opaque-reference")])])
private let mixedClipboard = WritingClipboard(parts: [
    .inline([textNode("東京😀", marks: [.object(["type": .string("bold")])])]),
    .node(value: .object(["id": .string("import"), "type": .string("toggle"), "summary": .array([mixedReference]),
        "children": .array([.object(["id": .string("child"), "type": .string("paragraph"), "content": .array([textNode("inside")]),
            "consumer": .object(["id": .string("opaque-child")])])]), "consumer": .object(["id": .string("opaque-owner")])]), kind: "block"),
    .inline([mixedReference])
])
private func mixedSession(_ actor: String, version: Int = 5) throws -> WritingSession {
    try WritingSession(documentID: "mixed-paste", actorID: actor, epoch: "mixed-\(version)",
        document: Document(blocks: [Block(fields: ["id": .string("p"), "type": .string("paragraph"),
            "content": .array([textNode("abcd", marks: [.object(["type": .string("italic")])])]),
            "consumer": .object(["id": .string("opaque-boundary")])])]), protocolVersion: version)
}

@Test(arguments: ["a", "z"])
func mixedPasteAbsorbsOnlyExplicitInlineBoundariesAndFreshensWholeSchemaNodes(actor: String) throws {
    let a = try mixedSession(actor), b = try mixedSession("m"), address = TextAddress("p")
    let selected = try a.selectedText(at: address, range: 1..<3)
    _ = try b.replaceText(at: address, range: 4..<4, with: "R")
    let peer = b.changes()
    let position = try a.pasteSelection(mixedClipboard, replacing: selected)
    #expect(a.changes().changes.count == 1)
    try a.receive(peer); try b.receive(a.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1", "paste-\(actor)-1-3"])
    #expect(a.document.blocks[0].fields["content"] == .array([
        textNode("a", marks: [.object(["type": .string("italic")])]),
        textNode("東京😀", marks: [.object(["type": .string("bold")])])]))
    let owner = a.document.blocks[1]
    #expect(owner.fields["summary"] == .array([mixedReference]))
    #expect(owner.fields["consumer"] == .object(["id": .string("opaque-owner")]))
    #expect(owner.fields["children"]?.array?.first == .object([
        "id": .string("paste-\(actor)-1-2"), "type": .string("paragraph"), "content": .array([textNode("inside")]),
        "consumer": .object(["id": .string("opaque-child")])]))
    #expect(a.document.blocks[2].fields["content"] == .array([
        mixedReference, textNode("dR", marks: [.object(["type": .string("italic")])])]))
    #expect(a.document.blocks[0].fields["consumer"] == .object(["id": .string("opaque-boundary")]))
    #expect(a.document.blocks[2].fields["consumer"] == .object(["id": .string("opaque-boundary")]))
    #expect(try a.resolve(position).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.count == 1)
    #expect(try reopened.text(at: address) == "abcdR")
    #expect(b.document == reopened.document)
    try reopened.redo(); try b.receive(reopened.changes()); try b.receive(reopened.changes())
    #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test func mixedPasteAtZeroKeepsOriginalSuffixOwnerWithoutAnIncidentalBlankHead() throws {
    let session = try mixedSession("a")
    let clipboard = WritingClipboard(parts: [mixedClipboard.parts[1], .inline([mixedReference])])
    let position = try session.pasteSelection(clipboard, replacing: session.selectedText(at: TextAddress("p"), range: 0..<0))
    #expect(session.document.blocks.map(\.id) == ["paste-a-1-1", "p"])
    #expect(try session.text(at: TextAddress("p")) == "Taskabcd")
    #expect(try session.resolve(position).offset == 4)
    #expect(session.document.blocks[1].fields["consumer"] == .object(["id": .string("opaque-boundary")]))
    try session.undo(); #expect(try session.text(at: TextAddress("p")) == "abcd")
}

@Test func mixedPasteRejectsPolicyAndOldEpochBeforeAnyAcceptedMutation() throws {
    let old = try mixedSession("a", version: 4), session = try mixedSession("a")
    for active in [old, session] {
        let before = try active.save(), receipt = active.syncState
        #expect(throws: EditorError.self) {
            _ = try active.pasteSelection(mixedClipboard, replacing: active.selectedText(at: TextAddress("p"), range: 1..<3),
                policy: WritingPastePolicy(allowedBlockTypes: ["paragraph"], allowedMarkTypes: []))
        }
        #expect(try active.save() == before); #expect(active.syncState == receipt)
    }
    session.isComposing = true
    let before = try session.save()
    #expect(throws: WritingSessionError.compositionActive) {
        _ = try session.pasteSelection(mixedClipboard, replacing: session.selectedText(at: TextAddress("p"), range: 1..<3))
    }
    #expect(try session.save() == before)
}

@Test(arguments: ["a", "z"], [1, 2])
func mixedPasteConcurrentCutsOrderCompleteGroupsAndFollowBoundaryPrefix(actor: String, cut: Int) throws {
    let a = try mixedSession(actor), b = try mixedSession("m"), address = TextAddress("p")
    let position = try a.pasteSelection(mixedClipboard, replacing: a.selectedText(at: address, range: cut..<cut))
    _ = try b.splitParagraph(at: address, range: (3 - cut)..<(3 - cut), newBlockID: "peer-tail")
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try b.receive(own); try a.receive(peer)
    #expect(a.document == b.document)
    let middle = "paste-\(actor)-1-1", tail = "paste-\(actor)-1-3"
    #expect(a.document.blocks.map(\.id) == (cut == 1 ? ["p", middle, tail, "peer-tail"] : ["p", "peer-tail", middle, tail]))
    #expect(try a.text(at: address) == (cut == 1 ? "a東京😀" : "a"))
    #expect(try a.text(at: TextAddress("peer-tail")) == (cut == 1 ? "cd" : "b東京😀"))
    #expect(try a.text(at: TextAddress(tail)) == (cut == 1 ? "Taskb" : "Taskcd"))
    #expect(try a.resolve(position).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "peer-tail"])
    #expect(try reopened.text(at: address) == (cut == 1 ? "ab" : "a"))
    #expect(try reopened.text(at: TextAddress("peer-tail")) == (cut == 1 ? "cd" : "bcd"))
    try reopened.redo(); try b.receive(reopened.changes())
    #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], [false, true])
func mixedPasteAdjacentInlineFieldsKeepTheirExplicitBreak(actor: String, emptyLeading: Bool) throws {
    let a = try mixedSession(actor), b = try mixedSession("m"), address = TextAddress("p")
    let clipboard = WritingClipboard(parts: [.inline(emptyLeading ? [] : [textNode("東京😀")]), .inline([mixedReference])])
    let position = try a.pasteSelection(clipboard, replacing: a.selectedText(at: address, range: 0..<4))
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1"])
    #expect(try a.text(at: address) == (emptyLeading ? "" : "東京😀"))
    #expect(a.document.blocks[1].fields["content"] == .array([mixedReference]))
    #expect(try a.resolve(position).offset == 4)
    #expect(a.changes().changes.count == 1)
    try b.receive(a.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(try reopened.text(at: address) == "abcd"); #expect(b.document == reopened.document)
    try reopened.redo(); try b.receive(reopened.changes())
    #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], [2, 4])
func mixedPasteZeroReplacementRetainsSuffixOriginWithConcurrentSplit(actor: String, upper: Int) throws {
    let a = try mixedSession(actor), b = try mixedSession("m"), address = TextAddress("p")
    let clipboard = WritingClipboard(parts: [mixedClipboard.parts[1], .inline([mixedReference])])
    let position = try a.pasteSelection(clipboard, replacing: a.selectedText(at: address, range: 0..<upper))
    _ = try b.splitParagraph(at: address, range: 2..<2, newBlockID: "peer-tail")
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try b.receive(own); try a.receive(peer)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["paste-\(actor)-1-1", "p", "peer-tail"])
    #expect(try a.text(at: address) == "Task")
    #expect(try a.text(at: TextAddress("peer-tail")) == (upper == 2 ? "cd" : ""))
    #expect(a.document.blocks[1].fields["consumer"] == .object(["id": .string("opaque-boundary")]))
    #expect(try a.resolve(position).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "peer-tail"])
    #expect(try reopened.text(at: address) == "ab")
    #expect(try reopened.text(at: TextAddress("peer-tail")) == "cd")
    try reopened.redo(); try b.receive(reopened.changes())
    #expect(reopened.document == accepted); #expect(b.document == accepted)
}

private func crossPasteSession(_ actor: String, endpointMetadata: Bool = false) throws -> WritingSession {
    var endpoint: [String: JSONValue] = ["id": .string("q"), "type": .string("paragraph"),
        "content": .array([mixedReference, textNode("cd", marks: [.object(["type": .string("code")])])])]
    if endpointMetadata { endpoint["consumer"] = .object(["id": .string("opaque-endpoint")]) }
    return try WritingSession(documentID: "cross-paste", actorID: actor, epoch: "cross-5", document: Document(blocks: [
        Block(fields: ["id": .string("p"), "type": .string("paragraph"),
            "content": .array([textNode("ab", marks: [.object(["type": .string("italic")])])]),
            "consumer": .object(["id": .string("opaque-prefix")])]),
        Block(fields: ["id": .string("middle"), "type": .string("toggle"), "summary": .array([textNode("selected")]),
            "children": .array([.object(["id": .string("old-child"), "type": .string("paragraph"), "content": .array([textNode("gone")])])]),
            "consumer": .object(["id": .string("opaque-middle")])]),
        Block(fields: endpoint)
    ]), protocolVersion: 5)
}

@Test(arguments: ["a", "z"], [false, true])
func crossPasteInlineUsesOneAuthorJoinAndPreservesPeerAtoms(actor: String, reversed: Bool) throws {
    let a = try crossPasteSession(actor), b = try crossPasteSession("m")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    let range = WritingTextRange(start: reversed ? last : first, end: reversed ? first : last)
    let peerCaret = try b.position(at: TextAddress("q"), offset: 6)
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    let position = try a.pasteSelection(WritingClipboard(parts: [.inline([textNode("東京😀", marks: [.object(["type": .string("bold")])])])]), replacing: range)
    #expect(a.changes().changes.count == 1)
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try b.receive(own); try a.receive(peer)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p"])
    #expect(a.document.blocks[0].fields["content"] == .array([
        textNode("a", marks: [.object(["type": .string("italic")])]),
        textNode("東京😀", marks: [.object(["type": .string("bold")])]),
        textNode("cdR", marks: [.object(["type": .string("code")])])]))
    #expect(a.document.blocks[0].fields["consumer"] == .object(["id": .string("opaque-prefix")]))
    #expect(try a.resolve(position).offset == 5)
    #expect(try a.resolve(peerCaret).address.identity == a.node(at: NodeAddress("p")))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q"])
    #expect(try reopened.text(at: TextAddress("p")) == "ab")
    #expect(try reopened.text(at: TextAddress("q")) == "TaskcdR")
    #expect(reopened.document.blocks[1].fields["consumer"] == .object(["id": .string("opaque-middle")]))
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], [false, true])
func crossPasteMixedRetainsWholeImportsAndObservedSuffixOneUndo(actor: String, reversed: Bool) throws {
    let a = try crossPasteSession(actor), b = try crossPasteSession("m")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    let range = WritingTextRange(start: reversed ? last : first, end: reversed ? first : last)
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    let position = try a.pasteSelection(mixedClipboard, replacing: range)
    let own = a.changes(), peer = b.changes()
    #expect(own.changes.count == 1)
    try a.receive(peer); try b.receive(own); try b.receive(own); try a.receive(peer)
    #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "paste-\(actor)-1-1", "paste-\(actor)-1-3"])
    #expect(try a.text(at: TextAddress("p")) == "a東京😀")
    let imported = a.document.blocks[1]
    #expect(imported.fields["summary"] == .array([mixedReference]))
    #expect(imported.fields["consumer"] == .object(["id": .string("opaque-owner")]))
    #expect(imported.fields["children"]?.array?.first?["id"] == .string("paste-\(actor)-1-2"))
    #expect(a.document.blocks[2].fields["content"] == .array([mixedReference, textNode("cdR", marks: [.object(["type": .string("code")])])]))
    #expect(a.document.blocks[2].fields["consumer"] == .object(["id": .string("opaque-prefix")]))
    #expect(try a.resolve(position).offset == 4)
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(reopened.document.blocks.map(\.id) == ["p", "middle", "q"])
    #expect(try reopened.text(at: TextAddress("p")) == "ab")
    #expect(try reopened.text(at: TextAddress("q")) == "TaskcdR")
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test func crossPasteMetadataEndpointRejectsWithoutAcceptedMutation() throws {
    let a = try crossPasteSession("a", endpointMetadata: true)
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    let before = try a.save(), receipt = a.syncState
    #expect(throws: EditorError.invalidPath) { try a.pasteSelection(mixedClipboard, replacing: WritingTextRange(start: first, end: last)) }
    #expect(try a.save() == before); #expect(a.syncState == receipt)
}

@Test(arguments: ["a", "z"])
func crossPastePreservesUnseenIntermediateChildAndBoundaryText(actor: String) throws {
    let a = try crossPasteSession(actor), b = try crossPasteSession("m")
    let owner = try b.node(at: NodeAddress("middle"))
    let foreign: JSONValue = .object(["id": .string("foreign"), "type": .string("paragraph"),
        "content": .array([textNode("peer😀"), mixedReference]), "consumer": .object(["id": .string("opaque-foreign")])])
    let inserted = try b.insertCollectionNodes([foreign], into: NodeCollection(owner: owner, field: "children"))
    let foreignIdentity = try #require(inserted.nodes.first)
    _ = try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "X")
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(mixedClipboard, replacing: WritingTextRange(start: first, end: last))
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try b.receive(own); try a.receive(peer)
    #expect(a.document == b.document)
    let live = try a.address(of: foreignIdentity)
    #expect(live == NodeAddress("middle", path: ["children", "foreign"]))
    let retained = try #require(a.document.blocks.first(where: { $0.id == "middle" }))
    #expect(retained.fields["children"] == .array([foreign]))
    #expect(retained.fields["consumer"] == .object(["id": .string("opaque-middle")]))
    #expect(try a.text(at: TextAddress("paste-\(actor)-1-3")) == "TaskXcdR")
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes())
    #expect(try reopened.text(at: TextAddress("p")) == "abX")
    #expect(try reopened.text(at: TextAddress("q")) == "TaskcdR")
    #expect(try reopened.node(at: NodeAddress("middle", path: ["children", "foreign"])) == foreignIdentity)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}

@Test(arguments: ["a", "z"], ["source-before", "source-after", "endpoint-before", "endpoint-after"])
func crossPasteConcurrentBoundarySplitsPreserveCutOwners(actor: String, scenario: String) throws {
    let a = try crossPasteSession(actor), b = try crossPasteSession("m")
    let first = try a.position(at: TextAddress("p"), offset: 1), last = try a.position(at: TextAddress("q"), offset: 4)
    _ = try a.pasteSelection(mixedClipboard, replacing: WritingTextRange(start: first, end: last))
    let sourceCut = scenario.hasPrefix("source"), cut = scenario.hasSuffix("before") ? 0 : (sourceCut ? 2 : 6)
    let peerAddress = TextAddress(sourceCut ? "p" : "q")
    _ = try b.splitParagraph(at: peerAddress, range: cut..<cut, newBlockID: "peer-tail")
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    let imported = "paste-\(actor)-1-1", continuation = "paste-\(actor)-1-3"
    #expect(a.document.blocks.map(\.id) == (scenario == "source-before"
        ? ["p", "peer-tail", imported, continuation] : ["p", imported, continuation, "peer-tail"]))
    #expect(try a.text(at: TextAddress("p")) == (scenario == "source-before" ? "" : "a東京😀"))
    #expect(try a.text(at: TextAddress("peer-tail")) == (scenario == "source-before" ? "a東京😀" : scenario == "endpoint-before" ? "cd" : ""))
    #expect(try a.text(at: TextAddress(continuation)) == (scenario == "endpoint-before" ? "Task" : "Taskcd"))
    #expect(a.document.blocks.first(where: { $0.id == imported })?.fields["consumer"] == .object(["id": .string("opaque-owner")]))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(reopened.document == b.document)
    #expect(reopened.document.blocks.map(\.id) == (sourceCut ? ["p", "peer-tail", "middle", "q"] : ["p", "middle", "q", "peer-tail"]))
    #expect(try reopened.text(at: peerAddress) == (cut == 0 ? "" : (sourceCut ? "ab" : "Taskcd")))
    #expect(try reopened.text(at: TextAddress("peer-tail")) == (cut == 0 ? (sourceCut ? "ab" : "Taskcd") : ""))
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted); #expect(b.document == accepted)
}
