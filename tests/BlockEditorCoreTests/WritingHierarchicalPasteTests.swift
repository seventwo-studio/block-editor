import BlockEditorCore
import Foundation
import Testing

private let hierarchyRef: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("external"), "label": .string("Task"), "host": .string("reference-meta")])
private let hierarchyClipboard = WritingClipboard(parts: [.inline([textNode("東京😀", marks: [.object(["type": .string("bold")])])]),
    .node(value: .object(["id": .string("import"), "type": .string("toggle"), "summary": .array([hierarchyRef]), "host": .string("import-meta"),
        "children": .array([.object(["id": .string("child"), "type": .string("paragraph"), "content": .array([textNode("nested")]), "host": .string("child-meta")])])]), kind: "block"),
    .inline([hierarchyRef])])
private func hierarchySession(_ actor: String, version: Int = 6) throws -> WritingSession {
    let source: JSONValue = .object(["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("ab")]), "host": .string("start-meta")])
    let endpoint: JSONValue = .object(["id": .string("q"), "type": .string("paragraph"), "content": .array([hierarchyRef, textNode("cd", marks: [.object(["type": .string("italic")])])]), "host": .string("end-meta")])
    let baseline = try Document(blocks: [
        Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([textNode("left")]), "host": .string("left-meta"),
            "children": .array([source, .object(["id": .string("gone"), "type": .string("toggle"), "summary": .array([textNode("gone")]), "children": .array([]), "host": .string("gone-meta")])])]),
        Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([textNode("selected ancestor")]), "host": .string("right-meta"), "children": .array([
            .object(["id": .string("before"), "type": .string("paragraph"), "content": .array([textNode("before")])]), endpoint,
            .object(["id": .string("after"), "type": .string("paragraph"), "content": .array([textNode("after")])])])])])
    return try WritingSession(documentID: "hierarchy", actorID: actor, epoch: "e", document: baseline, protocolVersion: version)
}
private let hierarchyStart = TextAddress("left", path: ["children", "p", "content"])
private let hierarchyEnd = TextAddress("right", path: ["children", "q", "content"])

