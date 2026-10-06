import Foundation
import Testing
@testable import BlockEditorCore

struct ModernTableCommandTests {
    private func session(_ actor: String = "a") throws -> ModernSession {
        let table = try ModernInsertionCatalog.block("table", id: "T", childIDs: ["r1", "a", "b", "r2", "c", "d"])
        return try ModernSession(documentID: "doc", actorID: actor, epoch: "modern", document: ModernDocument(documentID: "doc", blocks: [table]))
    }
    private func target(_ s: ModernSession) throws -> ModernTableTarget {
        try s.captureTableTarget(table: s.node(at: NodeAddress("T")), row: s.node(at: NodeAddress("T", path: ["rows", "r1"])), cell: s.node(at: NodeAddress("T", path: ["rows", "r1", "cells", "a"])))
    }
    @Test func insertedRowsAndColumnsHaveIndependentEditableOriginsAndUndo() throws {
        let s = try session(), initial = s.document
        _ = try s.tableStructure(target(s), action: .insertRow, newIDs: ["r3", "e", "f"])
        #expect(s.document.blocks[0].fields["rows"]?.array?.map { $0["id"]?.string } == ["r1", "r3", "r2"])
        _ = try s.tableStructure(target(s), action: .insertColumn, newIDs: ["g", "h", "i"])
        let node = try s.node(at: NodeAddress("T", path: ["rows", "r3", "cells", "h"]))
        let field = try s.field(node: node)
        try s.replaceText(in: field, range: 0..<0, with: "🧑🏽‍💻 é")
        #expect(try s.text(in: field) == "🧑🏽‍💻 é")
        let reopened = try ModernSession.restore(s.save(), actorID: "a")
        try reopened.undo(); try reopened.undo(); try reopened.undo()
        #expect(reopened.document == initial)
        try reopened.redo(); try reopened.redo(); try reopened.redo()
        #expect(reopened.document == s.document)
    }
    @Test func headerUndoKeepsLaterPeerCellText() throws {
        let a = try session(), b = try session("b"), captured = try target(a)
        _ = try a.tableStructure(captured, action: .setHeader, header: false)
        let field = try b.field(node: captured.cell!)
        try b.replaceText(in: field, range: 0..<0, with: "peer")
        try a.receive(b.changes()); try b.receive(a.changes())
        #expect(a.document == b.document)
        try a.undo()
        #expect(try a.text(in: field) == "peer")
        #expect(a.document.blocks[0].fields["rows"]?.array?[0]["cells"]?.array?[0]["header"] == .bool(true))
    }
    @Test func staleDeletionDoesNotEraseNewPeerCellsAndMalformedPlansAreAtomic() throws {
        let s = try session(), captured = try target(s)
        _ = try s.tableStructure(captured, action: .insertColumn, newIDs: ["x", "y"])
        let before = try s.save()
        #expect(throws: ModernSessionError.self) { try s.tableStructure(captured, action: .removeColumn) }
        #expect(try s.save() == before)
        #expect(throws: (any Error).self) { try s.tableStructure(captured, action: .insertRow, newIDs: ["bad"]) }
        #expect(try s.save() == before)
    }
    @Test func catalogProducesAdmittedBlocksAndAvailabilityHonorsHostPolicy() throws {
        let s = try session()
        s.allowedCommands = ["tableStructure"]
        #expect(s.availability(for: "tableStructure").available)
        #expect(s.availability(for: "mediaProperties").reason == "hostPolicy")
        #expect(ModernInsertionCatalog.search("two").map(\.id) == ["columns"])
        for d in ModernInsertionCatalog.descriptors where !d.requiresHost && d.id != "columns" {
            let ids = (0..<6).map { "c\($0)" }
            let block = try ModernInsertionCatalog.block(d.id, id: d.id, childIDs: d.blockType == "list" ? ["item"] : ids)
            _ = try ModernDocument(documentID: "candidate", blocks: [block])
        }
    }
}
