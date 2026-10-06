import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernAsyncCommandsTests {
    private func fixture(_ name: String = "mixed") throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func session(_ actor: String = "a", _ document: ModernDocument? = nil, epoch: String = "async") throws -> ModernSession {
        let d = try document ?? fixture(); return try ModernSession(documentID: d.documentID, actorID: actor, epoch: epoch, document: d)
    }
    private func node(_ s: ModernSession, _ id: String = "media") throws -> NodeID { try s.node(at: NodeAddress(id)) }
    private func begin(_ s: ModernSession, _ request: String = "request", _ id: String = "media") throws -> ModernAsyncTarget {
        try s.beginAsyncBlock(node(s, id), requestID: request)
    }
    private let result: [String: JSONValue] = ["src": .string("asset://fixture/completed"), "width": .number(640), "height": .number(480)]
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let aa = try a.changes(), bb = try b.changes(); try a.receive(bb); try b.receive(aa); try a.receive(bb); try b.receive(aa)
    }
    private func reject(_ s: ModernSession, _ action: () throws -> Void) throws {
        let save = try s.save(), requests = try s.exportAsyncRequests(), state = s.syncState
        do { try action(); Issue.record("Expected unchanged rejection") } catch {}
        #expect(try s.save() == save && s.exportAsyncRequests() == requests && s.syncState == state && s.mergeRecovery == nil)
    }
    private func file(_ id: String = "file") -> JSONValue {
        .object(["id": .string(id), "type": .string("file"), "src": .string("asset://pending/file"), "name": .string("Research notes.pdf"), "consumer": .object(["assetID": .string("fixture-only"), "status": .string("pending")])])
    }
    private func media(_ s: ModernSession) -> [String: JSONValue] { s.document.blocks.first { $0.id == "media" }!.fields }

    @Test func completionPreservesPeerCaptionOpaqueMetadataAndOriginalOriginThroughMoveUndoReopen() throws {
        let a = try session(), b = try session("b"), target = try begin(a), original = media(a)
        let caption = try b.field(node: node(b), name: "caption")
        try b.replaceText(in: caption, range: 0..<0, with: "peer ")
        _ = try b.move(ModernMoveTarget(selection: b.captureNodes([node(b)]), boundary: b.captureBoundary()))
        try a.receive(b.changes()); let before = try a.save()
        #expect(try a.completeAsyncBlock(target, metadata: result).status == "applied")
        #expect(a.document.blocks[0].id == "media" && media(a)["consumer"] == original["consumer"])
        #expect(try a.text(in: caption) == "peer Caption")
        let changes = try a.changes().changes
        let own = changes.filter { $0.id.actor == "a" }; #expect(own.count == 1)
        let bytes = String(decoding: try a.changes().json(), as: UTF8.self)
        #expect(!bytes.contains("requestID") && !bytes.contains("generation"))
        let cache = try a.exportAsyncRequests(), restored = try ModernSession.restore(a.save(), actorID: "a")
        try restored.restoreAsyncRequests(cache); try restored.undo()
        #expect(try restored.text(in: caption) == "peer Caption" && media(restored)["src"] == original["src"])
        let undone = try restored.save(); #expect(try restored.completeAsyncBlock(target, metadata: result).status == "noop")
        #expect(try restored.save() == undone) // A duplicate provider delivery cannot undo the user's Undo.
        try restored.redo(); #expect(try restored.document == a.document && before != a.save())
        try exchange(a, b); #expect(a.document == b.document)
    }
    @Test func acceptedReplacementDocumentAndEpochRejectLateResultWithOriginReceiptStillPending() throws {
        let original = try session(), target = try begin(original), old = try original.save()
        let replacement = try session("replacement", fixture("unicode")), before = try replacement.save()
        let outcome = try replacement.completeAsyncBlock(target, metadata: result)
        #expect(outcome.status == "unavailable" && outcome.reason == "asyncOriginScopeChanged" && outcome.retainedResult == result)
        #expect(try replacement.save() == before && original.save() == old && original.asyncRequests[0].status == .pending)
        let otherEpoch = try session("a", epoch: "other"), otherBefore = try otherEpoch.save()
        #expect(try otherEpoch.completeAsyncBlock(target, metadata: result).status == "unavailable")
        #expect(try otherEpoch.save() == otherBefore && otherEpoch.asyncRequests.isEmpty)
    }
    @Test func deletedOrReusedLabelNeverReceivesCompletionAndExplicitRetryAfterDeletionUndoIsPossible() throws {
        let s = try session(), target = try begin(s)
        _ = try s.delete(ModernDeleteTarget(nodes: s.captureNodes([node(s)]))); let deleted = try s.save()
        #expect(try s.completeAsyncBlock(target, metadata: result).status == "unavailable")
        #expect(try s.save() == deleted && s.asyncRequests[0].status == .retained && s.asyncRequests[0].result == result)
        let cache = try s.exportAsyncRequests(), restored = try ModernSession.restore(s.save(), actorID: "a")
        try restored.restoreAsyncRequests(cache); #expect(try restored.save() == deleted)
        try restored.undo(); #expect(try restored.completeAsyncBlock(target, metadata: result).status == "applied")
        _ = try s.insertBlock(Block(fields: ["id": .string("media"), "type": .string("image"), "src": .string("asset://replacement")]), at: s.captureBoundary())
        let replaced = try s.save(); #expect(try s.completeAsyncBlock(target, metadata: result).status == "unavailable")
        #expect(try s.save() == replaced && media(s)["src"] == .string("asset://replacement"))
    }
    @Test func cancellationSupersededGenerationAndReusedRequestIDCannotApplyLateResult() throws {
        let s = try session(), first = try begin(s), before = try s.save()
        let second = try begin(s, "second")
        #expect(second.generation > first.generation && s.asyncRequests[0].status == .cancelled)
        #expect(try s.completeAsyncBlock(first, metadata: result).status == "unavailable")
        try s.cancelAsyncBlock(second); #expect(try s.completeAsyncBlock(second, metadata: result).status == "unavailable")
        #expect(try s.save() == before && s.asyncRequests.allSatisfy { $0.result == result && $0.status == .cancelled })
        try s.forgetAsyncBlock(first); let reused = try begin(s)
        #expect(reused.generation > second.generation)
        #expect(try s.completeAsyncBlock(first, metadata: result).status == "unavailable")
        #expect(s.asyncRequests.last!.target == reused && s.asyncRequests.last!.result == nil)
        #expect(try s.completeAsyncBlock(reused, metadata: result).status == "applied")
    }
    @Test func failureAndInterruptedReopenPreserveLocalPendingErrorResultWithoutSharedMutation() throws {
        let s = try session(), target = try begin(s), saved = try s.save()
        try s.failAsyncBlock(target, reason: "provider unavailable")
        #expect(try s.completeAsyncBlock(target, metadata: result).status == "unavailable")
        let cache = try s.exportAsyncRequests(), restored = try ModernSession.restore(s.save(), actorID: "a")
        try restored.restoreAsyncRequests(cache)
        #expect(try restored.save() == saved && restored.asyncRequests == s.asyncRequests)
        #expect(restored.asyncRequests[0].status == .failed && restored.asyncRequests[0].reason == "provider unavailable" && restored.asyncRequests[0].result == result)
        let retry = try begin(restored, "retry")
        #expect(retry.generation > target.generation && restored.asyncRequests[0].status == .cancelled)
        #expect(try restored.completeAsyncBlock(retry, metadata: result).status == "applied")
    }
    @Test func policyAndCompositionRetainInertResultForExplicitResubmissionAndDoNotChangeHistory() throws {
        let s = try session(), target = try begin(s), before = try s.save()
        s.allowedCommands = ["replaceTitle"]
        #expect(try s.completeAsyncBlock(target, metadata: result).reason == "hostPolicy")
        #expect(try s.save() == before && s.asyncRequests[0].result == result)
        s.allowedCommands = nil; s.isComposing = true
        #expect(try s.completeAsyncBlock(target, metadata: result).reason == "compositionActive")
        #expect(try s.save() == before && s.asyncRequests[0].status == .retained)
        s.isComposing = false
        #expect(try s.completeAsyncBlock(target, metadata: result).status == "applied")
    }
    @Test func sourceChangeRetainsOldResultAndFreshTargetCompletesWithoutOverwritingNewPreviewURL() throws {
        let s = try session(), peer = try session("peer"), first = try begin(s), peerTarget = try begin(peer)
        _ = try peer.completeAsyncBlock(peerTarget, metadata: ["src": .string("asset://new")]); try s.receive(peer.changes())
        let changed = try s.save()
        #expect(try s.completeAsyncBlock(first, metadata: result).reason == "asyncTargetChanged")
        #expect(try s.save() == changed && s.asyncRequests[0].status == .retained)
        let fresh = try begin(s, "fresh")
        #expect(fresh.origin.source == "asset://new")
        #expect(try s.completeAsyncBlock(fresh, metadata: ["alt": .string("Updated caption metadata")]).status == "applied")
        #expect(media(s)["src"] == .string("asset://new"))
    }
    @Test func concurrentDeletionPreventsValidPeerCompletionFromRecreatingContent() throws {
        let a = try session(), b = try session("b"), target = try begin(a)
        _ = try b.delete(ModernDeleteTarget(nodes: b.captureNodes([node(b)])))
        _ = try a.completeAsyncBlock(target, metadata: result); try exchange(a, b)
        #expect(a.document == b.document && !a.document.blocks.contains { $0.id == "media" })
        try a.undo(); try exchange(a, b)
        #expect(!a.document.blocks.contains { $0.id == "media" })
        try b.undo(); try exchange(a, b); #expect(a.document == b.document && media(a)["src"] == .string("asset://st140/coast"))
    }
    @Test func independentConcurrentMetadataRegistersComposeAndAuthorUndoRevealsPeerWinner() throws {
        let a = try session(), b = try session("b"), z = try session("z"), ta = try begin(a), tb = try begin(b), tz = try begin(z)
        _ = try a.completeAsyncBlock(ta, metadata: ["src": .string("asset://a"), "width": .number(640)])
        _ = try b.completeAsyncBlock(tb, metadata: ["alt": .string("peer")])
        _ = try z.completeAsyncBlock(tz, metadata: ["src": .string("asset://z"), "height": .number(480)])
        try exchange(a, b); try exchange(a, z); try exchange(b, z)
        #expect(a.document == b.document && b.document == z.document)
        #expect(media(a)["src"] == .string("asset://z") && media(a)["alt"] == .string("peer") && media(a)["width"] == .number(640) && media(a)["height"] == .number(480))
        try z.undo(); try exchange(a, z); #expect(media(a)["src"] == .string("asset://a") && media(a)["height"] == nil)
        try a.undo(); try exchange(a, z); #expect(media(a)["src"] == .string("asset://st140/coast") && media(a)["alt"] == .string("peer"))
    }
    @Test func fileInsertionAndCompletionAreSeparateStepsAndKeepConsumerPendingMetadata() throws {
        let s = try session(); _ = try s.insertBlock(Block(fields: file().object!), at: s.captureBoundary())
        let target = try begin(s, "file-upload", "file"), pending = s.document
        let metadata: [String: JSONValue] = ["src": .string("asset://fixture/notes"), "name": .string("研究😀.pdf"), "mimeType": .string("application/pdf"), "size": .number(240000)]
        #expect(try s.completeAsyncBlock(target, metadata: metadata).status == "applied")
        #expect(s.document.blocks[0].fields["consumer"] == file()["consumer"] && s.document.blocks[0].fields["name"] == .string("研究😀.pdf"))
        let completed = s.document; try s.undo(); #expect(s.document == pending)
        try s.undo(); #expect(s.document == (try fixture()))
        try s.redo(); #expect(s.document == pending); try s.redo(); #expect(s.document == completed)
        let cache = try s.exportAsyncRequests(), restored = try ModernSession.restore(s.save(), actorID: "a")
        try restored.restoreAsyncRequests(cache); #expect(restored.document == completed)
    }
    @Test func modernFileValidationDoesNotReinterpretLegacyOpaqueFiles() throws {
        let bad: [String: JSONValue] = ["id": .string("file"), "type": .string("file"), "name": .number(123)]
        #expect(throws: Never.self) { _ = try Document(blocks: [Block(fields: bad)]) }
        #expect(throws: (any Error).self) { _ = try ModernDocument(documentID: "file", title: "", blocks: [Block(fields: bad)]) }
        let s = try session()
        for size in [-1.0, 1.5, 9_007_199_254_740_992] {
            var fields = file().object!; fields["size"] = .number(size)
            try reject(s) { _ = try s.insertBlock(Block(fields: fields), at: s.captureBoundary()) }
        }
    }
    @Test func previewOnlyUpdatesDescriptiveMetadataAndExplicitNullRemovesOptionalValues() throws {
        let s = try session(), block = try Block(fields: ["id": .string("preview"), "type": .string("embed"), "url": .string("https://example.org/notes"), "title": .string("Pending"), "consumer": .object(["opaque": .string("keep")])])
        _ = try s.insertBlock(block, at: s.captureBoundary()); let target = try begin(s, "preview", "preview")
        _ = try s.completeAsyncBlock(target, metadata: ["title": .string("Notes"), "description": .string("Local provider result"), "thumbnail": .string("asset://fixture/thumbnail")])
        let updated = s.document.blocks[0].fields
        #expect(updated["url"] == block.fields["url"] && updated["consumer"] == block.fields["consumer"] && updated["title"] == .string("Notes"))
        let remove = try begin(s, "remove", "preview")
        _ = try s.completeAsyncBlock(remove, metadata: ["description": .null, "thumbnail": .null])
        #expect(s.document.blocks[0].fields["description"] == nil && s.document.blocks[0].fields["thumbnail"] == nil)
        try reject(s) { _ = try s.completeAsyncBlock(remove, metadata: ["url": .string("https://different.example")]) }
    }
    @Test func unchangedResultAndRepeatedDeliveryHaveNoHistoryAndNoAutomaticRedo() throws {
        let s = try session(), target = try begin(s), before = try s.save()
        let unchanged: [String: JSONValue] = ["src": .string(target.origin.source)]
        #expect(try s.completeAsyncBlock(target, metadata: unchanged).status == "noop")
        #expect(try s.save() == before && s.asyncRequests[0].status == .applied)
        #expect(try s.completeAsyncBlock(target, metadata: unchanged).status == "noop")
        #expect(try s.completeAsyncBlock(target, metadata: result).reason == "asyncAlreadyApplied")
        let restored = try ModernSession.restore(s.save(), actorID: "a"); try restored.restoreAsyncRequests(s.exportAsyncRequests())
        #expect(try restored.save() == before && restored.asyncRequests == s.asyncRequests)
    }
    @Test(arguments: [[:], ["id": JSONValue.string("new")], ["caption": .array([])], ["consumer": .object([:])], ["src": .null], ["width": .number(-1)], ["alt": .number(5)], ["height": .number(1.5)]])
    func invalidMetadataNeverChangesAcceptedHistoryOrRequestRecord(_ metadata: [String: JSONValue]) throws {
        let s = try session(), target = try begin(s)
        try reject(s) { _ = try s.completeAsyncBlock(target, metadata: metadata) }
    }
    @Test func localArchiveAndGenerationValidationAreAtomicAndCapacityNeedsExplicitForget() throws {
        let s = try session(), saved = try s.save()
        for index in 0..<64 { _ = try begin(s, "r\(index)") }
        try reject(s) { _ = try begin(s, "overflow") }
        try s.cancelAsyncBlock(s.asyncRequests.last!.target); try s.forgetAsyncBlock(s.asyncRequests[0].target)
        let next = try begin(s, "next"); #expect(next.generation == 65 && s.asyncRequests.count == 64)
        #expect(try s.save() == saved)
        let archive = try s.exportAsyncRequests(), target = try session("restored")
        let targetSaved = try target.save()
        var malformed = try JSONDecoder().decode(JSONValue.self, from: archive).object!
        malformed["generation"] = .number(0)
        try reject(target) { try target.restoreAsyncRequests(JSONEncoder().encode(JSONValue.object(malformed))) }
        var rows = malformed["requests"]!.array!; rows[0] = rows[1]; malformed["requests"] = .array(rows); malformed["generation"] = .number(65)
        try reject(target) { try target.restoreAsyncRequests(JSONEncoder().encode(JSONValue.object(malformed))) }
        try target.restoreAsyncRequests(archive); #expect(try target.save() == targetSaved && target.asyncRequests == s.asyncRequests)
        try reject(target) { try target.restoreAsyncRequests(archive) }
    }
    @Test func forgedSharedMetadataAndWrongSourceProofRejectEvenWhenInactive() throws {
        let s = try session(), target = try begin(s); _ = try s.completeAsyncBlock(target, metadata: result)
        let batch = try s.changes(), change = batch.changes[0]
        guard case .edit(let operations) = change.body, case .completeAsyncMetadata(let edit) = operations[0] else { Issue.record("Missing metadata edit"); return }
        let badOrigin = ModernAsyncOrigin(node: edit.origin.node, kind: .image, source: "asset://forged", observed: edit.origin.observed)
        let bad = ModernAsyncMetadataEdit(origin: badOrigin, metadata: result)
        let disabled = ModernChange(id: ChangeID(counter: 2, actor: "a"), observed: [change.id], body: .setActive(targets: [change.id], active: false))
        for hidden in [false, true] {
            let receiver = try session("receiver"), forged = ModernChange(id: change.id, observed: [], body: .edit([.completeAsyncMetadata(bad)]))
            try reject(receiver) { try receiver.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [forged] + (hidden ? [disabled] : []))) }
        }
        let receiver = try session("receiver")
        let forged = ModernChange(id: change.id, observed: [], body: .edit([.completeAsyncMetadata(edit), .setAppearance(field: "fontSize", value: "large")]))
        try reject(receiver) { try receiver.receive(ModernBatch(documentID: batch.documentID, epoch: batch.epoch, baseline: batch.baseline, changes: [forged, disabled])) }
    }
    @Test func forgedAppliedLocalReceiptCannotAcknowledgePendingOriginAfterReopen() throws {
        let s = try session(); _ = try begin(s)
        var archive = try JSONDecoder().decode(JSONValue.self, from: s.exportAsyncRequests()).object!, rows = archive["requests"]!.array!
        var row = rows[0].object!; row["status"] = .string("applied"); row["result"] = .object(result); row["receipt"] = .array([])
        rows[0] = .object(row); archive["requests"] = .array(rows)
        let restored = try session("restored")
        try reject(restored) { try restored.restoreAsyncRequests(JSONEncoder().encode(JSONValue.object(archive))) }
    }
    @Test func nearFullArchiveReservesFailureAndCancellationWithoutLosingAcceptedLocalState() throws {
        let baseline = try fixture()
        func archive(_ source: String) throws -> Data {
            let origin = ModernAsyncOrigin(node: .baseline(blockID: "media", path: []), kind: .image, source: source, observed: [])
            let records = (1...27).map { index in
                ModernAsyncRecord(target: ModernAsyncTarget(documentID: baseline.documentID, epoch: "async", requestID: "r\(index)", generation: UInt64(index), origin: origin),
                    status: index == 27 ? .pending : .cancelled, reason: index == 27 ? nil : "superseded")
            }
            return try canonicalEncoder().encode(ModernAsyncArchive(version: 1, documentID: baseline.documentID, epoch: "async", generation: 27, requests: records))
        }
        func fitted(_ headroom: Int) throws -> (ModernDocument, Data) {
            var low = 90_000, high = 100_000
            while low < high {
                let middle = (low + high + 1) / 2
                if try archive(String(repeating: "\0", count: middle)).count <= 16_000_000 - headroom { low = middle } else { high = middle - 1 }
            }
            let source = String(repeating: "\0", count: low)
            var fields = baseline.fields, blocks = fields["blocks"]!.array!, media = blocks.firstIndex { $0["id"] == .string("media") }!
            var image = blocks[media].object!; image["src"] = .string(source); blocks[media] = .object(image); fields["blocks"] = .array(blocks)
            return try (ModernDocument(fields: fields), archive(source))
        }
        // The first well-shaped archive fits the nominal limit but would lose
        // exportability when its pending provider reports a maximally escaped error.
        let (crowdedDocument, crowded) = try fitted(2000), crowdedSession = try session("a", crowdedDocument)
        #expect(crowded.count < 16_000_000 && crowded.count > 15_995_000)
        try reject(crowdedSession) { try crowdedSession.restoreAsyncRequests(crowded) }
        let (roomyDocument, roomy) = try fitted(6400), s = try session("a", roomyDocument), before = try s.save()
        try s.restoreAsyncRequests(roomy)
        let target = s.asyncRequests.last!.target, reason = String(repeating: "\0", count: 1000)
        try s.failAsyncBlock(target, reason: reason)
        #expect(try s.exportAsyncRequests().count <= 16_000_000 && s.save() == before && s.asyncRequests.last!.reason == reason)
        try s.cancelAsyncBlock(target)
        #expect(try s.exportAsyncRequests().count <= 16_000_000 && s.save() == before && s.asyncRequests.last!.status == .cancelled)
    }
    @Test func completionPublicationPreservesAnotherRequestFailureFromTheHostCallback() throws {
        let s = try session()
        _ = try s.insertBlock(Block(fields: ["id": .string("preview"), "type": .string("embed"), "url": .string("https://example.org")]), at: s.captureBoundary())
        let target = try begin(s), other = try begin(s, "other", "preview")
        var publications = 0
        s.onChange = { _, _ in
            publications += 1
            try? s.failAsyncBlock(other, reason: "Provider interrupted during publication")
        }
        #expect(try s.completeAsyncBlock(target, metadata: result).status == "applied")
        #expect(publications == 1 && s.asyncRequests.first!.status == .applied && s.asyncRequests.last!.status == .failed)
        #expect(s.asyncRequests.last!.reason == "Provider interrupted during publication")
        let restored = try ModernSession.restore(s.save(), actorID: "a")
        try restored.restoreAsyncRequests(s.exportAsyncRequests())
        #expect(restored.asyncRequests == s.asyncRequests && restored.document == s.document)
    }
}
