import BlockEditorCore
import BlockEditorLocalDemo
import Foundation
import Testing

@Test func draftRestoresExclusiveAuthorHistoryAndPreservesRemoteChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    let endpoint = URL(string: "http://127.0.0.1:4319/rooms/draft")!
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Hello")])
    let remote = try EditorSession(documentID: "d", actorID: "remote", document: baseline)
    do {
        let draft = try LocalDraft(file: file)
        #expect(try draft.restore(endpoint: endpoint) == nil)
        #expect(throws: DraftError.alreadyOpen) { try LocalDraft(file: file) }
        let local = try EditorSession(documentID: "d", actorID: "local", document: baseline)
        try local.replaceText(at: TextAddress("p"), range: 5..<5, with: " local 😀")
        try draft.save(local, endpoint: endpoint)
    }
    try remote.replaceText(at: TextAddress("p"), range: 5..<5, with: " remote 世界")
    let draft = try LocalDraft(file: file)
    let restored = try #require(try draft.restore(endpoint: endpoint))
    #expect(restored.actorID == "local")
    #expect(restored.canUndo)
    try restored.receive(remote.changes())
    try remote.receive(restored.changes())
    #expect(try restored.document == remote.document)
    try restored.undo()
    #expect(try restored.text(at: TextAddress("p")) == "Hello remote 世界")
    let bytes = try Data(contentsOf: file)
    #expect(throws: DraftError.differentEndpoint) { try draft.restore(endpoint: URL(string: "http://127.0.0.1:4319/rooms/other")!) }
    #expect(try Data(contentsOf: file) == bytes)
    var incompatible = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    incompatible["version"] = 99
    let newer = try JSONSerialization.data(withJSONObject: incompatible)
    try newer.write(to: file)
    #expect(throws: DraftError.unsupportedVersion) { try draft.restore(endpoint: endpoint) }
    #expect(try Data(contentsOf: file) == newer)
}

@Test func corruptDraftIsNotSilentlyReplaced() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    let draft = try LocalDraft(file: file)
    let corrupt = Data("not a saved document".utf8)
    try corrupt.write(to: file)
    #expect(throws: (any Error).self) { try draft.restore(endpoint: URL(string: "http://localhost/room")!) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@Test func standaloneDraftCreatesReopensAndUndoesWithoutTransport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("local.json")
    var author = ""
    do {
        let draft = try LocalDraft(file: file)
        let session = try draft.openLocalDocument()
        author = session.actorID
        #expect(try session.text(at: TextAddress("p")) == "")
        try session.setText(at: TextAddress("p"), to: "Local café 👩🏽‍💻")
        try draft.saveLocalDocument(session)
    }
    let draft = try LocalDraft(file: file)
    let restored = try draft.openLocalDocument()
    #expect(restored.actorID == author)
    #expect(try restored.text(at: TextAddress("p")) == "Local café 👩🏽‍💻")
    try restored.undo()
    #expect(try restored.text(at: TextAddress("p")) == "")
    try restored.redo()
    #expect(try restored.text(at: TextAddress("p")) == "Local café 👩🏽‍💻")
    let bytes = try Data(contentsOf: file)
    #expect(throws: DraftError.differentEndpoint) {
        try draft.restore(endpoint: URL(string: "http://localhost/rooms/other")!)
    }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func standaloneOpenDoesNotReplaceAnExistingRelayDraft() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json")
    let draft = try LocalDraft(file: file)
    let session = try EditorSession(documentID: "relay", actorID: "author", document: Document(blocks: [.paragraph(id: "p", text: "Keep me")]))
    try draft.save(session, endpoint: URL(string: "http://localhost/rooms/existing")!)
    let bytes = try Data(contentsOf: file)
    #expect(throws: DraftError.differentEndpoint) { try draft.openLocalDocument() }
    #expect(try Data(contentsOf: file) == bytes)
}

