@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernCapacitySizingTests {
    @Test func placeholderSizingMatchesPublicWireForIndependentBaselinesAndAllChangeBodies() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
        let id = ChangeID(counter: 9_007_199_254_740_991, actor: "writer/東京\"e\u{301}")
        let field = WritingField(node: .document(documentID: "document"), name: "title")
        let edit = ModernChange(id: id, observed: [], body: .edit([.text(.insert(WritingAtomSeed(
            key: WritingAtomKey(origin: field, element: ElementID(change: id, index: 0)),
            node: .object(["type": .string("text"), "text": .string("😀"), "opaque": .number(-0.0)]),
            edge: .start, route: .field(field))))]))
        let toggle = ModernChange(id: ChangeID(counter: 2, actor: "other"), observed: [id], body: .setActive(targets: [id], active: false))
        var modernCount = 0, legacyCount = 0
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let bytes = try Data(contentsOf: url), value = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard value["format"] == .string(ModernDocument.format) else {
                #expect(throws: (any Error).self) { try ModernDocument(json: bytes) }
                legacyCount += 1; continue
            }
            let baseline = try ModernDocument(json: bytes)
            modernCount += 1
            let baselineBytes = try baseline.json().count
            for changes in [[], [edit], [edit, toggle]] {
                let batch = ModernBatch(documentID: baseline.documentID, epoch: "epoch\"\\/世界", baseline: baseline, changes: changes)
                #expect(try batch.capacityByteCount(baselineByteCount: baselineBytes) == batch.json().count)
            }
        }
        #expect(modernCount == 55 && legacyCount == 4)
    }

    @Test func capacityReadDoesNotChangeSavedHistoryOrRetainOldSessionBaseline() throws {
        for opaque in ["😀\"\\\u{0000}", String(repeating: "opaque", count: 10_000)] {
            var fields = try ModernDocument(documentID: "capacity", blocks: [.paragraph(id: "p", text: "A😀")]).fields
            fields["opaque"] = .string(opaque)
            let document = try ModernDocument(fields: fields)
            let s = try ModernSession(documentID: "capacity", actorID: "a", epoch: "e", document: document)
            let field = try s.field(node: s.node(at: NodeAddress("p")))
            _ = try s.replaceText(in: s.captureTextRange(in: field, start: 3, end: 3), with: "!")
            _ = try s.replaceText(in: s.captureTextRange(in: field, start: 4, end: 4), with: "?")
            let saved = try s.save(), batch = try s.changes()
            #expect(try batch.capacityByteCount(baselineByteCount: document.json().count) == batch.json().count)
            #expect(try s.save() == saved)
            let reopened = try ModernSession.restore(saved, actorID: "a")
            try reopened.undo()
            #expect(try reopened.text(in: field) == "A😀!")
            try reopened.redo()
            #expect(try reopened.text(in: field) == "A😀!?" && reopened.document.fields["opaque"] == .string(opaque))
        }
    }
}