@Test(arguments: ["a", "z"], [false, true])
func hierarchicalPasteKeepsOriginalCollectionsAndWholeImportedMetadata(actor: String, reversed: Bool) throws {
    let a = try hierarchySession(actor), b = try hierarchySession("m")
    let startOwner = try a.node(at: NodeAddress("left", path: ["children", "p"]))
    let endOwner = try a.node(at: NodeAddress("right", path: ["children", "q"]))
    let lower = try a.position(at: hierarchyStart, offset: 1), upper = try a.position(at: hierarchyEnd, offset: 4)
    _ = try b.replaceText(at: hierarchyStart, range: 2..<2, with: "X")
    _ = try b.replaceText(at: hierarchyEnd, range: 6..<6, with: "R")
    let caret = try a.pasteSelection(hierarchyClipboard, replacing: WritingTextRange(start: reversed ? upper : lower, end: reversed ? lower : upper))
    #expect(a.changes().changes.count == 1)
    let own = a.changes(), peer = b.changes()
    try a.receive(peer); try b.receive(own); try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document)
    #expect(try a.node(at: NodeAddress("left", path: ["children", "p"])) == startOwner)
    #expect(try a.node(at: NodeAddress("right", path: ["children", "q"])) == endOwner)
    #expect(try a.text(at: hierarchyStart) == "a東京😀X")
    #expect(try a.text(at: hierarchyEnd) == "TaskcdR")
    #expect(try a.resolve(caret).offset == 4)
    let left = a.document.blocks[0], right = a.document.blocks[1]
    #expect(left.fields["children"]?.array?.map { $0["id"]?.string } == ["p", "paste-\(actor)-1-1"])
    #expect(left.fields["children"]?.array?.first?["host"] == .string("start-meta"))
    #expect(left.fields["children"]?.array?.last?["host"] == .string("import-meta"))
    #expect(left.fields["children"]?.array?.last?["children"]?.array?.first?["id"] == .string("paste-\(actor)-1-2"))
    #expect(right.fields["children"]?.array?.map { $0["id"]?.string } == ["q", "after"])
    #expect(right.fields["children"]?.array?.first?["host"] == .string("end-meta"))
    #expect(right.fields["summary"] == .array([]) && right.fields["host"] == .string("right-meta"))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    #expect(try reopened.text(at: hierarchyStart) == "abX" && reopened.text(at: hierarchyEnd) == "TaskcdR")
    #expect(reopened.document.blocks[0].fields["children"]?.array?.map { $0["id"]?.string } == ["p", "gone"])
    #expect(reopened.document.blocks[1].fields["children"]?.array?.map { $0["id"]?.string } == ["before", "q", "after"])
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"])
func hierarchicalPasteSingleInlineKeepsBothOpaqueBoundaries(actor: String) throws {
    let baseline = try Document(blocks: [Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("ab")]), "host": .string("p-meta")]),
        Block(fields: ["id": .string("q"), "type": .string("paragraph"), "content": .array([hierarchyRef, textNode("cd")]), "host": .string("q-meta"), "opaqueChildren": .array([.object(["id": .string("opaque"), "payload": .string("keep")])])])])
    let a = try WritingSession(documentID: "metadata-inline", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "metadata-inline", actorID: "m", epoch: "e", document: baseline, protocolVersion: 6)
    let q = try a.node(at: NodeAddress("q"))
    _ = try b.replaceText(at: TextAddress("q"), range: 6..<6, with: "R")
    let caret = try a.pasteSelection(WritingClipboard(parts: [.inline([textNode("東京😀", marks: [.object(["type": .string("bold")])])])]),
        replacing: WritingTextRange(start: a.position(at: TextAddress("p"), offset: 1), end: a.position(at: TextAddress("q"), offset: 4)))
    try a.receive(b.changes()); try b.receive(a.changes()); #expect(a.document == b.document)
    #expect(a.document.blocks.map(\.id) == ["p", "q"])
    #expect(try a.text(at: TextAddress("p")) == "a東京😀" && a.text(at: TextAddress("q")) == "cdR")
    #expect(try a.resolve(caret).offset == 5 && a.resolve(caret).address.identity == a.node(at: NodeAddress("p")))
    #expect(try a.node(at: NodeAddress("q")) == q)
    #expect(a.document.blocks[1].fields["opaqueChildren"] == baseline.blocks[1].fields["opaqueChildren"])
    #expect(a.document.blocks[0].fields["host"] == .string("p-meta") && a.document.blocks[1].fields["host"] == .string("q-meta"))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(try reopened.text(at: TextAddress("p")) == "ab" && reopened.text(at: TextAddress("q")) == "TaskcdR")
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"])
func hierarchicalPasteBoundaryAncestorKeepsChildrenAndForeignDescendants(actor: String) throws {
    let a = try hierarchySession(actor), b = try hierarchySession("m")
    let ancestor = TextAddress("left", path: ["summary"])
    let lower = try a.position(at: ancestor, offset: 2), upper = try a.position(at: hierarchyStart, offset: 1)
    let owner = try b.node(at: NodeAddress("left", path: ["children", "gone"]))
    let child: JSONValue = .object(["id": .string("peer"), "type": .string("paragraph"), "content": .array([hierarchyRef, textNode("😀")]), "host": .string("peer-meta")])
    _ = try b.insertCollectionNodes([child], into: NodeCollection(owner: owner, field: "children"))
    _ = try a.pasteSelection(hierarchyClipboard, replacing: WritingTextRange(start: lower, end: upper))
    #expect(try a.text(at: ancestor) == "le東京😀" && a.text(at: hierarchyStart) == "Taskb")
    #expect(a.document.blocks[0].fields["children"]?.array?.map { $0["id"]?.string } == ["paste-\(actor)-1-1", "p", "gone"])
    try a.receive(b.changes()); try b.receive(a.changes()); #expect(a.document == b.document)
    #expect(try a.text(at: TextAddress("left", path: ["children", "gone", "children", "peer", "content"])) == "Task😀")
    #expect(a.document.blocks[0].fields["host"] == .string("left-meta"))
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(try reopened.text(at: ancestor) == "left" && reopened.text(at: hierarchyStart) == "ab")
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test(arguments: ["a", "z"])
func hierarchicalPasteDeletesOnlyObservedIntermediateSubtrees(actor: String) throws {
    let a = try hierarchySession(actor), b = try hierarchySession("m")
    let owner = try b.node(at: NodeAddress("left", path: ["children", "gone"]))
    let child: JSONValue = .object(["id": .string("peer"), "type": .string("paragraph"), "content": .array([hierarchyRef, textNode("😀")]), "host": .string("peer-meta")])
    _ = try b.insertCollectionNodes([child], into: NodeCollection(owner: owner, field: "children"))
    let identity = try b.node(at: NodeAddress("left", path: ["children", "gone", "children", "peer"]))
    _ = try a.pasteSelection(hierarchyClipboard, replacing: WritingTextRange(start: a.position(at: hierarchyStart, offset: 1), end: a.position(at: hierarchyEnd, offset: 4)))
    try a.receive(b.changes()); try b.receive(a.changes()); try a.receive(b.changes()); #expect(a.document == b.document)
    #expect(try a.node(at: NodeAddress("left", path: ["children", "gone", "children", "peer"])) == identity)
    #expect(try a.text(at: TextAddress("left", path: ["children", "gone", "children", "peer", "content"])) == "Task😀")
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(try reopened.node(at: NodeAddress("left", path: ["children", "gone", "children", "peer"])) == identity)
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == accepted && b.document == accepted)
}