@Test func pendingRecoverySurvivesDraftRestartExportAndExplicitRepair() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json"), archive = directory.appendingPathComponent("recovery.json")
    let endpoint = URL(string: "http://localhost/rooms/recovery")!
    let parent = try Block(fields: ["id": .string("parent"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    let baseline = try Document(blocks: [parent])
    let a = try EditorSession(documentID: "recovery", actorID: "a", document: baseline, collaborationVersion: 2)
    let b = try EditorSession(documentID: "recovery", actorID: "b", document: baseline, collaborationVersion: 2)
    let collection = NodeCollection(owner: .baseline(blockID: "parent", path: []), field: "children")
    _ = try a.insertNode(.object(Block.paragraph(id: "same", text: "café 😀 Alice").fields), into: collection)
    let second = try b.insertNode(.object(Block.paragraph(id: "same", text: "世界 Bob").fields), into: collection)
    let accepted = try a.save(), receipts = a.syncState
    #expect(throws: EditorError.self) { try a.receive(b.changes()) }
    let proposal = try #require(a.mergeRecovery)
    #expect(RecoveryBlock.candidates(in: proposal).contains { $0.id == second && $0.label.contains("世界 Bob") })
    do {
        let draft = try LocalDraft(file: file)
        try draft.save(a, endpoint: endpoint)
        try draft.exportRecovery(a, endpoint: endpoint, to: archive)
        let exported = try Data(contentsOf: archive)
        #expect(throws: DraftError.archiveExists) { try draft.exportRecovery(a, endpoint: endpoint, to: archive) }
        #expect(try Data(contentsOf: archive) == exported)
    }
    let draft = try LocalDraft(file: file)
    let restored = try #require(try draft.restore(endpoint: endpoint))
    #expect(try restored.save() == accepted)
    #expect(restored.syncState == receipts)
    #expect(restored.mergeRecovery == proposal)
    #expect(throws: EditorError.self) { try restored.undo() }
    #expect(throws: EditorError.self) {
        try restored.repairMerge([.move(identity: second, collection: collection)])
    }
    #expect(restored.mergeRecovery == proposal)
    #expect(try restored.save() == accepted)
    let exportLease = try LocalDraft(file: archive)
    let exportedSession = try #require(try exportLease.restore(endpoint: endpoint))
    #expect(exportedSession.mergeRecovery == proposal)
    #expect(try exportedSession.document == restored.document)
    #expect(exportedSession.syncState == receipts)
    #expect(exportedSession.actorID != restored.actorID)
    let wrapper = try Block(fields: ["id": .string("wrapper"), "type": .string("toggle"), "summary": .array([]), "children": .array([])])
    try restored.repairMerge([.wrap(identity: second, container: wrapper, field: "children")])
    try b.receive(restored.changes())
    #expect(try restored.document == b.document)
    #expect(restored.mergeRecovery == nil)
    #expect(try restored.text(at: restored.textAddress(of: second)) == "世界 Bob")
    try draft.save(restored, endpoint: endpoint)
    #expect(try draft.restore(endpoint: endpoint)?.mergeRecovery == nil)
}

@Test func oldDraftUpgradesWithoutResetAndIncompatibleRecoveryIsRetainedOnDisk() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("draft.json"), endpoint = URL(string: "http://localhost/rooms/old")!
    let session = try EditorSession(documentID: "old", actorID: "author", document: Document(blocks: [.paragraph(id: "p", text: "Keep me")]))
    let old: [String: Any] = ["version": 1, "endpoint": endpoint.absoluteString, "actorID": session.actorID,
                            "snapshot": try session.save().base64EncodedString()]
    let draft = try LocalDraft(file: file)
    try JSONSerialization.data(withJSONObject: old).write(to: file)
    let restored = try #require(try draft.restore(endpoint: endpoint))
    #expect(try restored.document == session.document)
    #expect(restored.actorID == session.actorID)
    try draft.save(restored, endpoint: endpoint)
    var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(record["version"] as? Int == 2)
    record["recovery"] = ["reason": "identityConflict", "batch": ["version": 99, "documentID": "old",
        "baseline": ["blocks": []], "changes": []]]
    let incompatible = try JSONSerialization.data(withJSONObject: record)
    try incompatible.write(to: file)
    #expect(throws: EditorError.unsupportedVersion(99)) { try draft.restore(endpoint: endpoint) }
    #expect(try Data(contentsOf: file) == incompatible)
}
