@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernCommandTargetsTests {
    private func session(_ actor: String, document: ModernDocument? = nil) throws -> ModernSession {
        let document = try document ?? ModernDocument(documentID: "modern", title: "Title", blocks: [Block.paragraph(id: "a", text: "abcd"), Block.paragraph(id: "b", text: "efgh"), Block.paragraph(id: "c", text: "ijkl")])
        return try ModernSession(documentID: document.documentID, actorID: actor, epoch: "modern-1", document: document)
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }
    private func node(_ label: String, in session: ModernSession) throws -> NodeID { try session.node(at: NodeAddress(label)) }
    private func field(_ label: String, in session: ModernSession) throws -> WritingField { try session.field(node: node(label, in: session)) }
    private func textFocus(_ result: ModernStructuralResult) throws -> WritingPosition {
        guard case .text(let position) = result.focus else { throw EditorError.invalidPath }; return position
    }
    private func layout() throws -> Block {
        try Block(fields: ["id": .string("layout"), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array([
            .object(["id": .string("left"), "children": .array([])]), .object(["id": .string("right"), "children": .array([])])])])
    }

    @Test func capturedRootBoundarySurvivesAnchorMoveAndDeletionWithoutRetargeting() throws {
        let doc = try ModernDocument(documentID: "modern", title: "Title", blocks: [Block.paragraph(id: "a", text: "A"), layout(), Block.paragraph(id: "b", text: "B")])
        let a = try session("a", document: doc), b = try session("b", document: doc), original = try node("a", in: a)
        let boundary = try a.captureBoundary(after: original)
        let left = try b.node(at: NodeAddress("layout", path: ["columns", "left"]))
        try b.move(original, into: NodeCollection(owner: left, field: "children")); try a.receive(b.changes())
        let inserted = try a.insertBlock(Block.paragraph(id: "x", text: "New"), at: boundary)
        #expect(a.document.blocks.map(\.id) == ["x", "layout", "b"])
        #expect(try a.resolve(textFocus(inserted)).offset == 0)
        #expect(try a.address(of: textFocus(inserted).field.node) == NodeAddress("x"))
        let anchor = try node("b", in: a), captured = try a.captureBoundary(after: anchor)
        try a.delete(anchor)
        _ = try a.insertBlock(Block.paragraph(id: "y", text: "Last"), at: captured)
        #expect(a.document.blocks.map(\.id) == ["x", "layout", "y"])
    }

    @Test func insertChoosesFirstEditableNestedFieldOrWholeNodeAndUndoesOnce() throws {
        let a = try session("a"), boundary = try a.captureBoundary()
        let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("unordered"), "items": .array([
            .object(["id": .string("item"), "content": .array([textNode("Item")])])])])
        let result = try a.insertBlock(list, at: boundary), caret = try textFocus(result)
        #expect(try a.address(of: caret.field.node) == NodeAddress("list", path: ["items", "item"]))
        #expect(try a.resolve(caret).offset == 0)
        try a.undo(); #expect(a.document == a.baseline)
        let divider = try Block(fields: ["id": .string("divider"), "type": .string("divider"), "opaque": .string("kept")])
        let whole = try a.insertBlock(divider, at: boundary)
        guard case .nodes(let selected) = whole.selection else { throw EditorError.invalidPath }
        #expect(try a.address(of: selected.nodes[0]) == NodeAddress("divider"))
        #expect(whole.focus == .nodes(selected) && a.document.blocks.first?.fields["opaque"] == .string("kept"))
    }

    @Test func multiMovePreservesCapturedOrderCaretAndPeerTextAsOneUndo() throws {
        let a = try session("a"), b = try session("b")
        let first = try node("a", in: a), second = try node("b", in: a), last = try node("c", in: a)
        let selection = try a.captureNodes([first, second]), boundary = try a.captureBoundary(after: last)
        let caret = try a.position(in: field("a", in: a), offset: 2, affinity: .after)
        try b.replaceText(in: field("a", in: b), range: 4..<4, with: " peer"); try a.receive(b.changes())
        let result = try a.move(ModernMoveTarget(selection: selection, boundary: boundary, caret: caret))
        #expect(a.document.blocks.map(\.id) == ["c", "a", "b"])
        #expect(try a.resolve(textFocus(result)).offset == 2)
        #expect(result.selection == .nodes(ModernNodeSelection(documentID: "modern", epoch: "modern-1", nodes: [first, second], observed: a.modernObserved)))
        let edits = try a.changes().changes.filter { $0.id.actor == "a" }
        #expect(edits.count == 1)
        guard case .edit(let operations) = edits[0].body else { throw EditorError.invalidChange }
        #expect(operations.count == 2)
        try a.undo(); #expect(a.document.blocks.map(\.id) == ["a", "b", "c"] && a.document.blocks[0].text == "abcd peer")
        try a.redo(); try b.receive(a.changes()); #expect(a.document == b.document)
        let saved = try a.save()
        _ = try a.move(ModernMoveTarget(selection: a.captureNodes([first, second]), boundary: a.captureBoundary(after: last), caret: caret))
        #expect(try a.save() == saved)
    }

    @Test func mixedDeletePreservesLaterPeerAtomsAndIndependentTextWithOneUndo() throws {
        let a = try session("a"), b = try session("b")
        let selected = try a.captureNodes([node("b", in: a)])
        let range = try a.captureTextRange(in: field("a", in: a), start: 3, end: 1)
        try b.replaceText(in: field("a", in: b), range: 2..<2, with: "X")
        try b.replaceText(in: field("c", in: b), range: 4..<4, with: " peer")
        try a.receive(b.changes())
        let before = a.document, result = try a.delete(ModernDeleteTarget(nodes: selected, ranges: [range]))
        #expect(a.document.blocks.map(\.id) == ["a", "c"] && a.document.blocks[0].text == "aXd" && a.document.blocks[1].text == "ijkl peer")
        #expect(try a.resolve(textFocus(result)).offset == 1)
        #expect(try a.changes().changes.filter { $0.id.actor == "a" }.count == 1)
        try a.undo(); #expect(a.document == before)
        try a.redo(); try b.receive(a.changes()); #expect(a.document == b.document)
    }

    @Test func deleteReturnsFollowingThenPrecedingTextOrEmptyInsertionWithoutPlaceholder() throws {
        let a = try session("a")
        let middle = try a.delete(ModernDeleteTarget(nodes: a.captureNodes([node("b", in: a)])))
        #expect(try textFocus(middle).field == field("c", in: a))
        #expect(try a.resolve(textFocus(middle)).offset == 0)
        let last = try a.delete(ModernDeleteTarget(nodes: a.captureNodes([node("c", in: a)])))
        #expect(try textFocus(last).field == field("a", in: a))
        #expect(try a.resolve(textFocus(last)).offset == 4)
        let empty = try a.delete(ModernDeleteTarget(nodes: a.captureNodes([node("a", in: a)])))
        guard case .insertion(let boundary) = empty.focus else { throw EditorError.invalidPath }
        #expect(a.document.blocks.isEmpty && empty.selection == nil && a.document.title == "Title")
        #expect(boundary.collection == .root && boundary.after == nil)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        _ = try reopened.insertBlock(Block.paragraph(id: "fresh", text: "Writing"), at: boundary)
        #expect(reopened.document.blocks.map(\.id) == ["fresh"])
    }

    @Test func readOnlyBodyFallbackUsesTitleAndCoveredRangesDoNotDuplicateDeletion() throws {
        let divider = try Block(fields: ["id": .string("divider"), "type": .string("divider")])
        let doc = try ModernDocument(documentID: "modern", title: "Title", blocks: [Block.paragraph(id: "a", text: "A"), divider])
        let a = try session("a", document: doc), selected = try a.captureNodes([node("a", in: a)])
        let range = try a.captureTextRange(in: field("a", in: a), start: 0, end: 1)
        let result = try a.delete(ModernDeleteTarget(nodes: selected, ranges: [range]))
        #expect(try textFocus(result).field == a.titleField)
        #expect(try a.resolve(textFocus(result)).offset == 5)
        guard case .edit(let operations) = try a.changes().changes[0].body else { throw EditorError.invalidChange }
        #expect(operations.count == 1)
    }

    @Test func staleSelectionScopeForgedBoundaryWrongOrderAndForeignCaretRejectAtomically() throws {
        let a = try session("a"), selected = try a.captureNodes([node("a", in: a)]), boundary = try a.captureBoundary()
        #expect(throws: EditorError.invalidPath) { try a.captureNodes([node("b", in: a), node("a", in: a)]) }
        #expect(throws: EditorError.invalidPath) { try a.captureNodes([node("a", in: a), node("a", in: a)]) }
        let before = try a.save()
        let foreign = ModernBlockBoundary(documentID: "wrong", epoch: boundary.epoch, collection: .root, after: nil, observed: [])
        #expect(throws: EditorError.differentDocument) { try a.insertBlock(Block.paragraph(id: "x"), at: foreign) }
        let forged = ModernBlockBoundary(documentID: "modern", epoch: "modern-1", collection: .root,
            after: .edit(ElementID(change: ChangeID(counter: 1, actor: "fake"), index: 0)), observed: [])
        #expect(throws: EditorError.invalidPath) { try a.insertBlock(Block.paragraph(id: "x"), at: forged) }
        let caret = try a.position(in: field("b", in: a), offset: 0)
        #expect(throws: EditorError.invalidPath) { try a.move(ModernMoveTarget(selection: selected, boundary: boundary, caret: caret)) }
        #expect(try a.save() == before)
        try a.delete(node("a", in: a)); _ = try a.insertBlock(Block.paragraph(id: "a", text: "replacement"))
        let saved = try a.save()
        #expect(throws: EditorError.invalidPath) { try a.delete(ModernDeleteTarget(nodes: selected)) }
        #expect(try a.save() == saved)
    }

    @Test func ancestorOverlapMetadataAndDeletedColumnDestinationReject() throws {
        let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([textNode("Summary")]), "children": .array([.object(try Block.paragraph(id: "nested", text: "Child").fields)])])
        let doc = try ModernDocument(documentID: "modern", title: "Title", blocks: [toggle, layout()])
        let a = try session("a", document: doc), parent = try node("toggle", in: a), child = try a.node(at: NodeAddress("toggle", path: ["children", "nested"]))
        #expect(throws: EditorError.invalidPath) { try a.captureNodes([parent, child]) }
        #expect(throws: EditorError.invalidPath) { try a.captureNodes([.document(documentID: "modern")]) }
        let title = try a.captureTextRange(in: a.titleField, start: 0, end: 5), before = try a.save()
        #expect(throws: EditorError.invalidPath) { try a.delete(ModernDeleteTarget(ranges: [title])) }
        #expect(try a.save() == before)
        let left = try a.node(at: NodeAddress("layout", path: ["columns", "left"]))
        let boundary = try a.captureBoundary(in: NodeCollection(owner: left, field: "children"))
        try a.delete(node("layout", in: a)); let saved = try a.save()
        #expect(throws: EditorError.invalidPath) { try a.insertBlock(Block.paragraph(id: "new"), at: boundary) }
        #expect(try a.save() == saved)
    }
}