@Test func hierarchicalPasteOldEpochAndIncompatibleKindRejectAtomically() throws {
    let old = try hierarchySession("a", version: 5)
    let before = try old.save(), receipt = old.syncState
    #expect(throws: EditorError.invalidPath) { try old.pasteSelection(hierarchyClipboard,
        replacing: WritingTextRange(start: old.position(at: hierarchyStart, offset: 1), end: old.position(at: hierarchyEnd, offset: 4))) }
    #expect(try old.save() == before && old.syncState == receipt)
    let next = try hierarchySession("a"), saved = try next.save(), received = next.syncState
    let cell: JSONValue = .object(["id": .string("cell"), "content": .array([textNode("cell")])])
    #expect(throws: EditorError.invalidPath) { try next.pasteSelection(WritingClipboard(parts: [.node(value: cell, kind: "cell")]),
        replacing: WritingTextRange(start: next.position(at: hierarchyStart, offset: 1), end: next.position(at: hierarchyEnd, offset: 4))) }
    #expect(try next.save() == saved && next.syncState == received)
}

@Test(arguments: ["a", "z"], [false, true])
func hierarchicalPasteNestedImportsAndParentEnterKeepIndependentCollections(actor: String, reversedDelivery: Bool) throws {
    let bold: [JSONValue] = [.object(["type": .string("bold")])]
    let italic: [JSONValue] = [.object(["type": .string("italic")])]
    let endpoint: JSONValue = .object(["id": .string("q"), "content": .array([hierarchyRef, textNode("cd", marks: italic)]),
        "checked": .bool(false), "host": .string("q-meta")])
    let item: JSONValue = .object(["id": .string("p"), "content": .array([textNode("ab")]),
        "checked": .bool(true), "host": .string("p-meta"), "children": .array([endpoint])])
    let baseline = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"),
        "style": .string("todo"), "host": .string("list-meta"), "items": .array([item])])])
    let a = try WritingSession(documentID: "nested-import-enter", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "nested-import-enter", actorID: "m", epoch: "e", document: baseline, protocolVersion: 6)
    let start = TextAddress("list", path: ["items", "p", "content"])
    let end = TextAddress("list", path: ["items", "p", "children", "q", "content"])
    let p = try a.node(at: NodeAddress("list", path: ["items", "p"]))
    let q = try a.node(at: NodeAddress("list", path: ["items", "p", "children", "q"]))
    let imported: JSONValue = .object(["id": .string("input"), "content": .array([hierarchyRef, textNode("M", marks: italic)]),
        "checked": .bool(true), "host": .object(["id": .string("opaque-import")]), "children": .array([
            .object(["id": .string("input-child"), "content": .array([textNode("nested😀")]), "host": .string("child-meta")])])])
    let clipboard = WritingClipboard(parts: [.inline([textNode("東京😀", marks: bold)]), .node(value: imported, kind: "item"), .inline([textNode("T😀", marks: bold)])])
    let caret = try a.pasteSelection(clipboard, replacing: WritingTextRange(start: a.position(at: start, offset: 1), end: a.position(at: end, offset: 4)))
    #expect(a.changes().changes.count == 1)
    _ = try b.enterListItem(at: start, range: 1..<1, newItemID: "tail")
    let peerOnly = b.document, own = a.changes(), peer = b.changes()
    if reversedDelivery { try b.receive(own); try a.receive(peer) }
    else { try a.receive(peer); try b.receive(own) }
    try a.receive(peer); try b.receive(own)
    #expect(a.document == b.document && a.mergeRecovery == nil && b.mergeRecovery == nil)
    var expectedImport = imported.object!
    expectedImport["id"] = .string("paste-\(actor)-1-1")
    expectedImport["children"] = .array([.object(["id": .string("paste-\(actor)-1-2"), "content": .array([textNode("nested😀")]), "host": .string("child-meta")])])
    var expectedEnd = endpoint.object!
    expectedEnd["content"] = .array([textNode("T😀", marks: bold), textNode("cd", marks: italic)])
    var expectedStart = item.object!
    expectedStart["content"] = .array([textNode("a"), textNode("東京😀", marks: bold)])
    expectedStart["children"] = .array([.object(expectedImport), .object(expectedEnd)])
    var expectedTail = item.object!
    expectedTail["id"] = .string("tail"); expectedTail["checked"] = .bool(false)
    expectedTail["content"] = .array([]); expectedTail["children"] = .array([])
    let expected = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"),
        "style": .string("todo"), "host": .string("list-meta"), "items": .array([.object(expectedStart), .object(expectedTail)])])])
    #expect(a.document == expected)
    #expect(try a.node(at: NodeAddress("list", path: ["items", "p"])) == p)
    #expect(try a.node(at: NodeAddress("list", path: ["items", "p", "children", "q"])) == q)
    #expect(try a.resolve(caret).address.identity == q && a.resolve(caret).offset == 3)
    let reopened = try WritingSession.restore(a.save(), actorID: actor)
    #expect(reopened.document == expected)
    try reopened.undo(); try b.receive(reopened.changes()); try b.receive(reopened.changes())
    #expect(reopened.document == peerOnly && b.document == peerOnly)
    try reopened.redo(); try b.receive(reopened.changes())
    #expect(reopened.document == expected && b.document == expected)
    // The other author's Enter Undo removes only the parent tail; the imported
    // child chain and original ending owner stay in the original child collection.
    try b.undo(); try reopened.receive(b.changes())
    var pasteOnly = expected.blocks[0].fields
    pasteOnly["items"] = .array([.object(expectedStart)])
    let expectedPasteOnly = try Document(blocks: [Block(fields: pasteOnly)])
    #expect(b.document == expectedPasteOnly && reopened.document == expectedPasteOnly)
    try b.redo(); try reopened.receive(b.changes())
    #expect(b.document == expected && reopened.document == expected)
}

