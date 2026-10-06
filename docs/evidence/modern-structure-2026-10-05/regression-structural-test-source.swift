@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernStructureTests {
    private func session(_ actor: String, document: ModernDocument? = nil) throws -> ModernSession {
        let document = try document ?? ModernDocument(documentID: "modern", title: "A", blocks: [Block.paragraph(id: "p", text: "ab")])
        return try ModernSession(documentID: document.documentID, actorID: actor, epoch: "modern-1", document: document)
    }
    private func layout(_ id: String, childID: String = "p") throws -> Block {
        try Block(fields: ["id": .string(id), "type": .string("columns"), "splitBasisPoints": .number(5000), "columns": .array([
            .object(["id": .string("left"), "children": .array([.object(try Block.paragraph(id: childID, text: "Left").fields)])]),
            .object(["id": .string("right"), "children": .array([])])])])
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes(); try a.receive(second); try b.receive(first)
    }

    @Test func insertedBodyFieldsShareTitleHistoryPeerUndoAndReopen() throws {
        let a = try session("a"), b = try session("b"), p = try a.node(at: NodeAddress("p"))
        let inserted = try a.insertBlock(Block.paragraph(id: "new", text: "seed"), after: p)
        let field = try a.field(node: inserted)
        #expect(try a.text(in: field) == "seed")
        try b.receive(a.changes()); try b.replaceText(in: field, range: 4..<4, with: " peer")
        try a.receive(b.changes()); try a.replaceTitle(range: 0..<0, with: "Title ")
        let restored = try ModernSession.restore(a.save(), actorID: "a")
        try restored.undo(); #expect(restored.document.title == "A")
        try restored.undo(); #expect(try restored.text(in: field) == " peer")
        #expect(restored.document.blocks.map(\.id) == ["p", "new"])
        try restored.redo(); #expect(try restored.text(in: field) == "seed peer")
        try b.receive(restored.changes()); #expect(restored.document == b.document)
        try restored.redo(); #expect(restored.document.title == "Title A")
    }

    @Test func insertionUndoWithoutPeerWorkHidesBirthButDoesNotReuseOrigin() throws {
        let a = try session("a"), identity = try a.insertBlock(Block.paragraph(id: "new", text: "seed"))
        let field = try a.field(node: identity), position = try a.position(in: field, offset: 2)
        try a.undo(); #expect(a.document.blocks.map(\.id) == ["p"])
        #expect(throws: EditorError.invalidPath) { try a.resolve(position) }
        let replacement = try a.insertBlock(Block.paragraph(id: "new", text: "other"))
        #expect(replacement != identity)
        #expect(throws: EditorError.invalidPath) { try a.replaceText(in: field, range: 0..<0, with: "wrong") }
        #expect(a.document.blocks.first?.text == "other")
    }

    @Test func columnMovesKeepScopedOriginsCaretPeerTextAndOneAuthorUndo() throws {
        let doc = try ModernDocument(documentID: "modern", title: "A", blocks: [layout("layout"), Block.paragraph(id: "outside", text: "Root")])
        let a = try session("a", document: doc), b = try session("b", document: doc)
        let child = try a.node(at: NodeAddress("layout", path: ["columns", "left", "children", "p"]))
        let right = try a.node(at: NodeAddress("layout", path: ["columns", "right"]))
        let field = try a.field(node: child), caret = try a.position(in: field, offset: 2)
        try a.move(child, into: NodeCollection(owner: right, field: "children"))
        try b.replaceText(in: field, range: 4..<4, with: " peer")
        try exchange(a, b)
        #expect(a.document == b.document)
        #expect(try a.resolve(caret).offset == 2)
        #expect(try a.address(of: child) == NodeAddress("layout", path: ["columns", "right", "children", "p"]))
        try a.undo(); #expect(try a.address(of: child) == NodeAddress("layout", path: ["columns", "left", "children", "p"]))
        #expect(try a.text(in: field) == "Left peer")
        try a.redo(); try a.move(child, into: .root, after: a.node(at: NodeAddress("outside")))
        #expect(try a.address(of: child) == NodeAddress("p"))
        #expect(try a.resolve(caret).offset == 2)
        #expect(a.document.blocks.last?.text == "Left peer")
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        #expect(reopened.document == a.document)
        #expect(try reopened.address(of: child) == NodeAddress("p"))
    }

    @Test func deletionRetainsPeerHistoryAndStaleTargetsCannotHitReusedLabels() throws {
        let doc = try ModernDocument(documentID: "modern", title: "A", blocks: [Block.paragraph(id: "p", text: "ab"), Block.paragraph(id: "q", text: "safe")])
        let a = try session("a", document: doc), b = try session("b", document: doc)
        let p = try a.node(at: NodeAddress("p")), q = try a.node(at: NodeAddress("q"))
        let field = try a.field(node: p), captured = try a.captureTextRange(in: field, start: 0, end: 1)
        try a.delete(p); try b.replaceText(in: field, range: 2..<2, with: " peer")
        try b.replaceText(in: b.field(node: q), range: 4..<4, with: "!")
        try exchange(a, b)
        #expect(a.document == b.document && a.document.blocks.map(\.id) == ["q"] && a.document.blocks[0].text == "safe!")
        #expect(throws: EditorError.invalidPath) { try a.replaceText(in: captured, with: "bad") }
        try a.undo(); #expect(try a.text(in: field) == "ab peer")
        try a.redo(); let new = try a.insertBlock(Block.paragraph(id: "p", text: "fresh"))
        #expect(new != p)
        #expect(throws: EditorError.invalidPath) { try a.replaceText(in: captured, with: "bad") }
        #expect(a.document.blocks.first?.text == "fresh")
    }

    @Test func independentInsertionsAndMovesConvergeInEitherReceiveOrder() throws {
        let a = try session("a"), b = try session("b"), p = try a.node(at: NodeAddress("p"))
        let x = try a.insertBlock(Block.paragraph(id: "x", text: "A"), after: p)
        let y = try b.insertBlock(Block.paragraph(id: "y", text: "B"), after: p)
        try exchange(a, b); #expect(a.document == b.document)
        try a.move(x, into: .root); try b.move(y, into: .root)
        try exchange(a, b); #expect(a.document == b.document)
        let saved = try a.save(); try a.move(a.document.blocks[0].id == "x" ? x : y, into: .root)
        #expect(try a.save() == saved)
    }

    @Test func invalidStructuralCommandsAreAtomicAndPolicyDoesNotStripPeerContent() throws {
        let doc = try ModernDocument(documentID: "modern", title: "A", blocks: [layout("one"), layout("two", childID: "other"), Block.paragraph(id: "p", text: "Root")])
        let a = try session("a", document: doc), before = try a.save()
        let one = try a.node(at: NodeAddress("one")), left = try a.node(at: NodeAddress("two", path: ["columns", "left"]))
        #expect(throws: (any Error).self) { try a.move(one, into: NodeCollection(owner: left, field: "children")) }
        #expect(throws: (any Error).self) { try a.insertBlock(layout("new")) }
        #expect(throws: (any Error).self) { try a.delete(left) }
        #expect(throws: (any Error).self) { try a.insertBlock(Block.paragraph(id: "p")) }
        #expect(try a.save() == before)
        a.allowedCommands = ["replaceText"]
        #expect(throws: ModernSessionError.unavailable("hostPolicy")) { try a.insertBlock(Block.paragraph(id: "q")) }
        let b = try session("b", document: doc); _ = try b.insertBlock(Block.paragraph(id: "peer", text: "rich"))
        try a.receive(b.changes()); #expect(a.document == b.document)
    }

    @Test func incrementalInsertedFieldPacketBeforeBirthRetainsRecoveryThenConverges() throws {
        let a = try session("a"), receiver = try session("receiver")
        let node = try a.insertBlock(Block.paragraph(id: "new", text: "seed")), birthReceipt = a.syncState
        let field = try a.field(node: node)
        try a.replaceText(in: field, range: 4..<4, with: " later")
        let incremental = try a.changes(since: birthReceipt), saved = try receiver.save()
        #expect(throws: (any Error).self) { try receiver.receive(incremental) }
        #expect(receiver.mergeRecovery != nil && receiver.syncState.received.isEmpty)
        #expect(try receiver.save() == saved)
        try receiver.receive(a.changes())
        #expect(receiver.mergeRecovery == nil && receiver.document == a.document)
        #expect(try receiver.text(in: field) == "seed later")
    }

    @Test func forgedStructuralAndUnobservedInsertedTextPacketsNeverAcknowledge() throws {
        let a = try session("a"), b = try session("b"), created = try a.insertBlock(Block.paragraph(id: "new", text: "seed"))
        try b.receive(a.changes()); let field = try b.field(node: created)
        try b.replaceText(in: field, range: 4..<4, with: "X")
        let changes = try b.changes().changes, last = changes.last!
        let forged = ModernChange(id: last.id, observed: [], body: last.body)
        let receiver = try session("receiver"), saved = try receiver.save()
        #expect(throws: EditorError.invalidChange) { try receiver.receive(ModernBatch(documentID: "modern", epoch: "modern-1", baseline: a.baseline, changes: [changes[0], forged])) }
        #expect(try receiver.save() == saved)
        let id = ChangeID(counter: 1, actor: "bad"), creation = ElementID(change: id, index: 0)
        let bad = ModernChange(id: id, observed: [], body: .edit([.structure(.insertNode(value: .object(try Block.paragraph(id: "bad").fields), identity: .baseline(blockID: "p", path: []), collection: .root, placement: creation, after: nil))]))
        #expect(throws: EditorError.invalidChange) { try receiver.receive(ModernBatch(documentID: "modern", epoch: "modern-1", baseline: a.baseline, changes: [bad])) }
        #expect(try receiver.save() == saved)
    }
}
