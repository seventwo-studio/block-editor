@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernColumnTests {
    private func fixture(_ name: String) throws -> ModernDocument {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/acceptance/modern-editor/documents/" + name + ".json")
        return try ModernDocument(json: Data(contentsOf: path))
    }
    private func session(_ actor: String, _ name: String) throws -> ModernSession {
        let document = try fixture(name)
        return try ModernSession(documentID: document.documentID, actorID: actor, epoch: "modern-1", document: document)
    }
    private func emptyLayout() throws -> JSONValue {
        var fields = try fixture("columns-created").blocks[0].fields
        fields["columns"] = .array(fields["columns"]!.array!.map { column in
            var fields = column.object!; fields["children"] = .array([]); return .object(fields)
        })
        return .object(fields)
    }
    private func id(_ label: String) -> NodeID { .baseline(blockID: label, path: []) }
    private func second(_ a: ModernSession, layout: NodeID? = nil) throws -> NodeCollection {
        NodeCollection(owner: try modernColumnIDs(layout ?? id("layout"), in: a.structure)[1], field: "children")
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }
    private func create(_ a: ModernSession, caret: WritingPosition? = nil) throws -> NodeID {
        let target = ModernCreateColumnsTarget(selection: try a.captureNodes([id("A"), id("B")]), caret: caret)
        let outcome = try a.createColumns(target, layout: emptyLayout())
        guard case .nodes(let nodes) = outcome.selection else { throw EditorError.invalidChange }; return nodes.nodes[0]
    }

    @Test func creationMatchesIndependentFixtureAndKeepsCaretOriginsOneUndoAndReopen() throws {
        let a = try session("a", "before-columns"), field = try a.field(node: id("A")), caret = try a.position(in: field, offset: 1)
        let layout = try create(a, caret: caret)
        #expect(a.document == (try fixture("columns-created")))
        #expect(try a.resolve(caret).offset == 1 && a.address(of: id("A")) == NodeAddress("layout", path: ["columns", "first-column", "children", "A"]))
        #expect(a.syncState.received.count == 1)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); #expect(reopened.document == (try fixture("before-columns")))
        #expect(!reopened.canUndo)
        try reopened.redo(); #expect(reopened.document == (try fixture("columns-created")))
        #expect(try reopened.node(at: NodeAddress("layout")) == layout)
    }
    @Test func creationUndoFlattensPeerChildrenAfterRestoredSelectionAndRetainsHistoricalAnchors() throws {
        let a = try session("a", "before-columns"), b = try session("b", "before-columns"), layout = try create(a)
        try b.receive(a.changes())
        let d = try b.insertBlock(Block(fields: fixture("columns-create-peer").blocks[0].fields["columns"]!.array![1]["children"]!.array![0].object!), into: second(b, layout: layout))
        try a.receive(b.changes()); #expect(a.document == (try fixture("columns-create-peer")))
        try a.undo(); #expect(a.document == (try fixture("columns-create-undone-peer")))
        let x = try a.insertBlock(Block.paragraph(id: "X", text: "Outside"), after: d)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        try reopened.undo(); try reopened.redo()
        // Undo/Redo of X keeps the creation undone; the historical route survives reopen.
        #expect(reopened.document.blocks.map(\.id) == ["A", "B", "D", "X", "C", "E"])
        #expect(try reopened.node(at: NodeAddress("X")) == x)
        try b.receive(reopened.changes()); #expect(b.document == reopened.document)
    }
    @Test func emptyCreationHasNoPlaceholderAndAllowsOutsideLayoutNestedBoundaries() throws {
        let a = try session("a", "before-columns")
        let boundary = try a.captureBoundary(in: NodeCollection(owner: id("B"), field: "children"))
        let outcome = try a.createColumns(ModernCreateColumnsTarget(boundary: boundary), layout: emptyLayout())
        guard case .nodes(let selected) = outcome.selection else { throw EditorError.invalidChange }
        let columns = try modernColumnIDs(selected.nodes[0], in: a.structure)
        #expect(try a.nodes(in: NodeCollection(owner: columns[0], field: "children")).isEmpty)
        #expect(try a.nodes(in: NodeCollection(owner: columns[1], field: "children")).isEmpty)
        try a.undo(); #expect(a.document == (try fixture("before-columns")))
    }
    @Test func removalMatchesFlattenedFixtureRestoresSplitAndCaretAndRoutesLatePeerPackets() throws {
        for peerFirst in [false, true] {
            let a = try session("a", "columns-3000"), b = try session("b", "columns-3000")
            let field = try b.field(node: b.node(at: NodeAddress("layout", path: ["columns", "first-column", "children", "A"]))); try b.format(in: field, range: 0..<3, markType: "bold", mark: nil)
            try b.replaceText(in: field, range: 3..<3, with: " remote")
            _ = try b.insertBlock(Block(fields: fixture("columns-peer-child").blocks[0].fields["columns"]!.array![1]["children"]!.array![1].object!), into: second(b), after: b.node(at: NodeAddress("layout", path: ["columns", "second-column", "children", "C"])))
            let aField = try a.field(node: a.node(at: NodeAddress("layout", path: ["columns", "first-column", "children", "A"])))
            let caret = try a.position(in: aField, offset: 1)
            if peerFirst { try a.receive(b.changes()) }
            _ = try a.removeColumns(ModernColumnTarget(layout: id("layout"), caret: caret))
            if !peerFirst { #expect(a.document == (try fixture("columns-flattened"))); try a.receive(b.changes()) }
            try b.receive(a.changes())
            #expect(a.document == (try fixture("columns-flat-peer")) && a.document == b.document)
            #expect(try a.resolve(caret).offset == 1)
            let restored = try ModernSession.restore(a.save(), actorID: "a")
            try restored.undo(); #expect(restored.document == (try fixture("columns-peer-child")))
            try restored.redo(); #expect(restored.document == (try fixture("columns-flat-peer")))
            try restored.receive(b.changes()); #expect(restored.document == (try fixture("columns-flat-peer")))
        }
    }
    @Test func removalDoesNotOverrideIndependentPeerMoveAndConcurrentRemovalsNeverDuplicate() throws {
        let a = try session("a", "columns-3000"), b = try session("b", "columns-3000")
        let d = try b.insertBlock(Block(fields: fixture("columns-peer-child").blocks[0].fields["columns"]!.array![1]["children"]!.array![1].object!), into: second(b))
        try b.move(d, into: .root, after: id("E"))
        _ = try a.removeColumns(ModernColumnTarget(layout: id("layout"))); try exchange(a, b)
        #expect(a.document.blocks.map(\.id) == ["A", "B", "C", "E", "D"] && a.document == b.document)
        try a.undo(); #expect(a.document.blocks.map(\.id) == ["layout", "E", "D"])
        let c = try session("c", "columns-3000"), e = try session("e", "columns-3000")
        _ = try c.removeColumns(ModernColumnTarget(layout: id("layout"))); _ = try e.removeColumns(ModernColumnTarget(layout: id("layout")))
        try exchange(c, e); #expect(c.document == (try fixture("columns-flattened")) && c.document == e.document)
        try e.undo(); try exchange(c, e); #expect(c.document == (try fixture("columns-flattened")))
        try c.undo(); try exchange(c, e); #expect(c.document == (try fixture("columns-3000")) && c.document == e.document)
    }
    @Test func removalUndoKeepsInsertionsAnchoredAfterPreviouslyFlattenedChildOutsideLayout() throws {
        let a = try session("a", "columns-3000"), b = try session("b", "columns-3000")
        _ = try a.removeColumns(ModernColumnTarget(layout: id("layout"))); try b.receive(a.changes())
        let c = try b.node(at: NodeAddress("C"))
        _ = try b.insertBlock(Block.paragraph(id: "X", text: "Outside"), after: c)
        try a.receive(b.changes()); #expect(a.document.blocks.map(\.id) == ["A", "B", "C", "X", "E"])
        try a.undo(); #expect(a.document.blocks.map(\.id) == ["layout", "X", "E"])
        try b.receive(a.changes()); #expect(a.document == b.document)
        try a.redo(); #expect(a.document.blocks.map(\.id) == ["A", "B", "C", "X", "E"])
    }
    @Test func synchronizedResizeLWWAuthorUndoReopenAndNoopMatchIndependentSnapshots() throws {
        let a = try session("a", "columns-5000"), b = try session("b", "columns-5000"), target = ModernColumnTarget(layout: id("layout"))
        _ = try a.resizeColumns(target, splitBasisPoints: 6000); _ = try b.resizeColumns(target, splitBasisPoints: 4000)
        try exchange(a, b); #expect(a.document == (try fixture("columns-split-b")) && a.document == b.document)
        let unchanged = try a.save(); _ = try a.resizeColumns(target, splitBasisPoints: 4000); #expect(try a.save() == unchanged)
        let reopened = try ModernSession.restore(b.save(), actorID: "b")
        try reopened.undo(); try a.receive(reopened.changes()); #expect(a.document == (try fixture("columns-split-a")))
        try a.undo(); try reopened.receive(a.changes()); #expect(a.document == (try fixture("columns-5000")) && a.document == reopened.document)
        try a.redo(); try reopened.receive(a.changes()); try reopened.redo(); try a.receive(reopened.changes())
        #expect(a.document == (try fixture("columns-split-b")) && a.document == reopened.document)
    }
    @Test func invalidNestedAndNoncontiguousCreationAndSplitDoNotChangeSavedHistory() throws {
        let a = try session("a", "before-columns"), selection = try a.captureNodes([id("A"), id("C")]), before = try a.save()
        #expect(throws: EditorError.invalidPath) { try a.createColumns(ModernCreateColumnsTarget(selection: selection), layout: emptyLayout()) }
        #expect(try a.save() == before)
        let layout = try create(a), column = try second(a, layout: layout), boundary = try a.captureBoundary(in: column)
        let saved = try a.save()
        #expect(throws: EditorError.invalidPath) { try a.createColumns(ModernCreateColumnsTarget(boundary: boundary), layout: emptyLayout()) }
        for split in [999, 9001] { #expect(throws: EditorError.invalidChange) { try a.resizeColumns(ModernColumnTarget(layout: layout), splitBasisPoints: split) } }
        #expect(try a.save() == saved)
    }
    @Test func conflictingFlattenedLabelsRetainUnionUntilAuthorRepairInsteadOfLosingPeerChild() throws {
        let a = try session("a", "columns-3000"), b = try session("b", "columns-3000")
        _ = try a.removeColumns(ModernColumnTarget(layout: id("layout")))
        _ = try b.insertBlock(Block.paragraph(id: "E", text: "Peer duplicate scoped label"), into: second(b))
        let saved = try a.save(), received = a.syncState
        #expect(throws: ModernSessionError.self) { try a.receive(b.changes()) }
        #expect(a.syncState == received); #expect(try a.save() == saved)
        #expect(a.mergeRecovery != nil)
        try a.repairUndo([ChangeID(counter: 1, actor: "a")])
        #expect(a.document.blocks.map(\.id) == ["layout", "E"] && a.mergeRecovery == nil)
        #expect(a.document.blocks[0].fields["columns"]?.array?[1]["children"]?.array?.first?["content"]?.array?.first?["text"] == .string("Peer duplicate scoped label"))
    }
    @Test func modernColumnRoutesRejectAtEveryLegacyProtocolWithoutReceiptOrSaveChanges() throws {
        let document = try Document(blocks: [Block.paragraph(id: "p", text: "Legacy")])
        let edit = ChangeID(counter: 1, actor: "peer")
        let route = NodePlacementID.columnRoute(layout: id("layout"), slot: ElementID(change: edit, index: 0), node: id("child"))
        let mutation = Mutation.moveNode(identity: id("p"), collection: .root, placement: ElementID(change: edit, index: 1), after: route)
        let legacy = try EditorSession(documentID: "legacy", actorID: "a", document: document, collaborationVersion: 2)
        let saved = try legacy.save(), receipt = legacy.syncState
        #expect(throws: EditorError.self) { try legacy.receive(ChangeBatch(documentID: "legacy", baseline: document,
            changes: [Change(id: edit, body: .edit([mutation]))], version: 2)) }
        #expect(legacy.syncState == receipt); #expect(try legacy.save() == saved)
        for version in 3...6 {
            let writing = try WritingSession(documentID: "legacy", actorID: "a", epoch: "legacy-1", document: document, protocolVersion: version)
            let saved = try writing.save(), receipt = writing.syncState
            let change = WritingChange(id: edit, body: .edit([.structure(mutation)]), observed: [])
            #expect(throws: EditorError.self) { try writing.receive(WritingBatch(documentID: "legacy", epoch: "legacy-1", baseline: document, changes: [change], version: version)) }
            #expect(writing.syncState == receipt); #expect(try writing.save() == saved)
        }
    }
    @Test func malformedInactiveColumnOperationAndCausallyRemovedTargetsReject() throws {
        let a = try session("a", "before-columns"), edit = ChangeID(counter: 1, actor: "peer")
        var layout = try emptyLayout().object!
        layout["columns"] = .array(layout["columns"]!.array! + [.object(["id": .string("third"), "children": .array([])])])
        let placement = ElementID(change: edit, index: 0)
        let creation = ModernColumnCreation(layout: .object(layout), identity: .inserted(creation: placement, path: []), collection: .root, placement: placement, after: nil, nodes: [], sources: [])
        let malformed = ModernChange(id: edit, observed: [], body: .edit([.createColumns(creation)]))
        let disabled = ModernChange(id: ChangeID(counter: 2, actor: "peer"), observed: [edit], body: .setActive(targets: [edit], active: false))
        let saved = try a.save()
        #expect(throws: EditorError.self) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [malformed, disabled])) }
        #expect(try a.save() == saved)
        let b = try session("b", "columns-3000")
        _ = try b.removeColumns(ModernColumnTarget(layout: id("layout")))
        let before = try b.save(), removal = ChangeID(counter: 1, actor: "b")
        let bad = ModernChange(id: ChangeID(counter: 2, actor: "peer"), observed: [removal], body: .edit([.resizeColumns(layout: id("layout"), splitBasisPoints: 6000)]))
        #expect(throws: EditorError.self) { try b.receive(ModernBatch(documentID: b.documentID, epoch: b.epoch, baseline: b.baseline, changes: [bad])) }
        #expect(try b.save() == before)
    }
    @Test func resizePacketBeforeLayoutBirthRetainsRecoveryThenConvergesWithoutPromotingReceipt() throws {
        let a = try session("a", "before-columns"), b = try session("b", "before-columns"), layout = try create(a)
        let birth = a.syncState
        _ = try a.resizeColumns(ModernColumnTarget(layout: layout), splitBasisPoints: 7000)
        let before = try b.save(), receipt = b.syncState
        #expect(throws: ModernSessionError.self) { try b.receive(a.changes(since: birth)) }
        #expect(b.syncState == receipt); #expect(try b.save() == before)
        try b.receive(a.changes()); #expect(b.document == a.document && b.mergeRecovery == nil)
    }

}
