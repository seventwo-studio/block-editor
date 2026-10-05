import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernMigrationTests {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json"))
    }
    private func json<Value: Encodable>(_ value: Value) throws -> Data { try canonicalEncoder().encode(value) }
    private func make(_ plan: ModernCutoverPreparation) throws -> ModernSession {
        try plan.makeSession(actorID: "a", archiveReadback: plan.archiveBytes, oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true)
    }
    @Test(arguments: ["mixed", "5001"])
    func independentLegacyFixturesMigrateWithoutChangingAnyFieldOrAllocatingHistory(_ kind: String) throws {
        let raw = try fixture("legacy-" + kind), expected = try ModernDocument(json: fixture("migrated-" + kind))
        let archive = ModernCutoverArchive(documentID: expected.documentID, epoch: "modern", source: .document(format: .documentObject, bytes: raw), originals: [raw])
        let plan = try ProtocolMigration.prepareModernCutover(archive), session = try make(plan)
        #expect(plan.document == expected && session.document == expected && !session.canUndo && !session.canRedo)
        #expect(try session.changes().changes.isEmpty && session.syncState.received.isEmpty && session.localSelection == nil)
        let decoded = try ModernCutoverArchive(json: plan.archiveBytes); #expect(decoded == archive && decoded.originals == [raw])
        if case .document(_, let retained) = decoded.source { #expect(retained == raw) } else { Issue.record("Missing original") }
        let r = try ModernSession.restore(session.save(), actorID: "a"); #expect(r.document == expected)
        #expect(plan.originMapping.filter { $0.address.path.isEmpty }.count == expected.blocks.count)
        for entry in plan.originMapping {
            #expect(entry.target == .baseline(blockID: entry.address.blockID, path: entry.address.path))
            #expect(entry.source == .legacyPath(entry.address))
            if kind == "mixed" { #expect(try entry.target == session.node(at: entry.address)) }
        }
        if kind == "5001" {
            #expect(plan.originMapping.map(\.address.blockID) == expected.blocks.map(\.id))
            #expect(plan.originMapping.allSatisfy { $0.address.path.isEmpty })
        }
    }
    @Test func blockArrayAndExtendedEnvelopeKeepExistingTitleAppearanceAndOpaqueMetadata() throws {
        let raw = Data(#" [ {"id":"A","type":"paragraph","content":[{"type":"text","text":"世界😀","marks":[{"type":"bold"}]}],"vendor":{"columns":["opaque"]}} ] "#.utf8)
        let plan = try ProtocolMigration.prepareModernCutover(ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: raw)))
        #expect(plan.document.title == "" && plan.document.appearance == .default && plan.document.blocks[0].text == "世界😀")
        var fields: [String: JSONValue] = ["blocks": .array(plan.document.blocks.map { .object($0.fields) }), "title": .string("Existing title"),
            "appearance": .object(["fontFamily": .string("serif"), "fontSize": .string("large"), "pageWidth": .string("wide"), "vendor": .bool(true)]), "vendor": .array([.string("preserve")])]
        let kept = try ProtocolMigration.prepareModernCutover(ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .documentObject, bytes: json(fields))))
        #expect(kept.document.title == "Existing title" && kept.document.fields["vendor"] == fields["vendor"] && kept.document.fields["appearance"] == fields["appearance"])
        fields["documentID"] = .string("foreign")
        #expect(throws: ModernCutoverError.incompatibleRepresentation) { try ProtocolMigration.prepareModernCutover(ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .documentObject, bytes: json(fields)))) }
    }
    @Test func thousandsOfEmptyContainersKeepEveryOriginWithoutRepeatingCollectionReplay() throws {
        let blocks: [JSONValue] = (0..<5001).map {
            .object(["id": .string("toggle-\($0)"), "type": .string("toggle"), "summary": .array([]),
                     "children": .array([]), "vendor": .object(["items": .array([.string("opaque")])])])
        }
        let raw = try json(blocks)
        let plan = try ProtocolMigration.prepareModernCutover(ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: raw)))
        #expect(plan.document.fields["blocks"] == .array(blocks))
        #expect(plan.originMapping.count == 5001)
        for (index, entry) in plan.originMapping.enumerated() {
            #expect(entry.address == NodeAddress("toggle-\(index)"))
            #expect(entry.target == .baseline(blockID: "toggle-\(index)", path: []))
            #expect(entry.source == .legacyPath(entry.address))
        }
    }
    @Test(arguments: ["legacy-collision", "unsupported-inline"])
    func incompatibleIndependentFixturesRemainExactAndNeverActivate(_ name: String) throws {
        let raw = try fixture(name), archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .documentObject, bytes: raw))
        #expect(throws: ModernCutoverError.incompatibleRepresentation) { try ProtocolMigration.prepareModernCutover(archive) }
        #expect(try ModernCutoverArchive(json: archive.json()) == archive)
    }
    @Test func reservedBlockRegistersAndNestedLayoutsRejectWithoutRetypingConsumerJSON() throws {
        for fields in [#"{"id":"A","type":"paragraph","semanticColor":"neutral"}"#, #"{"id":"A","type":"file","src":"asset://A","name":"File"}"#,
                       #"{"id":"A","type":"toggle","summary":[],"children":[{"id":"C","type":"columns","columns":[] }]}"#] {
            let raw = Data(("[" + fields + "]").utf8), archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: raw))
            #expect(throws: ModernCutoverError.incompatibleRepresentation) { try ProtocolMigration.prepareModernCutover(archive) }
        }
    }
    @Test(arguments: [1,2,3,4,5,6])
    func allLegacySessionVersionsRequireAllOfflineChangesAndKeepOldUndoOnlyInTheArchive(_ version: Int) throws {
        let d = try Document(blocks: [Block.paragraph(id: "p", text: "ABC")])
        let accepted: Data, reconciled: Data, packet: Data
        if version <= 2 {
            let a = try EditorSession(documentID: "d", actorID: "a", document: d, collaborationVersion: version), b = try EditorSession(documentID: "d", actorID: "b", document: d, collaborationVersion: version)
            try a.replaceText(at: TextAddress("p"), range: 0..<0, with: "L"); accepted = try a.save()
            try b.replaceText(at: TextAddress("p"), range: 3..<3, with: "R"); packet = try json(b.changes()); try a.receive(b.changes()); reconciled = try a.save()
        } else {
            let a = try WritingSession(documentID: "d", actorID: "a", epoch: "old", document: d, protocolVersion: version), b = try WritingSession(documentID: "d", actorID: "b", epoch: "old", document: d, protocolVersion: version)
            try a.replaceText(at: TextAddress("p"), range: 0..<0, with: "L"); accepted = try a.save()
            try b.replaceText(at: TextAddress("p"), range: 3..<3, with: "R"); packet = try json(b.changes()); try a.receive(b.changes()); reconciled = try a.save()
        }
        let premature = ModernCutoverArchive(documentID: "d", epoch: "new", source: .session(acceptedSnapshot: accepted, reconciledSnapshot: accepted, pendingRecovery: nil, unacknowledged: [packet]))
        #expect(throws: ModernCutoverError.unreconciledInput) { try ProtocolMigration.prepareModernCutover(premature) }
        let archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .session(acceptedSnapshot: accepted, reconciledSnapshot: reconciled, pendingRecovery: nil, unacknowledged: [packet]), originals: [Data("native settled draft".utf8)])
        let plan = try ProtocolMigration.prepareModernCutover(archive), session = try make(plan)
        #expect(session.document.blocks[0].text == "LABCR" && !session.canUndo && !session.canRedo && session.syncState.received.isEmpty)
        if version <= 2 { #expect(try EditorSession.restore(accepted, actorID: "a").canUndo) } else { #expect(try WritingSession.restore(accepted, actorID: "a").canUndo) }
        #expect(try ModernCutoverArchive(json: plan.archiveBytes) == archive)
        try session.replaceTitle(range: 0..<0, with: "Title"); try session.undo(); #expect(session.document.blocks[0].text == "LABCR" && session.document.title == "")
        if version >= 3 {
            let same = ModernCutoverArchive(documentID: "d", epoch: "old", source: archive.source)
            #expect(throws: ModernCutoverError.sameEpoch) { try ProtocolMigration.prepareModernCutover(same) }
        }
    }
    @Test func archiveReadbackAndEveryAcknowledgmentAreRequiredBeforeCreatingANewSession() throws {
        let archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: Data("[]".utf8))), plan = try ProtocolMigration.prepareModernCutover(archive)
        for index in 0..<3 {
            #expect(throws: ModernCutoverError.acknowledgmentsRequired) { try plan.makeSession(actorID: "a", archiveReadback: plan.archiveBytes, oldWritersStopped: index != 0, archivePersisted: index != 1, resetUndoAcknowledged: index != 2) }
        }
        #expect(throws: ModernCutoverError.archiveReadbackMismatch) { try plan.makeSession(actorID: "a", archiveReadback: Data("wrong".utf8), oldWritersStopped: true, archivePersisted: true, resetUndoAcknowledged: true) }
        #expect(try make(plan).document.blocks.isEmpty)
    }
    @Test func malformedDuplicateNumericUnknownArchiveOrWrongSourceFormatNeverDropsOriginalData() throws {
        for raw in [#"[{"id":"A","id":"B","type":"paragraph"}]"#, #"[{"id":"A","type":"opaque","value":9007199254740993}]"#, "{}"] {
            let archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: Data(raw.utf8)))
            #expect(throws: (any Error).self) { try ProtocolMigration.prepareModernCutover(archive) }
        }
        let archive = ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: Data("[]".utf8)))
        var wire = try #require(JSONDecoder().decode(JSONValue.self, from: archive.json()).object); wire["unknown"] = .bool(true)
        #expect(throws: (any Error).self) { try ModernCutoverArchive(json: json(wire)) }
    }
    @Test func movedInsertedAndRepeatedScopedOriginsMapExplicitlyAndOldAnchorsNeverEnterTheNewEpoch() throws {
        let d = try Document(blocks: [Block.paragraph(id: "p", text: "ABC"), Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([]), "children": .array([.object(try Block.paragraph(id: "p", text: "Nested").fields)])])])
        let old = try WritingSession(documentID: "d", actorID: "a", epoch: "old", document: d, protocolVersion: 6)
        let accepted = try old.save(), original = try old.position(at: TextAddress("p"), offset: 2)
        let inserted = try old.insertCollectionNodes([.object(try Block.paragraph(id: "I", text: "New").fields)], into: .root)
        let owner = try old.node(at: NodeAddress("toggle")), child = try old.node(at: NodeAddress("toggle", path: ["children", "p"]))
        _ = try old.move(inserted, into: NodeCollection(owner: owner, field: "children"), after: child)
        let insertedCaret = try old.position(at: old.textAddress(of: inserted.nodes[0]), offset: 1)
        let archive = try ModernCutoverArchive(documentID: "d", epoch: "new", source: .session(acceptedSnapshot: accepted, reconciledSnapshot: old.save(), pendingRecovery: nil, unacknowledged: []))
        let plan = try ProtocolMigration.prepareModernCutover(archive), fresh = try make(plan), remapped = try plan.remap(original)
        #expect(try remapped.epoch == "new" && remapped != original && fresh.resolve(remapped).offset == 2)
        let insertedRemap = try plan.remap(insertedCaret)
        #expect(try fresh.resolve(insertedRemap).offset == 1 && insertedRemap.field.node == fresh.node(at: NodeAddress("toggle", path: ["children", "I"])))
        #expect(plan.originMapping.contains { $0.source == .origin(inserted.nodes[0]) && $0.address == NodeAddress("toggle", path: ["children", "I"]) })
        #expect(throws: ModernSessionError.incompatibleEpoch) { try fresh.resolve(original) }
        #expect(plan.originMapping.contains { $0.address == NodeAddress("p") } && plan.originMapping.contains { $0.address == NodeAddress("toggle", path: ["children","p"]) })
    }
    @Test func rejectedUnionRequiresExplicitRepairAndEveryRejectedChangeRemainsInTheArchive() throws {
        let d = try Document(blocks: [Block.paragraph(id: "p", text: "ABC")])
        let a = try WritingSession(documentID: "d", actorID: "a", epoch: "old", document: d, protocolVersion: 6), b = try WritingSession(documentID: "d", actorID: "b", epoch: "old", document: d, protocolVersion: 6)
        _ = try a.insertCollectionNodes([.object(try Block.paragraph(id: "shared", text: "A").fields)], into: .root)
        _ = try b.insertCollectionNodes([.object(try Block.paragraph(id: "shared", text: "B").fields)], into: .root)
        let accepted = try a.save()
        #expect(throws: (any Error).self) { try a.receive(b.changes()) }
        let pending = try json(#require(a.mergeRecovery)), own = try #require(a.changes().changes.first { $0.id.actor == "a" })
        let premature = ModernCutoverArchive(documentID: "d", epoch: "new", source: .session(acceptedSnapshot: accepted, reconciledSnapshot: accepted, pendingRecovery: pending, unacknowledged: []))
        #expect(throws: ModernCutoverError.unreconciledInput) { try ProtocolMigration.prepareModernCutover(premature) }
        try a.repairUndo(own.id)
        let archive = try ModernCutoverArchive(documentID: "d", epoch: "new", source: .session(acceptedSnapshot: accepted, reconciledSnapshot: a.save(), pendingRecovery: pending, unacknowledged: [json(b.changes())]))
        let plan = try ProtocolMigration.prepareModernCutover(archive), fresh = try make(plan)
        #expect(fresh.document.blocks.map(\.text) == ["B", "ABC"] && !fresh.canUndo && !fresh.canRedo)
        #expect(try ModernCutoverArchive(json: plan.archiveBytes) == archive)
        #expect(try WritingSession.restore(accepted, actorID: "a").document.blocks.map(\.text) == ["A", "ABC"])
    }
}
