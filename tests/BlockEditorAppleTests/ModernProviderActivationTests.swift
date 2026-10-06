import BlockEditorApple
import BlockEditorCore
import Foundation
import Testing

@MainActor struct ModernProviderActivationTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("modern-batch-\(UUID())")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false); return value
    }
    private func model() throws -> ModernEditorModel {
        let image = try Block(fields: ["id": .string("image"), "type": .string("image"), "src": .string("asset://pending")])
        return ModernEditorModel(session: try ModernSession(documentID: "host", actorID: "a", epoch: "e", document: ModernDocument(documentID: "host", blocks: [image])))
    }
    @Test func delayedResultIsDurableButDoesNotApplyAfterDocumentSwitch() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(), store = ModernHostStore(url: directory.appendingPathComponent("pair.json"), documentID: "host", actorID: "a")
        let controller = ModernProviderController(persistence: ModernPersistenceController(model: model, store: store)) { _ in
            await MainActor.run { model.isActive = false }
            return ["src": .string("asset://resolved")]
        }
        let target = try controller.start(node: model.session.node(at: NodeAddress("image")))
        await controller.waitForRequest(target)
        #expect(model.document.blocks[0].fields["src"] == .string("asset://pending"))
        let saved = try #require(try await store.load()), restored = try saved.restore()
        #expect(restored.session.asyncRequests.first?.status == .retained && restored.session.asyncRequests.first?.result?["src"] == .string("asset://resolved"))
        #expect(restored.session.syncState.received.isEmpty)
        model.isActive = true; try await controller.retryResult(target)
        #expect(model.document.blocks[0].fields["src"] == .string("asset://resolved"))
        #expect(try await store.load()?.restore().session.asyncRequests.first?.status == .applied)
    }
    @Test func failedResultSaveLeavesResponseForExplicitRetry() async throws {
        let directory = try directory(), parked = directory.appendingPathExtension("parked")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: parked) }
        let model = try model(), store = ModernHostStore(url: directory.appendingPathComponent("pair.json"), documentID: "host", actorID: "a")
        let controller = ModernProviderController(persistence: ModernPersistenceController(model: model, store: store)) { _ in
            try FileManager.default.moveItem(at: directory, to: parked)
            return ["src": .string("asset://successful-response")]
        }
        let target = try controller.start(node: model.session.node(at: NodeAddress("image")))
        await controller.waitForRequest(target)
        #expect(controller.error != nil && model.session.syncState.received.isEmpty)
        #expect(model.session.asyncRequests.first?.result?["src"] == .string("asset://successful-response"))
        try FileManager.default.moveItem(at: parked, to: directory)
        try await controller.retryResult(target)
        #expect(model.document.blocks[0].fields["src"] == .string("asset://successful-response"))
        #expect(try await store.load()?.restore().session.asyncRequests.first?.status == .applied)
    }
    @Test func migrationActivationRetainsOriginalsAndRollbackSurvivesConflict() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModernActivationStore(directory: directory, documentID: "migrating")
        let raw = Data(#" [{"id":"p","type":"paragraph","content":[{"type":"text","text":"Original 😀"}],"vendor":{"retain":true}}] "#.utf8)
        func candidate(_ epoch: String) throws -> (ModernCutoverArchive, ModernHostCheckpoint) {
            let archive = ModernCutoverArchive(documentID: "migrating", epoch: epoch, source: .document(format: .blockArray, bytes: raw), originals: [raw])
            let plan = try ProtocolMigration.prepareModernCutover(archive)
            let session = try plan.makeSession(actorID: "a", archiveReadback: plan.archiveBytes, oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true)
            return (archive, try ModernHostCheckpoint(session: session))
        }
        let first = try candidate("one"), active = try await store.activate(archive: first.0, candidate: first.1, replacing: nil, oldWritersStopped: true)
        #expect(try Data(contentsOf: directory.appendingPathComponent(active.archiveFile)) == first.0.json())
        let live = try #require(try await store.activeHostStore(actorID: "a"))
        let opened = try #require(try await live.load()).restore()
        let paragraph = try opened.session.logicalFields(includingTitle: false)[0]
        try opened.session.replaceText(in: paragraph, range: 0..<0, with: "Saved later: ")
        _ = try await live.save(ModernHostCheckpoint(session: opened.session), replacing: first.1.revision)
        #expect(try await store.loadActive()?.restore().session.document.blocks[0].text == "Saved later: Original 😀")
        #expect(try Data(contentsOf: directory.appendingPathComponent(active.archiveFile)) == first.0.json())
        let second = try candidate("two"), replacement = try await store.activate(archive: second.0, candidate: second.1, replacing: active.revision, oldWritersStopped: true)
        do { _ = try await store.activate(archive: second.0, candidate: second.1, replacing: active.revision, oldWritersStopped: true); Issue.record("Expected revision conflict") }
        catch { #expect(error as? ModernHostStoreError == .revisionConflict) }
        #expect(try await store.active()?.revision == replacement.revision)
        let rollback = try await store.rollback(replacing: replacement.revision, oldWritersStopped: true)
        #expect(rollback.revision == active.revision)
        #expect(try await store.loadActive()?.restore().session.document.blocks[0].text == "Saved later: Original 😀")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(replacement.checkpointFile).path))
    }
}
