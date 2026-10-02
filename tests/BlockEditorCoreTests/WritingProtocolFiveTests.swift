import BlockEditorCore
import Foundation
import Testing

@Test
func v5InheritsV4ObservedUnicodeAuthorUndoAndRestart() throws {
    let baseline = try Document(blocks: [Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "host": .object(["opaque": .string("keep")]), "content": .array([textNode("C")])])])
    var versions: [(Document, [WritingChange])] = []
    for version in [4, 5] {
        let a = try WritingSession(documentID: "unicode-epoch", actorID: "a", epoch: "explicit-epoch", document: baseline, protocolVersion: version)
        let b = try WritingSession(documentID: "unicode-epoch", actorID: "b", epoch: "explicit-epoch", document: baseline, protocolVersion: version)
        let address = TextAddress("p")
        _ = try a.replaceText(at: address, range: 0..<0, with: "東京")
        let caret = try a.replaceText(at: address, range: 2..<2, with: "X")
        #expect(try a.text(at: address) == "東京XC")
        #expect(try a.resolve(caret).offset == 3)
        _ = try b.replaceText(at: address, range: 1..<1, with: "R")
        try a.receive(b.changes()); try a.receive(b.changes()); try b.receive(a.changes())
        #expect(try a.text(at: address) == "東京XCR")
        #expect(a.document == b.document && a.syncState.version == version)
        #expect(a.changes().changes.allSatisfy { $0.observed != nil })
        versions.append((a.document, a.changes().changes))
        let restored = try WritingSession.restore(a.save(), actorID: "a")
        #expect(restored.protocolVersion == version)
        try restored.undo(); #expect(try restored.text(at: address) == "東京CR")
        try restored.undo(); #expect(try restored.text(at: address) == "CR")
        try restored.redo(); #expect(try restored.text(at: address) == "東京CR")
        try restored.redo(); #expect(restored.document == a.document)
        #expect(restored.document.blocks[0].fields["host"] == baseline.blocks[0].fields["host"])
    }
    // The explicit batch version differs; existing operation bodies and exact cohorts do not.
    #expect(versions[0].0 == versions[1].0 && versions[0].1 == versions[1].1)
}

@Test
func v5RejectsMixedVersionsAndUnknownVersionsWithoutAdmission() throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "p", text: "C")])
    let a = try WritingSession(documentID: "same-document", actorID: "a", epoch: "same-epoch", document: baseline, protocolVersion: 4)
    let b = try WritingSession(documentID: "same-document", actorID: "b", epoch: "same-epoch", document: baseline, protocolVersion: 5)
    _ = try a.replaceText(at: TextAddress("p"), range: 0..<0, with: "four")
    _ = try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "five")
    let savedA = try a.save(), savedB = try b.save(), receiptA = a.syncState, receiptB = b.syncState
    #expect(throws: EditorError.unsupportedVersion(5)) { try a.receive(b.changes()) }
    #expect(throws: EditorError.unsupportedVersion(4)) { try b.receive(a.changes()) }
    #expect(try a.save() == savedA)
    #expect(try b.save() == savedB)
    #expect(a.syncState == receiptA && b.syncState == receiptB && a.mergeRecovery == nil && b.mergeRecovery == nil)
    let wrongEpoch = WritingBatch(documentID: b.documentID, epoch: "other-epoch", baseline: baseline, changes: [], version: 5)
    #expect(throws: WritingSessionError.incompatibleEpoch) { try b.receive(wrongEpoch) }
    #expect(try b.save() == savedB)
    #expect(throws: EditorError.unsupportedVersion(6)) {
        _ = try WritingSession(documentID: "unsupported", actorID: "a", epoch: "six", document: baseline, protocolVersion: 6)
    }
    let unsupported = WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: baseline, changes: b.changes().changes, version: 6)
    #expect(throws: EditorError.unsupportedVersion(6)) {
        _ = try WritingSession.restore(JSONEncoder().encode(unsupported), actorID: "b")
    }
    #expect(throws: EditorError.unsupportedVersion(6)) { try b.receive(unsupported) }
    #expect(try b.save() == savedB)
    #expect(try WritingSession.restore(savedA, actorID: "a").protocolVersion == 4)
}