@Test(arguments: ["a", "z"], [false, true])
func hierarchicalPasteConcurrentImportsUseRetainedRankInSameChildCollection(actor: String, reversedDelivery: Bool) throws {
    let italic: [JSONValue] = [.object(["type": .string("italic")])]
    let endpoint: JSONValue = .object(["id": .string("q"), "content": .array([hierarchyRef, textNode("cd", marks: italic)]), "host": .string("q-meta")])
    let source: JSONValue = .object(["id": .string("p"), "content": .array([textNode("ab")]), "checked": .bool(true), "host": .string("p-meta"), "children": .array([endpoint])])
    let baseline = try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "host": .string("list-meta"), "items": .array([source])])])
    let a = try WritingSession(documentID: "two-nested-imports", actorID: actor, epoch: "e", document: baseline, protocolVersion: 6)
    let b = try WritingSession(documentID: "two-nested-imports", actorID: "m", epoch: "e", document: baseline, protocolVersion: 6)
    let start = TextAddress("list", path: ["items", "p", "content"])
    let end = TextAddress("list", path: ["items", "p", "children", "q", "content"])
    let q = try a.node(at: NodeAddress("list", path: ["items", "p", "children", "q"]))
    let first: JSONValue = .object(["id": .string("input-A"), "content": .array([hierarchyRef, textNode("A😀", marks: italic)]), "checked": .bool(true), "host": .string("first-meta")])
    let second: JSONValue = .object(["id": .string("input-B"), "content": .array([textNode("東京B", marks: italic)]), "checked": .bool(false), "host": .string("second-meta")])
    _ = try a.pasteSelection(WritingClipboard(parts: [.node(value: first, kind: "item")]), replacing: WritingTextRange(start: a.position(at: start, offset: 1), end: a.position(at: end, offset: 4)))
    _ = try b.pasteSelection(WritingClipboard(parts: [.node(value: second, kind: "item")]), replacing: WritingTextRange(start: b.position(at: start, offset: 2), end: b.position(at: end, offset: 5)))
    let own = a.changes(), peer = b.changes()
    if reversedDelivery { try b.receive(own); try a.receive(peer) }
    else { try a.receive(peer); try b.receive(own) }
    try a.receive(peer); try b.receive(own)
    var importedFirst = first.object!, importedSecond = second.object!
    importedFirst["id"] = .string("paste-\(actor)-1-1"); importedSecond["id"] = .string("paste-m-1-1")
    func expected(_ includeFirst: Bool, _ includeSecond: Bool) throws -> Document {
        var q = endpoint.object!, p = source.object!
        q["content"] = .array([textNode(includeSecond ? "d" : "cd", marks: italic)])
        p["content"] = .array([textNode(includeFirst ? "a" : "ab")])
        p["children"] = .array((includeFirst ? [.object(importedFirst)] : []) + (includeSecond ? [.object(importedSecond)] : []) + [.object(q)])
        return try Document(blocks: [Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "host": .string("list-meta"), "items": .array([.object(p)])])])
    }
    let combined = try expected(true, true)
    #expect(a.document == combined && b.document == combined && a.mergeRecovery == nil && b.mergeRecovery == nil)
    #expect(try a.node(at: NodeAddress("list", path: ["items", "p", "children", "q"])) == q)
    let reopened = try WritingSession.restore(a.save(), actorID: actor)
    #expect(reopened.document == combined)
    try reopened.undo(); try b.receive(reopened.changes()); #expect(try reopened.document == expected(false, true) && b.document == expected(false, true))
    try reopened.redo(); try b.receive(reopened.changes()); #expect(reopened.document == combined && b.document == combined)
    try b.undo(); try reopened.receive(b.changes()); #expect(try b.document == expected(true, false) && reopened.document == expected(true, false))
    try b.redo(); try reopened.receive(b.changes()); #expect(reopened.document == combined && b.document == combined)
}

