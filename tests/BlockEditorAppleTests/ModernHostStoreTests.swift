import BlockEditorApple
import BlockEditorCore
import Foundation
import Testing

@MainActor @Suite struct ModernHostStoreTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("modern-host-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }
    private func document() throws -> ModernDocument {
        let image = try Block(fields: ["id": .string("image"), "type": .string("image"), "src": .string("asset://pending")])
        return try ModernDocument(documentID: "host", title: "Title", blocks: [.paragraph(id: "p", text: "ABC😀"), image])
    }
    private func session(_ actor: String = "author") throws -> ModernSession {
        try ModernSession(documentID: "host", actorID: actor, epoch: "epoch", document: document())
    }
    private func field(_ session: ModernSession) throws -> WritingField {
        try session.field(node: session.node(at: NodeAddress("p")))
    }

    @Test func diskReopenPairsHistoryCaretProvidersHeldPeerAndOriginalDraft() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModernHostStore(url: directory.appendingPathComponent("active.json"), documentID: "host", actorID: "author")
        let a = try session(), b = try session("peer")
        let selected = try a.captureTextRange(in: field(a), start: 2, end: 1)
        try a.setLocalSelection(a.captureLocalSelection(focus: .text(selected.end), selection: .text(WritingTextRange(start: selected.start, end: selected.end))))
        try a.replaceText(in: selected, with: "X")
        _ = try a.beginAsyncBlock(a.node(at: NodeAddress("image")), requestID: "inert-provider")
        let release = try a.holdRemoteChanges(); defer { try? release() }
        try b.replaceText(in: field(b), range: 0..<0, with: "R"); try a.receive(b.changes())
        let draft = ModernPendingInput(target: try a.captureTextRange(in: field(a), start: 2, end: 2), text: "東京😀", selection: 4..<4, reason: "Native composition retained")
        a.isComposing = true
        #expect(throws: ModernSessionError.compositionActive) { try ModernHostCheckpoint(session: a) }
        let checkpoint = try await store.save(ModernHostCheckpoint(session: a, pendingInputs: [draft]), replacing: nil)
        let reopened = try #require(try await store.load()).restore()
        #expect(reopened.checkpoint.revision == checkpoint.revision)
        #expect(reopened.pendingInputs == [draft])
        #expect(reopened.session.document == a.document)
        #expect(try reopened.session.exportHistorySelection() == a.exportHistorySelection())
        #expect(try reopened.session.exportAsyncRequests() == a.exportAsyncRequests())
        #expect(reopened.session.asyncRequests.first?.status == .pending && !reopened.session.isComposing)
        #expect(try reopened.session.exportDeferredChanges() == a.exportDeferredChanges())
        #expect(reopened.session.document.blocks[0].text == "AXC😀")
        try reopened.resumeDeferredChanges()
        #expect(reopened.session.document.blocks[0].text == "RAXC😀")
        try reopened.session.undo()
        #expect(reopened.session.document.blocks[0].text == "RABC😀")
        guard case .text(let selection) = reopened.session.localSelection?.selection else { Issue.record("Missing original backward selection"); return }
        #expect(try reopened.session.resolve(selection.start).offset == 3)
        #expect(try reopened.session.resolve(selection.end).offset == 2)
        #expect(reopened.pendingInputs == [draft])
        try reopened.session.redo()
        #expect(reopened.session.document.blocks[0].text == "RAXC😀")
    }

    @Test func conflictingRecoveryReopensAcceptedStateAndCanBeExplicitlyRepaired() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModernHostStore(url: directory.appendingPathComponent("active.json"), documentID: "host", actorID: "author")
        let a = try session(), b = try session("peer")
        _ = try a.insertBlock(.paragraph(id: "same", text: "Own"))
        let own = try #require(a.changes().changes.first?.id)
        _ = try b.insertBlock(.paragraph(id: "same", text: "Peer"))
        #expect(throws: ModernSessionError.self) { try a.receive(b.changes()) }
        let recovery = try #require(try a.exportRecovery())
        let checkpoint = try await store.save(ModernHostCheckpoint(session: a), replacing: nil)
        let reopened = try #require(try await store.load()).restore()
        #expect(try reopened.session.save() == checkpoint.accepted)
        #expect(try reopened.session.exportRecovery() == recovery)
        try reopened.session.repairUndo([own])
        #expect(reopened.session.mergeRecovery == nil)
        let expected = try ModernDocument(documentID: "host", title: "Title", blocks: [.paragraph(id: "same", text: "Peer")] + document().blocks)
        #expect(reopened.session.document == expected)
        let repaired = try await store.save(ModernHostCheckpoint(session: reopened.session), replacing: checkpoint.revision)
        #expect(try await store.load()?.revision == repaired.revision)
    }

    @Test func staleWriterAndInvalidDraftCannotReplaceTheDurablePair() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("active.json")
        let first = ModernHostStore(url: url, documentID: "host", actorID: "author")
        let second = ModernHostStore(url: url, documentID: "host", actorID: "author")
        let a = try session(), checkpoint = try await first.save(ModernHostCheckpoint(session: a), replacing: nil)
        let stale = try #require(try await second.load()).restore()
        try a.replaceTitle(range: 0..<0, with: "New ")
        let next = try await first.save(ModernHostCheckpoint(session: a), replacing: checkpoint.revision), bytes = try Data(contentsOf: url)
        let stalePair = try ModernHostCheckpoint(session: stale.session)
        await #expect(throws: ModernHostStoreError.revisionConflict) { try await second.save(stalePair, replacing: checkpoint.revision) }
        let invalid = ModernPendingInput(target: try a.captureTextRange(in: field(a), start: 1, end: 1), text: "a", selection: 2..<2, reason: "Invalid caret")
        #expect(throws: ModernHostStoreError.invalidCheckpoint) { try ModernHostCheckpoint(session: a, pendingInputs: [invalid]) }
        #expect(try Data(contentsOf: url) == bytes)
        let loaded = try #require(try await first.load()).restore()
        #expect(loaded.session.document.title == "New Title" && loaded.checkpoint.revision == next.revision)
        let wrongOwner = ModernHostStore(url: url, documentID: "host", actorID: "other")
        await #expect(throws: ModernHostStoreError.differentOwner) { try await wrongOwner.load() }
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["ignoredSidecar"] = "must not disappear"
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: url)
        await #expect(throws: ModernHostStoreError.invalidCheckpoint) { try await first.load() }
    }
}
