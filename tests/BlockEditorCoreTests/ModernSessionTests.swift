@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernSessionTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
    }
    private func fixture(_ name: String) throws -> ModernDocument {
        try ModernDocument(json: Data(contentsOf: fixtures.appendingPathComponent(name + ".json")))
    }
    private func session(_ actor: String, document: ModernDocument? = nil) throws -> ModernSession {
        let document = try document ?? ModernDocument(documentID: "modern", title: "A", blocks: [Block.paragraph(id: "p", text: "ab")])
        return try ModernSession(documentID: document.documentID, actorID: actor, epoch: "modern-1", document: document)
    }
    private func exchange(_ a: ModernSession, _ b: ModernSession) throws {
        let first = try a.changes(), second = try b.changes()
        try a.receive(second); try b.receive(first)
    }
    private func wire(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }

    @Test func independentTitleAppearanceFixturesPassSharedSessionPeerUndoRedoAndReopen() throws {
        let baseline = try fixture("unicode"), a = try session("a", document: baseline), b = try session("b", document: baseline)
        let both = try fixture("unicode-title-both"), sizeBoth = try fixture("unicode-title-size-both"), peer = try fixture("unicode-title-peer")
        try a.replaceTitle(range: 0..<0, with: "Studio ")
        try b.replaceTitle(range: baseline.title.utf16.count..<baseline.title.utf16.count, with: " 2026")
        try b.setAppearance(field: "pageWidth", value: "wide")
        try exchange(a, b)
        #expect(a.document == b.document && a.document == both)
        try a.setAppearance(field: "fontSize", value: "large")
        #expect(a.document == sizeBoth)
        let saved = try a.save(), resumed = try ModernSession.restore(saved, actorID: "a")
        #expect(try resumed.save() == saved && resumed.canUndo)
        try resumed.undo(); try resumed.undo(); try b.receive(resumed.changes())
        #expect(resumed.document == b.document && resumed.document == peer)
        try resumed.redo(); try resumed.redo(); try b.receive(resumed.changes())
        #expect(resumed.document == b.document && resumed.document == sizeBoth)
        let fresh = try ModernSession.restore(resumed.save(), actorID: "fresh")
        #expect(fresh.document == resumed.document && !fresh.canUndo && !fresh.canRedo)
        #expect(resumed.document.blocks == baseline.blocks)
    }

    @Test(arguments: [false, true])
    func independentAppearanceRegistersAndSameFieldWinsConvergeAcrossOrder(_ reverse: Bool) throws {
        let a = try session("a"), b = try session("b"), baseline = a.baseline
        try a.setAppearance(field: "fontSize", value: "large")
        try b.setAppearance(field: "pageWidth", value: "wide")
        try exchange(a, b)
        #expect(a.document == b.document && a.document.appearance.fontSize == .large && a.document.appearance.pageWidth == .wide)
        let c = try session("a"), d = try session("z")
        try c.setAppearance(field: "fontFamily", value: "serif"); try d.setAppearance(field: "fontFamily", value: "monospace")
        let receiver = try session("receiver")
        for packet in reverse ? [try d.changes(), try c.changes()] : [try c.changes(), try d.changes()] { try receiver.receive(packet) }
        #expect(receiver.document.appearance.fontFamily == .monospace)
        try d.undo(); try receiver.receive(d.changes())
        #expect(receiver.document.appearance.fontFamily == .serif && receiver.document.blocks == baseline.blocks)
        try d.redo(); try receiver.receive(d.changes()); #expect(receiver.document.appearance.fontFamily == .monospace)
    }

    @Test func typingGroupUndoRetainsPeerAtomsAndHistoryOrderAcrossReopen() throws {
        let a = try session("a"), b = try session("b"), field = try a.field(node: a.node(at: NodeAddress("p")))
        try a.replaceText(in: field, range: 2..<2, with: "X", typingGroup: "input-1")
        try a.replaceText(in: field, range: 3..<3, with: "Y", typingGroup: "input-1")
        try b.receive(a.changes()); try b.replaceText(in: field, range: 3..<3, with: "Z")
        try a.receive(b.changes())
        #expect(try a.text(in: field) == "abXZY")
        let restored = try ModernSession.restore(a.save(), actorID: "a")
        try restored.undo(); #expect(try restored.text(in: field) == "abZ" && !restored.canUndo)
        try restored.redo(); #expect(try restored.text(in: field) == "abXZY")
        restored.endTypingGroup()
        try restored.replaceText(in: field, range: 5..<5, with: "M", typingGroup: "input-2")
        try restored.setAppearance(field: "fontFamily", value: "serif")
        try restored.replaceText(in: field, range: 6..<6, with: "N", typingGroup: "input-2")
        try restored.undo(); try restored.undo(); try restored.undo()
        #expect(try restored.text(in: field) == "abXZY" && restored.document.appearance.fontFamily == .sans)
        let reopened = try ModernSession.restore(restored.save(), actorID: "a")
        try reopened.redo(); #expect(try reopened.text(in: field) == "abXZYM")
        try reopened.redo(); #expect(reopened.document.appearance.fontFamily == .serif)
        try reopened.redo(); #expect(try reopened.text(in: field) == "abXZYMN")
    }

    @Test func anchoredBackwardRangeRetainsUnobservedPeerTextAndUnicodeCaret() throws {
        let document = try ModernDocument(documentID: "unicode", title: "😀é", blocks: [Block.paragraph(id: "p", text: "abcd")])
        let a = try session("a", document: document), b = try session("b", document: document)
        let field = try a.field(node: a.node(at: NodeAddress("p")))
        let range = try a.captureTextRange(in: field, start: 3, end: 1)
        try b.replaceText(in: field, range: 2..<2, with: "X"); try a.receive(b.changes())
        let caret = try a.replaceText(in: range, with: "😀")
        #expect(try a.text(in: field) == "a😀Xd" && a.resolve(caret).offset == 3)
        #expect(throws: EditorError.invalidRange) { try a.replaceTitle(range: 1..<1, with: "bad") }
        let saved = try a.save()
        #expect(throws: EditorError.invalidChange) { try a.replaceTitle(range: 0..<0, with: "\n") }
        #expect(try a.save() == saved && a.document.title == "😀é")
    }

    @Test func bodyFieldsInsideColumnsRemainDistinctAndLiteralAtomsRejectRichMarks() throws {
        let baseline = try fixture("columns-rich"), a = try session("a", document: baseline)
        let seed = ModernProjectionSeed(baseline)
        let body = try #require(seed.fields.first { $0.name == "content" })
        let before = try a.text(in: body)
        try a.replaceText(in: body, range: before.utf16.count..<before.utf16.count, with: "😀")
        #expect(try a.text(in: body) == before + "😀" && a.document.title == baseline.title)
        try a.format(in: body, range: 0..<(before.utf16.count + 2), markType: "semantic-color", mark: .object(["type": .string("semantic-color"), "value": .string("blue")]))
        try a.undo(); try a.undo(); #expect(a.document == baseline)
        let literal = try #require(seed.fields.first { $0.name == "code" })
        let saved = try a.save()
        #expect(throws: EditorError.invalidChange) { try a.format(in: literal, range: 0..<0, markType: "bold", mark: .object(["type": .string("bold")])) }
        #expect(try a.save() == saved)
    }

    @Test func mismatchedScopeUnsupportedFormatDuplicateKeysAndLossyNumbersRejectUnchanged() throws {
        let a = try session("a"), saved = try a.save(), baseline = a.baseline
        for packet in [ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: baseline, changes: [], version: 6),
                       ModernBatch(documentID: "other", epoch: a.epoch, baseline: baseline, changes: []),
                       ModernBatch(documentID: a.documentID, epoch: "old", baseline: baseline, changes: [])] {
            #expect(throws: (any Error).self) { try a.receive(packet) }
        }
        #expect(throws: EditorError.differentDocument) { try ModernSession(documentID: "other", actorID: "a", epoch: "valid", document: baseline) }
        var root = try #require(JSONDecoder().decode(JSONValue.self, from: a.changes().json()).object)
        var wrong = baseline.fields; wrong["formatVersion"] = .number(2); root["baseline"] = .object(wrong)
        #expect(throws: (any Error).self) { try ModernBatch(json: wire(.object(root))) }
        for raw in [#"{"version":7,"version":6}"#, #"{"version":7,"\u0076ersion":6}"#, #"{"number":9007199254740993}"#] {
            #expect(throws: (any Error).self) { try ModernBatch(json: Data(raw.utf8)) }
        }
        #expect(throws: (any Error).self) { try a.changes(since: WritingSyncState(documentID: a.documentID, epoch: "old", version: 7)) }
        #expect(try a.save() == saved && a.mergeRecovery == nil)
        #expect(throws: (any Error).self) { try WritingSession.restore(saved, actorID: "a") }
    }

    @Test(arguments: [false, true])
    func malformedPlainTitleAndInactiveTransactionsNeverAcknowledge(_ inactive: Bool) throws {
        let a = try session("a"), saved = try a.save(), receipt = a.syncState
        let id = ChangeID(counter: 1, actor: "remote"), field = a.titleField
        for node in [textNode("\n"), textNode("X", marks: [.object(["type": .string("bold")])]),
                     .object(["type": .string("text"), "text": .string("X"), "hidden": .string("drop")]),
                     .object(["type": .string("entity-ref"), "entityId": .string("id"), "entityType": .string("note"), "label": .string("X")])] {
            let atom = WritingAtomSeed(key: WritingAtomKey(origin: field, element: ElementID(change: id, index: 0)), node: node, edge: .start, route: .field(field))
            var changes = [ModernChange(id: id, observed: [], body: .edit([.text(.insert(atom))]))]
            if inactive { changes.append(ModernChange(id: ChangeID(counter: 2, actor: "remote"), observed: [id], body: .setActive(targets: [id], active: false))) }
            #expect(throws: EditorError.invalidChange) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: changes)) }
            #expect(try a.save() == saved && a.syncState == receipt && a.mergeRecovery == nil)
        }
    }

    @Test func unobservedReferencesDuplicateBirthsCrossFieldRoutesAndForeignUndoReject() throws {
        let a = try session("a"), b = try session("b")
        try b.replaceTitle(range: 1..<1, with: "B"); try a.receive(b.changes())
        let saved = try a.save(), packet = try b.changes(), first = try #require(packet.changes.first), id = ChangeID(counter: 2, actor: "bad")
        let anchor = WritingAtomKey(origin: b.titleField, element: ElementID(change: first.id, index: 0))
        let inserted = WritingAtomSeed(key: WritingAtomKey(origin: b.titleField, element: ElementID(change: id, index: 0)), node: textNode("X"), edge: .after(anchor), route: .follow(anchor))
        let body = try a.field(node: a.node(at: NodeAddress("p")))
        let wrongRoute = WritingAtomSeed(key: WritingAtomKey(origin: body, element: ElementID(change: id, index: 0)), node: textNode("X"), edge: .after(anchor), route: .follow(anchor))
        for change in [ModernChange(id: id, observed: [], body: .edit([.text(.insert(inserted))])),
                       ModernChange(id: id, observed: [first.id], body: .edit([.text(.insert(inserted)), .text(.insert(inserted))])),
                       ModernChange(id: id, observed: [first.id], body: .edit([.text(.insert(wrongRoute))])),
                       ModernChange(id: id, observed: [first.id], body: .setActive(targets: [first.id], active: false))] {
            #expect(throws: EditorError.invalidChange) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [change])) }
            #expect(try a.save() == saved && a.mergeRecovery == nil)
        }
        var conflicting = try #require(JSONDecoder().decode(JSONValue.self, from: b.changes().json()).object)
        var changes = try #require(conflicting["changes"]?.array), change = try #require(changes[0].object)
        change["observed"] = .array([.object(["actor": .string("other"), "counter": .number(1)])]); changes[0] = .object(change); conflicting["changes"] = .array(changes)
        #expect(throws: EditorError.conflictingChange) { try a.receive(ModernBatch(json: wire(.object(conflicting)))) }
        #expect(try a.save() == saved)
    }

    @Test func missingCausalPacketIsSeparatelyRecoverableWithoutReceiptThenAcceptsUnion() throws {
        let author = try session("author"), receiver = try session("receiver")
        try author.replaceTitle(range: 1..<1, with: "B"); let first = try author.changes(), firstReceipt = author.syncState
        try author.replaceTitle(range: 2..<2, with: "C"); let second = try author.changes(since: firstReceipt)
        let saved = try receiver.save(), receipt = receiver.syncState
        #expect(throws: (any Error).self) { try receiver.receive(second) }
        #expect(try receiver.save() == saved && receiver.mergeRecovery != nil && receiver.syncState == receipt)
        let exported = try receiver.exportRecovery(), pending = try #require(exported), restored = try ModernSession.restore(saved, actorID: "receiver")
        #expect(throws: (any Error).self) { try restored.restoreRecovery(pending) }
        #expect(throws: (any Error).self) { try restored.replaceTitle(range: 0..<0, with: "blocked") }
        try restored.receive(first)
        #expect(restored.document == author.document && restored.mergeRecovery == nil && restored.syncState.received.count == 2)
        #expect(!restored.canUndo)
    }

    @Test func compositionHoldPreservesLocalDraftBoundaryQueuesNoReceiptAndReleasesOnce() throws {
        let a = try session("a"), b = try session("b"), release = try a.holdRemoteChanges()
        let saved = try a.save(), receipt = a.syncState
        a.isComposing = true
        try b.replaceTitle(range: 1..<1, with: "peer")
        try a.receive(b.changes())
        #expect(try a.save() == saved && a.syncState == receipt)
        #expect(try JSONDecoder().decode(JSONValue.self, from: a.exportDeferredChanges()).array?.count == 1)
        #expect(throws: ModernSessionError.compositionActive) { try a.replaceTitle(range: 0..<0, with: "draft") }
        a.isComposing = false
        try a.replaceTitle(range: 0..<0, with: "draft ")
        try release(); let after = try a.save(); try release()
        #expect(try a.save() == after && a.document.title == "draft Apeer" && a.syncState.received.count == 2)
        #expect(try JSONDecoder().decode(JSONValue.self, from: a.exportDeferredChanges()).array == [])
    }

    @Test func invalidDeferredPacketRemainsExportableAndQueueLimitDoesNotAcknowledge() throws {
        let a = try session("a"), release = try a.holdRemoteChanges(), receipt = a.syncState
        let id = ChangeID(counter: 1, actor: "remote"), change = ModernChange(id: id, observed: [], body: .edit([.setAppearance(field: "fontSize", value: "huge")]))
        let packet = ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [change])
        for _ in 0..<64 { try a.receive(packet) }
        #expect(throws: EditorError.recoveryCapacityExceeded) { try a.receive(packet) }
        #expect(a.syncState == receipt)
        #expect(throws: EditorError.invalidChange) { try release() }
        #expect(a.syncState == receipt && a.mergeRecovery == nil)
        #expect(try JSONDecoder().decode(JSONValue.self, from: a.exportDeferredChanges()).array?.count == 64)
    }

    @Test func unknownWireFieldsAndMalformedSavedHistoryRejectRatherThanDisappear() throws {
        let a = try session("a")
        try a.replaceTitle(range: 1..<1, with: "B")
        var value = try #require(JSONDecoder().decode(JSONValue.self, from: a.changes().json()).object)
        value["ignored"] = .bool(true)
        #expect(throws: (any Error).self) { try ModernBatch(json: wire(.object(value))) }
        value.removeValue(forKey: "ignored")
        var changes = try #require(value["changes"]?.array), change = try #require(changes[0].object)
        change["ignored"] = .bool(true); changes[0] = .object(change); value["changes"] = .array(changes)
        #expect(throws: (any Error).self) { try ModernBatch(json: wire(.object(value))) }
        var saved = try #require(JSONDecoder().decode(JSONValue.self, from: a.save()).object), local = try #require(saved["localHistory"]?.object)
        local["redo"] = local["undo"]; saved["localHistory"] = .object(local)
        #expect(throws: (any Error).self) { try ModernSession.restore(wire(.object(saved)), actorID: "a") }
        #expect(throws: (any Error).self) { try ModernSession.restore(wire(.object(saved)), actorID: "fresh") }
    }

    @Test func callbacksObserveFinalHistoryAndCannotReenterPublication() throws {
        let a = try session("a"), b = try session("b")
        var seen: [[Bool]] = [], rejected = false
        a.onChange = { _, _ in seen.append([a.canUndo, a.canRedo]); do { try a.setAppearance(field: "fontSize", value: "large") } catch { rejected = true } }
        try a.replaceTitle(range: 1..<1, with: "B"); try a.undo(); try a.redo()
        #expect(seen == [[true, false], [false, true], [true, false]] && rejected)
        a.onWillReceive = { do { try a.receive(b.changes()) } catch { rejected = true } }
        try b.replaceTitle(range: 0..<0, with: "peer "); try a.receive(b.changes())
        #expect(a.document.title == "peer AB")
    }

    @Test func schemaUnionRecoveryRetainsBothAuthorsAndRepairDisablesOnlyOwnEdit() throws {
        let math = try Block(fields: ["id": .string("m"), "type": .string("math"), "expression": .string("xy")])
        let baseline = try ModernDocument(documentID: "math", title: "keep", blocks: [math])
        let a = try session("a", document: baseline), b = try session("b", document: baseline)
        let field = try a.field(node: a.node(at: NodeAddress("m")), name: "expression")
        try a.replaceText(in: field, range: 0..<1, with: ""); try b.replaceText(in: field, range: 1..<2, with: "")
        let saved = try a.save(), receipt = a.syncState, aEdit = try #require(receipt.received.first)
        #expect(throws: (any Error).self) { try a.receive(b.changes()) }
        #expect(try a.save() == saved && a.syncState == receipt && a.document.blocks[0].fields["expression"] == .string("y"))
        let exported = try a.exportRecovery(), pending = try #require(exported)
        let restored = try ModernSession.restore(saved, actorID: "a")
        #expect(throws: (any Error).self) { try restored.restoreRecovery(pending) }
        #expect(throws: (any Error).self) { try restored.undo() }
        let peerEdit = try #require(b.syncState.received.first)
        #expect(throws: EditorError.invalidChange) { try restored.repairUndo([peerEdit]) }
        try restored.repairUndo([aEdit]); try b.receive(restored.changes())
        #expect(restored.mergeRecovery == nil && restored.document == b.document && restored.document.blocks[0].fields["expression"] == .string("x"))
        #expect(!restored.canUndo && restored.canRedo && restored.syncState.received.count == 3)
        #expect(throws: (any Error).self) { try restored.redo() }
        #expect(restored.mergeRecovery != nil && restored.document.blocks[0].fields["expression"] == .string("x"))
        try restored.repairUndo([aEdit]); #expect(restored.mergeRecovery == nil && restored.canRedo)
    }

    @Test func noopsAndFailedCommandsPreserveAcceptedHistoryAndCompositionEndsTypingGroup() throws {
        let a = try session("a"), field = try a.field(node: a.node(at: NodeAddress("p")))
        let initial = try a.save()
        try a.setAppearance(field: "fontSize", value: "default"); try a.replaceText(in: field, range: 0..<0, with: "")
        #expect(try a.save() == initial && !a.canUndo)
        try a.replaceText(in: field, range: 2..<2, with: "X", typingGroup: "input")
        a.isComposing = true
        #expect(throws: ModernSessionError.compositionActive) { try a.setAppearance(field: "fontSize", value: "large") }
        a.isComposing = false
        try a.replaceText(in: field, range: 3..<3, with: "Y", typingGroup: "input")
        try a.undo(); #expect(try a.text(in: field) == "abX" && a.canUndo)
        let saved = try a.save()
        #expect(throws: EditorError.invalidChange) { try a.setAppearance(field: "fontSize", value: "huge") }
        #expect(try a.save() == saved && a.canRedo)
    }

    @Test func malformedOperationWithMissingDependencyRejectsInsteadOfCreatingRecovery() throws {
        let a = try session("a"), saved = try a.save()
        let missing = ChangeID(counter: 1, actor: "missing"), id = ChangeID(counter: 2, actor: "remote")
        let change = ModernChange(id: id, observed: [missing], body: .edit([.setAppearance(field: "fontSize", value: "huge")]))
        #expect(throws: EditorError.invalidChange) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [change])) }
        #expect(try a.save() == saved && a.mergeRecovery == nil)
        var payload: JSONValue = .bool(true)
        for _ in 0..<101 { payload = .object(["nested": payload]) }
        let field = try a.field(node: a.node(at: NodeAddress("p")))
        var node = textNode("X").object!; node["host"] = payload
        let atom = WritingAtomSeed(key: WritingAtomKey(origin: field, element: ElementID(change: id, index: 0)), node: .object(node), edge: .start, route: .field(field))
        let deep = ModernChange(id: id, observed: [], body: .edit([.text(.insert(atom))]))
        #expect(throws: EditorError.invalidChange) { try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [deep])) }
        #expect(try a.save() == saved && a.mergeRecovery == nil)
    }

    @Test func packetCountRawBytesAndHeldBytesUseIndependentLimitsWithoutReceipt() throws {
        let a = try session("a"), receipt = a.syncState
        let change = ModernChange(id: ChangeID(counter: 1, actor: "remote"), observed: [], body: .edit([.setAppearance(field: "fontSize", value: "large")]))
        #expect(throws: EditorError.recoveryCapacityExceeded) {
            try a.receive(ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: Array(repeating: change, count: 100_001)))
        }
        #expect(throws: EditorError.recoveryCapacityExceeded) { try ModernBatch(json: Data(repeating: 32, count: 64_000_001)) }
        let release = try a.holdRemoteChanges()
        let large = ModernChange(id: change.id, observed: [], body: .edit([.setAppearance(field: "fontSize", value: String(repeating: "x", count: 32_000_000))]))
        let packet = ModernBatch(documentID: a.documentID, epoch: a.epoch, baseline: a.baseline, changes: [large])
        try a.receive(packet)
        #expect(throws: EditorError.recoveryCapacityExceeded) { try a.receive(packet) }
        #expect(a.syncState == receipt && a.mergeRecovery == nil)
        #expect(throws: EditorError.invalidChange) { try release() }
        #expect(a.syncState == receipt && a.mergeRecovery == nil)
    }

}