@Test(arguments: ["a", "z"], [false, true])
func hierarchicalPasteForeignMovedImportRetainsPeerWorkThroughAuthorUndo(actor: String, acrossContainer: Bool) throws {
    let a = try hierarchySession(actor), b = try hierarchySession("m")
    let baseline = a.document
    _ = try a.pasteSelection(hierarchyClipboard, replacing: WritingTextRange(start: a.position(at: hierarchyStart, offset: 1), end: a.position(at: hierarchyEnd, offset: 4)))
    try b.receive(a.changes())
    let label = "paste-\(actor)-1-1", childLabel = "paste-\(actor)-1-2"
    let imported = try b.node(at: NodeAddress("left", path: ["children", label]))
    if acrossContainer {
        try b.move(WritingSelection(nodes: [imported]), into: .root, after: b.node(at: NodeAddress("right")))
    } else {
        try b.move(WritingSelection(nodes: [imported]), into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"), after: b.node(at: NodeAddress("right", path: ["children", "q"])))
    }
    let importAddress = try b.textAddress(of: imported, field: "summary")
    _ = try b.replaceText(at: importAddress, range: 4..<4, with: "X")
    let peerChild: JSONValue = .object(["id": .string("peer-child"), "type": .string("paragraph"), "content": .array([hierarchyRef, textNode("東京😀")]), "host": .object(["id": .string("peer-opaque")])])
    let oldChild = try b.node(at: acrossContainer ? NodeAddress(label, path: ["children", childLabel]) : NodeAddress("right", path: ["children", label, "children", childLabel]))
    _ = try b.insertCollectionNodes([peerChild], into: NodeCollection(owner: imported, field: "children"), after: oldChild)
    let peerIdentity = try b.node(at: acrossContainer ? NodeAddress(label, path: ["children", "peer-child"]) : NodeAddress("right", path: ["children", label, "children", "peer-child"]))
    try a.receive(b.changes()); try a.receive(b.changes())
    #expect(a.document == b.document && a.mergeRecovery == nil)
    #expect(try a.address(of: imported) == (acrossContainer ? NodeAddress(label) : NodeAddress("right", path: ["children", label])))
    #expect(try a.text(at: a.textAddress(of: imported, field: "summary")) == "TaskX")
    let accepted = a.document, reopened = try WritingSession.restore(a.save(), actorID: actor)
    try reopened.undo(); try b.receive(reopened.changes()); try b.receive(reopened.changes())
    var keptImport: [String: JSONValue] = ["id": .string(label), "type": .string("toggle"), "summary": .array([textNode("X")]), "host": .string("import-meta"), "children": .array([peerChild])]
    var undoBlocks = baseline.blocks
    if acrossContainer { undoBlocks.append(try Block(fields: keptImport)) }
    else {
        var right = undoBlocks[1].fields, children = right["children"]!.array!
        children.insert(.object(keptImport), at: 2); right["children"] = .array(children); undoBlocks[1] = try Block(fields: right)
    }
    let expectedUndo = try Document(blocks: undoBlocks)
    #expect(reopened.document == expectedUndo && b.document == expectedUndo)
    #expect(try reopened.node(at: reopened.address(of: imported)) == imported)
    #expect(try reopened.node(at: acrossContainer ? NodeAddress(label, path: ["children", "peer-child"]) : NodeAddress("right", path: ["children", label, "children", "peer-child"])) == peerIdentity)
    let restartedUndo = try WritingSession.restore(reopened.save(), actorID: actor)
    #expect(restartedUndo.document == expectedUndo)
    try restartedUndo.redo(); try b.receive(restartedUndo.changes())
    #expect(restartedUndo.document == accepted && b.document == accepted)
    #expect(try restartedUndo.address(of: imported) == (acrossContainer ? NodeAddress(label) : NodeAddress("right", path: ["children", label])))
    keptImport["summary"] = .array([hierarchyRef, textNode("X")])
    keptImport["children"] = .array([.object(["id": .string(childLabel), "type": .string("paragraph"), "content": .array([textNode("nested")]), "host": .string("child-meta")]), peerChild])
    let actualImport = acrossContainer ? accepted.blocks.last!.fields : accepted.blocks[1].fields["children"]!.array![1].object!
    #expect(actualImport == keptImport)
}