@Test
func v5RequiredUndoExportsRestartsAndRepairsWithoutLosingPeerMetadata() throws {
    let baseline = try Document(blocks: [Block.paragraph(id: "rich", text: "café 😀")])
    let a = try WritingSession(documentID: "v5-recovery", actorID: "a", epoch: "five", document: baseline, protocolVersion: 5)
    let b = try WritingSession(documentID: "v5-recovery", actorID: "peer", epoch: "five", document: baseline, protocolVersion: 5)
    let inserted = try a.insertCollectionNodes([.object(["id": .string("math"), "type": .string("math"),
        "expression": .string("x+y"), "extension": .object(["remote": .bool(false)])])], into: .root)
    let math = try #require(inserted.nodes.first), creation = try #require(a.changes().changes.first?.id)
    try b.receive(a.changes())
    let peer = WritingChange(id: ChangeID(counter: 2, actor: "peer"), body: .edit([
        .structure(.setNodeField(identity: math, path: ["extension", "remote"], value: .bool(true)))]), observed: [creation])
    try b.receive(WritingBatch(documentID: b.documentID, epoch: b.epoch, baseline: baseline, changes: [peer], version: 5))
    try a.receive(b.changes())
    let accepted = try a.save(), receipt = a.syncState
    #expect(throws: WritingSessionError.self) { try a.undo() }
    let pending = try #require(a.mergeRecovery), exported = try #require(try a.exportRecovery())
    #expect(pending.reason == .schemaConstraint && pending.batch.version == 5 && pending.batch.changes.count == 3)
    #expect(try a.save() == accepted)
    #expect(a.syncState == receipt)
    let restored = try WritingSession.restore(accepted, actorID: "a")
    #expect(throws: WritingSessionError.self) { try restored.restoreRecovery(exported) }
    #expect(throws: EditorError.invalidChange) { try restored.repairText(node: math, field: "expression", text: "") }
    #expect(restored.mergeRecovery == pending && restored.syncState == receipt)
    #expect(try restored.save() == accepted)
    try restored.repairText(node: math, field: "expression", text: "restored 😀")
    #expect(restored.mergeRecovery == nil && restored.changes().version == 5)
    #expect(pending.batch.changes.allSatisfy { restored.changes().changes.contains($0) })
    let repaired = try #require(restored.document.blocks.first { $0.id == "math" })
    #expect(repaired.fields["expression"] == .string("restored 😀"))
    #expect(repaired.fields["extension"] == .object(["remote": .bool(true)]))
    try b.receive(restored.changes()); #expect(b.document == restored.document)
    let reopened = try WritingSession.restore(restored.save(), actorID: "a")
    #expect(reopened.protocolVersion == 5 && reopened.document == restored.document)
}

@Test
func bridgeRoutesExplicitV5AndRejectsUnknownCreateAndRestoreVersions() throws {
    let bridge = EditorBridge()
    func call(_ input: JSONValue) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(input)))
    }
    func create(_ version: Int, _ handle: String) -> JSONValue {
        .object(["command": .string("create"), "session": .string(handle), "collaborationVersion": .number(Double(version)),
            "documentID": .string("bridge-five"), "actorID": .string("a"), "epoch": .string("explicit"), "blocks": .array([])])
    }
    let rejected = try call(create(6, "reusable"))
    #expect(rejected["ok"] == .bool(false) && rejected["error"] == .string("unsupportedVersion(6)"))
    for version in [3, 4, 5] {
        let handle = version == 5 ? "reusable" : "version-\(version)"
        let created = try call(create(version, handle))
        #expect(created["ok"] == .bool(true))
        let saved = try call(.object(["command": .string("save"), "session": .string(handle)]))
        let snapshot = try #require(saved["value"])
        #expect(snapshot["version"] == .number(Double(version)))
        let restored = try call(.object(["command": .string("restore"), "session": .string("restored-\(version)"), "actorID": .string("a"), "snapshot": snapshot]))
        #expect(restored["ok"] == .bool(true))
        var unknown = try #require(snapshot.object); unknown["version"] = .number(6)
        let failedRestore = try call(.object(["command": .string("restore"), "session": .string("unknown-\(version)"), "actorID": .string("a"), "snapshot": .object(unknown)]))
        #expect(failedRestore["ok"] == .bool(false) && failedRestore["error"] == .string("unsupportedVersion(6)"))
    }
}
