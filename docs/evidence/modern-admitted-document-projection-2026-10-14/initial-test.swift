import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernProjectedDocumentTests {
    @Test func everyIndependentFixtureFieldKeepsFullAdmissionAndExactUndoReopen() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
        var documents = 0, names = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let raw = try Data(contentsOf: url), fields = try JSONDecoder().decode(JSONValue.self, from: raw)
            guard fields["format"] == .string(ModernDocument.format) else { continue }
            let original = try ModernDocument(json: raw), originalBytes = try original.json()
            let session = try ModernSession(documentID: original.documentID, actorID: "projection-test", epoch: "e", document: original)
            for field in try session.logicalFields() {
                names.insert(field.name)
                let old = try session.text(in: field), length = old.utf16.count
                try session.replaceText(in: field, range: length..<length, with: "!")
                #expect(try session.text(in: field) == old + "!")
                // Invoke the complete public admission path independently of the
                // session's projected-document construction.
                let fullyChecked = try ModernDocument(fields: session.document.fields)
                #expect(try fullyChecked.json() == session.document.json())
                let reopened = try ModernSession.restore(session.save(), actorID: "projection-test")
                #expect(try reopened.document.json() == fullyChecked.json())
                try session.undo(); #expect(try session.document.json() == originalBytes)
                try session.redo(); #expect(try session.document.json() == fullyChecked.json())
                try session.undo(); #expect(try session.document.json() == originalBytes)
            }
            documents += 1
        }
        #expect(documents == 55)
        #expect(names.isSuperset(of: ["title", "content", "summary", "caption", "code", "expression"]))
    }

    @Test func exactCapacityRejectsAnEditAtomicallyThenAllowsDeletionAndUndo() throws {
        var fields = try ModernDocument(documentID: "projection-capacity", blocks: [.paragraph(id: "p", text: "x")]).fields
        fields["opaque"] = .string("")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let overhead = try encoder.encode(fields).count
        fields["opaque"] = .string(String(repeating: "x", count: 32_000_000 - overhead))
        let original = try ModernDocument(fields: fields)
        #expect(try original.json().count == 32_000_000)
        let session = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "e", document: original)
        let field = try session.field(node: session.node(at: NodeAddress("p")))
        let receipt = session.syncState
        #expect(throws: (any Error).self) { try session.replaceText(in: field, range: 1..<1, with: "!") }
        #expect(session.document.fields == original.fields && session.syncState == receipt && !session.canUndo)
        try session.replaceText(in: field, range: 0..<1, with: "")
        #expect(try session.document.json().count == 31_999_999)
        #expect(session.document.fields["opaque"] == original.fields["opaque"])
        try session.undo(); #expect(try session.document.json() == original.json())
    }
}
