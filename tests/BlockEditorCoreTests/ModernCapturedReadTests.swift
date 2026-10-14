@testable import BlockEditorCore
import Testing

@Suite struct ModernCapturedReadTests {
    private func document() throws -> ModernDocument {
        try ModernDocument(documentID: "captured-read", title: "Help", blocks: [
            Block.paragraph(id: "A", text: "ABC"), Block.paragraph(id: "B", text: "Keep 😀")
        ])
    }
    @Test func currentPreviousAndOlderSelectionsRetainOnlyTheirOriginalAtomsThroughPeerWork() throws {
        let original = try document()
        let a = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "read", document: original)
        let b = try ModernSession(documentID: original.documentID, actorID: "b", epoch: "read", document: original)
        let field = try a.field(node: a.node(at: NodeAddress("A")))
        let selected = try a.captureTextRange(in: field, start: 0, end: 3)
        #expect(try a.markState(in: selected, type: "bold") == .off)
        try a.replaceText(in: field, range: 3..<3, with: "!")
        for _ in 0..<3 { #expect(try a.markState(in: selected, type: "bold") == .off) }
        try b.replaceText(in: b.field(node: b.node(at: NodeAddress("A"))), range: 0..<0, with: "Peer ")
        try a.receive(b.changes())
        let saved = try a.save()
        for _ in 0..<3 { #expect(try a.markState(in: selected, type: "bold") == .off) }
        #expect(try a.save() == saved)
        _ = try a.format(in: selected, markType: "bold", mark: .object(["type": .string("bold")]))
        var fields = original.fields, blocks = original.blocks.map { JSONValue.object($0.fields) }
        var first = blocks[0].object!
        first["content"] = .array([
            .object(["type": .string("text"), "text": .string("Peer "), "marks": .array([])]),
            .object(["type": .string("text"), "text": .string("ABC"), "marks": .array([.object(["type": .string("bold")])])]),
            .object(["type": .string("text"), "text": .string("!"), "marks": .array([])])
        ])
        blocks[0] = .object(first); fields["blocks"] = .array(blocks)
        let expected = try ModernDocument(fields: fields)
        #expect(a.document == expected)
        #expect(try a.markState(in: selected, type: "bold") == .on)
        try a.undo(); #expect(try a.text(in: field) == "Peer ABC!")
        try a.redo(); #expect(a.document == expected)
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        #expect(try reopened.markState(in: selected, type: "bold") == .on)
        #expect(reopened.document == expected)
    }

    @Test func forgedCohortsCannotBorrowAValidatedCurrentOrPreviousRead() throws {
        let original = try document()
        let session = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "read", document: original)
        let field = try session.field(node: session.node(at: NodeAddress("A")))
        try session.replaceText(in: field, range: 3..<3, with: "!")
        let current = try session.captureTextRange(in: field, start: 0, end: 3)
        #expect(try session.markState(in: current, type: "bold") == .off)
        let saved = try session.save(), identity = current.observed[0]
        for observed in [[identity, identity], [ChangeID(counter: 1, actor: "unknown")], [ChangeID(counter: 2, actor: "a")]] {
            let forged = ModernTextRange(start: current.start, end: current.end, observed: observed)
            #expect(throws: (any Error).self) { try session.markState(in: forged, type: "bold") }
            #expect(try session.save() == saved)
        }
    }
}
