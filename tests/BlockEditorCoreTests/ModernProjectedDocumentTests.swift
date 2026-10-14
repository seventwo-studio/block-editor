import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernProjectedDocumentTests {
    @Test func nestedLiteralFieldsAndPeerTitleAppearanceRemainIndependentThroughAuthorUndo() throws {
        let math = try Block(fields: ["id": .string("math"), "type": .string("math"), "expression": .string("\\alpha"),
                                      "opaque": .object(["zero": .number(-0.0), "spelling": .string("é")])])
        let toggle = try Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([.object(["type": .string("text"), "text": .string("Summary")])]), "children": .array([.object(math.fields)])])
        let original = try ModernDocument(documentID: "projected-peer", title: "Base", blocks: [toggle])
        let a = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "e", document: original)
        let b = try ModernSession(documentID: original.documentID, actorID: "b", epoch: "e", document: original)
        let field = try a.field(node: a.node(at: NodeAddress("toggle", path: ["children", "math"])), name: "expression")
        try a.replaceText(in: field, range: 6..<6, with: "😀é")
        try b.replaceText(in: b.titleField, range: 0..<4, with: "Peer")
        try b.setAppearance(field: "fontFamily", value: "serif")
        try a.receive(b.changes())
        var expected = b.document.fields, roots = original.fields["blocks"]!.array!, parent = roots[0].object!, children = parent["children"]!.array!, child = children[0].object!
        child["expression"] = .string("\\alpha😀é"); children[0] = .object(child)
        parent["children"] = .array(children); roots[0] = .object(parent); expected["blocks"] = .array(roots)
        let checked = try ModernDocument(fields: expected)
        #expect(try a.document.json() == checked.json())
        try a.undo(); #expect(try a.document.json() == b.document.json())
        try a.redo(); #expect(try a.document.json() == checked.json())
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        #expect(try reopened.document.json() == checked.json())
        try reopened.undo(); #expect(try reopened.document.json() == b.document.json())
    }
    @Test func representativeFieldBoundariesAcrossEveryFixtureKeepFullAdmissionAndExactUndoReopen() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
        var documents = 0, names = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let raw = try Data(contentsOf: url), fields = try JSONDecoder().decode(JSONValue.self, from: raw)
            guard fields["format"] == .string(ModernDocument.format) else { continue }
            let original = try ModernDocument(json: raw), originalBytes = try original.json()
            let session = try ModernSession(documentID: original.documentID, actorID: "projection-test", epoch: "e", document: original)
            let logical = try session.logicalFields()
            let groups = Dictionary(grouping: logical, by: \.name)
            let sampled = Set(groups.values.flatMap { [$0.first!, $0.last!] })
            for field in logical where sampled.contains(field) {
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
        #expect(names.isSuperset(of: ["title", "content", "summary", "caption", "code"]))
    }

    @Test func exactCapacityRejectsAnEditAtomicallyThenAllowsDeletionAndUndo() throws {
        var fields = try ModernDocument(documentID: "projection-capacity", blocks: [.paragraph(id: "p", text: "xy")]).fields
        fields["opaque"] = .string("")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let overhead = try encoder.encode(fields).count
        fields["opaque"] = .string(String(repeating: "x", count: 32_000_000 - overhead))
        let original = try ModernDocument(fields: fields)
        #expect(try original.json().count == 32_000_000)
        let session = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "e", document: original)
        let field = try session.field(node: session.node(at: NodeAddress("p")))
        let receipt = session.syncState
        #expect(throws: (any Error).self) { try session.replaceText(in: field, range: 2..<2, with: "!") }
        #expect(session.document.fields == original.fields && session.syncState == receipt && !session.canUndo)
        try session.replaceText(in: field, range: 1..<2, with: "")
        #expect(try session.document.json().count == 31_999_999)
        #expect(session.document.fields["opaque"] == original.fields["opaque"])
        try session.undo(); #expect(try session.document.json() == original.json())
    }
}
