import Foundation
import Testing
@testable import BlockEditorCore

// These are production limits, not smaller stand-ins. Serialize the large
// witnesses so a test runner cannot multiply their working set concurrently.
@Suite(.serialized) struct WritingByteRootBoundaryTests {
    private func baseline() throws -> Document {
        let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"),
            "entityId": .string("outside"), "label": .string("Task"), "consumer": .object(["id": .string("ref-opaque")])])
        return try Document(blocks: [Block(fields: ["id": .string("owner"), "type": .string("paragraph"),
            "content": .array([textNode("café 東京😀", marks: [.object(["type": .string("italic")])]), reference]),
            "consumer": .object(["left": .string(""), "right": .string(""), "history": .string(""), "id": .string("opaque")])])])
    }
    private func session(_ document: Document, version: Int, actor: String) throws -> WritingSession {
        try WritingSession(documentID: "real-boundary-\(version)", actorID: actor, epoch: "resource-\(version)",
            document: document, protocolVersion: version)
    }
    private func padding(_ bytes: Int) -> String {
        // Count bytes rather than UTF-16 units or scalars, including an odd byte.
        String(repeating: "é", count: bytes / 2) + (bytes % 2 == 0 ? "" : "x")
    }
    private func pending(_ receiver: WritingSession, _ batch: WritingBatch) throws -> WritingRecovery {
        do { try receiver.receive(batch); Issue.record("Over-limit union accepted") }
        catch WritingSessionError.recoveryRequired(let proposal) { return proposal }
        return try #require(receiver.mergeRecovery)
    }

    @Test(arguments: [4, 5], [0, 1])
    func actual32MBUnionRetainsRejectedHistoryAndPeerMetadata(version: Int, excess: Int) throws {
        let base = try baseline(), emptyBytes = try base.json().count
        let payloadBytes = 32_000_000 - emptyBytes + excess
        let left = padding(payloadBytes / 2), right = padding(payloadBytes - payloadBytes / 2)
        var blocks = base.blocks, metadata = try #require(blocks[0].fields["consumer"]?.object)
        metadata["left"] = .string(left); metadata["right"] = .string(right)
        blocks[0].fields["consumer"] = .object(metadata)
        let expected = try Document(blocks: blocks), wire = try expected.json()
        #expect(wire.count == 32_000_000 + excess)
        if excess == 0 { #expect(try Document(json: wire) == expected) }
        else { #expect(throws: EditorError.invalidDocument("Document exceeds 32 MB")) { _ = try Document(json: wire) } }
        let a = try session(base, version: version, actor: "a"), b = try session(base, version: version, actor: "b")
        let owner = try a.node(at: NodeAddress("owner"))
        try a.setNodeField(owner, path: ["consumer", "left"], value: .string(left))
        try b.setNodeField(owner, path: ["consumer", "right"], value: .string(right))
        if excess == 0 {
            try a.receive(b.changes()); try b.receive(a.changes()); try a.receive(b.changes()); try b.receive(a.changes())
            #expect(a.document == expected && b.document == expected)
            #expect(try a.document.json().count == 32_000_000)
            let reopened = try WritingSession.restore(a.save(), actorID: "a")
            try reopened.undo(); try b.receive(reopened.changes())
            #expect(reopened.document.blocks[0].value(at: ["consumer", "left"]) == .string(""))
            #expect(reopened.document.blocks[0].value(at: ["consumer", "right"]) == .string(right))
            try reopened.redo(); try b.receive(reopened.changes()); #expect(b.document == expected)
            return
        }
        let acceptedA = try a.save(), acceptedB = try b.save(), receiptA = a.syncState, receiptB = b.syncState
        let proposal = try pending(a, b.changes())
        #expect(proposal == (try pending(b, a.changes())))
        #expect(proposal.reason == .schemaConstraint && proposal.batch.changes.count == 2)
        #expect(try pending(a, b.changes()) == proposal)
        #expect(try a.save() == acceptedA && b.save() == acceptedB)
        #expect(a.syncState == receiptA && b.syncState == receiptB)
        let exported = try #require(try a.exportRecovery())
        #expect(exported.count < 64_000_000)
        let reopened = try WritingSession.restore(acceptedA, actorID: "a")
        #expect(throws: WritingSessionError.self) { try reopened.restoreRecovery(exported) }
        #expect(reopened.mergeRecovery == proposal && reopened.syncState == receiptA)
        #expect(throws: EditorError.invalidChange) { try reopened.repairUndo(ChangeID(counter: 1, actor: "b")) }
        #expect(try reopened.save() == acceptedA && reopened.mergeRecovery == proposal)
        try reopened.repairUndo(ChangeID(counter: 1, actor: "a"))
        #expect(reopened.mergeRecovery == nil)
        #expect(reopened.document.blocks[0].value(at: ["consumer", "left"]) == .string(""))
        #expect(reopened.document.blocks[0].value(at: ["consumer", "right"]) == .string(right))
        #expect(reopened.document.blocks[0].fields["content"] == base.blocks[0].fields["content"])
        #expect(try reopened.node(at: NodeAddress("owner")) == owner)
        let repair = reopened.changes(), reverse = WritingBatch(documentID: repair.documentID, epoch: repair.epoch,
            baseline: repair.baseline, changes: Array(repair.changes.reversed()), version: version)
        try b.receive(reverse); try b.receive(repair); #expect(b.document == reopened.document)
        #expect(proposal.batch.changes.allSatisfy { repair.changes.contains($0) })
        let repairedSave = try reopened.save(), repairedReceipt = reopened.syncState
        #expect(throws: WritingSessionError.self) { try reopened.redo() }
        #expect(try reopened.save() == repairedSave && reopened.syncState == repairedReceipt)
        let restarted = try WritingSession.restore(repairedSave, actorID: "a")
        #expect(throws: WritingSessionError.self) { try restarted.restoreRecovery(try #require(try reopened.exportRecovery())) }
        try restarted.repairUndo(ChangeID(counter: 1, actor: "a"))
        #expect(restarted.document == b.document)
        #expect(restarted.changes().changes.count == 5)
    }

    @Test(arguments: [4, 5])
    func actual64MBRetainedBudgetPreservesCallerOwnedRejectedPacket(version: Int) throws {
        let base = try baseline(), author = try session(base, version: version, actor: "a")
        let owner = try author.node(at: NodeAddress("owner"))
        for value in ["one", "two", "three", "four"] {
            try author.setNodeField(owner, path: ["consumer", "history"], value: .string(value))
        }
        let template = author.changes()
        func batch(_ sizes: [Int]) throws -> WritingBatch {
            let changes = try template.changes.enumerated().map { index, change -> WritingChange in
                guard case .edit(let operations) = change.body else { throw EditorError.invalidChange }
                let replaced = operations.map { operation -> WritingOperation in
                    if case .structure(.setNodeField(let node, let path, _)) = operation {
                        // Distinct final scalar values make all four transactions real.
                        return .structure(.setNodeField(identity: node, path: path,
                            value: .string(String(repeating: String(index), count: sizes[index]))))
                    }
                    return operation
                }
                return WritingChange(id: change.id, body: .edit(replaced), observed: change.observed)
            }
            return WritingBatch(documentID: template.documentID, epoch: template.epoch, baseline: base, changes: changes, version: version)
        }
        let ids = template.changes.map(\.id).sorted()
        let reserve = 1_024 + (try canonicalEncoder().encode(ids).count)
        let empty = try batch([0, 0, 0, 0])
        let payload = 64_000_000 - reserve - (try canonicalEncoder().encode(empty).count)
        let quarter = payload / 4, sizes = [quarter, quarter, quarter, payload - 3 * quarter]
        let exact = try batch(sizes), acceptedWire = try canonicalEncoder().encode(exact)
        #expect(acceptedWire.count + reserve == 64_000_000)
        let receiver = try session(base, version: version, actor: "a")
        try receiver.receive(exact)
        #expect(receiver.document.blocks[0].value(at: ["consumer", "history"]) == .string(String(repeating: "3", count: sizes[3])))
        #expect(receiver.document.blocks[0].fields["content"] == base.blocks[0].fields["content"])
        let accepted = try receiver.save(), receipt = receiver.syncState
        #expect(accepted.count <= 64_000_000)
        let restarted = try WritingSession.restore(accepted, actorID: "a")
        #expect(restarted.document == receiver.document && restarted.syncState == receipt)
        // A separate receiver with the first three records encounters the same
        // real limit on receiving the last record plus one byte. The caller must
        // retain this packet: the engine cannot append an over-capacity proposal.
        let partial = WritingBatch(documentID: exact.documentID, epoch: exact.epoch, baseline: base,
            changes: Array(exact.changes.dropLast()), version: version)
        let stopped = try session(base, version: version, actor: "b")
        try stopped.receive(partial)
        let stoppedSave = try stopped.save(), stoppedReceipt = stopped.syncState
        let over = try batch([sizes[0], sizes[1], sizes[2], sizes[3] + 1])
        let callerArchive = try canonicalEncoder().encode(over)
        #expect(callerArchive.count + reserve == 64_000_001)
        #expect(throws: EditorError.recoveryCapacityExceeded) { try stopped.receive(over) }
        #expect(stopped.mergeRecovery == nil && stopped.syncState == stoppedReceipt)
        #expect(try stopped.save() == stoppedSave)
        let resumed = try WritingSession.restore(stoppedSave, actorID: "b")
        let retained = try JSONDecoder().decode(WritingBatch.self, from: callerArchive)
        #expect(retained == over)
        #expect(throws: EditorError.recoveryCapacityExceeded) { try resumed.receive(retained) }
        #expect(try resumed.save() == stoppedSave && resumed.syncState == stoppedReceipt)
        // Explicit cutover creates a new epoch from accepted state. Both original
        // archives remain available; no automatic history truncation is asserted.
        let cutover = try WritingSession(documentID: resumed.documentID, actorID: "b", epoch: "cutover-\(version)",
            document: resumed.document, protocolVersion: version)
        try cutover.setNodeField(owner, path: ["consumer", "left"], value: .string("after-cutover"))
        #expect(cutover.syncState.received.count == 1)
        #expect(cutover.epoch != retained.epoch && cutover.baseline != retained.baseline)
        #expect(throws: EditorError.differentDocument) { try cutover.receive(retained) }
        let staleEpoch = WritingBatch(documentID: cutover.documentID, epoch: retained.epoch,
            baseline: cutover.baseline, changes: [], version: version)
        #expect(throws: WritingSessionError.incompatibleEpoch) { try cutover.receive(staleEpoch) }
        #expect(try WritingSession.restore(cutover.save(), actorID: "b").document == cutover.document)
    }

    @Test(arguments: [4, 5], [9_998, 9_999])
    func actual10000RootUnionCountsRootsAndRetainsPeerDescendants(version: Int, roots: Int) throws {
        let rich = try baseline().blocks[0]
        let base = try Document(blocks: [rich] + (1..<roots).map { try Block.paragraph(id: "root-\($0)") })
        let a = try session(base, version: version, actor: "a"), b = try session(base, version: version, actor: "b")
        let last = try a.node(at: NodeAddress("root-\(roots - 1)"))
        let insertedA = JSONValue.object(try Block.paragraph(id: "A", text: "author").fields)
        let insertedB: JSONValue = .object(["id": .string("B"), "type": .string("toggle"),
            "summary": .array([textNode("peer 東京😀")]), "children": .array([
                .object(["id": .string("peer-child"), "type": .string("paragraph"),
                    "content": rich.fields["content"]!, "consumer": .object(["id": .string("peer-opaque")])])]),
            "consumer": .object(["id": .string("B-opaque")])])
        let selectionA = try a.insertCollectionNodes([insertedA], into: .root, after: last)
        let selectionB = try b.insertCollectionNodes([insertedB], into: .root, after: last)
        let peer = try #require(selectionB.nodes.first)
        let peerChild = try b.node(at: NodeAddress("B", path: ["children", "peer-child"]))
        #expect(a.document.blocks.count == roots + 1 && b.document.blocks.count == roots + 1)
        #expect(b.document.blocks.last?.fields["children"]?.array?.count == 1)
        if roots == 9_998 {
            try a.receive(b.changes()); try b.receive(a.changes()); try a.receive(b.changes())
            #expect(a.document == b.document && a.document.blocks.count == 10_000)
            #expect(Set(a.document.blocks.map(\.id)) == Set(base.blocks.map(\.id) + ["A", "B"]))
            #expect(a.document.blocks[0] == rich)
            #expect(try a.node(at: a.address(of: peerChild)) == peerChild)
            let reopened = try WritingSession.restore(a.save(), actorID: "a")
            try reopened.undo(); try b.receive(reopened.changes())
            #expect(reopened.document.blocks.count == 9_999 && reopened.document == b.document)
            #expect(try reopened.node(at: reopened.address(of: peer)) == peer)
            try reopened.redo(); try b.receive(reopened.changes())
            #expect(reopened.document.blocks.count == 10_000 && reopened.document == b.document)
            return
        }
        #expect(throws: EditorError.invalidDocument("Too many blocks")) {
            _ = try Document(blocks: base.blocks + [Block(fields: insertedA.object!), Block(fields: insertedB.object!)])
        }
        let acceptedA = try a.save(), acceptedB = try b.save(), receiptA = a.syncState, receiptB = b.syncState
        let proposal = try pending(a, b.changes())
        #expect(proposal == (try pending(b, a.changes())) && proposal.reason == .schemaConstraint)
        #expect(try pending(a, b.changes()) == proposal)
        #expect(try a.save() == acceptedA && b.save() == acceptedB)
        #expect(a.syncState == receiptA && b.syncState == receiptB)
        let resumed = try WritingSession.restore(acceptedA, actorID: "a")
        #expect(throws: WritingSessionError.self) { try resumed.restoreRecovery(try #require(try a.exportRecovery())) }
        #expect(throws: EditorError.invalidChange) { try resumed.repairUndo(ChangeID(counter: 1, actor: "b")) }
        #expect(try resumed.save() == acceptedA && resumed.mergeRecovery == proposal)
        try resumed.repairUndo(ChangeID(counter: 1, actor: "a"))
        #expect(resumed.document.blocks.count == 10_000 && resumed.document.blocks[0] == rich)
        #expect(!resumed.document.blocks.contains { $0.id == "A" })
        #expect(try resumed.node(at: resumed.address(of: peer)) == peer)
        #expect(try resumed.node(at: resumed.address(of: peerChild)) == peerChild)
        #expect(try resumed.address(of: peerChild) == NodeAddress("B", path: ["children", "peer-child"]))
        #expect(resumed.changes().changes.count == 3 && selectionA.nodes.count == 1)
        let repair = resumed.changes(), reverse = WritingBatch(documentID: repair.documentID, epoch: repair.epoch,
            baseline: repair.baseline, changes: Array(repair.changes.reversed()), version: version)
        try b.receive(reverse); try b.receive(repair); #expect(b.document == resumed.document)
        let repaired = try resumed.save(), receipt = resumed.syncState
        #expect(throws: WritingSessionError.self) { try resumed.redo() }
        #expect(try resumed.save() == repaired && resumed.syncState == receipt)
        let restarted = try WritingSession.restore(repaired, actorID: "a")
        #expect(throws: WritingSessionError.self) { try restarted.restoreRecovery(try #require(try resumed.exportRecovery())) }
        try restarted.repairUndo(ChangeID(counter: 1, actor: "a"))
        #expect(restarted.document == b.document && restarted.changes().changes.count == 5)
    }
}
