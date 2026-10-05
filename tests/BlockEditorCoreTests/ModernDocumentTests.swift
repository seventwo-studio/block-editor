import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernDocumentTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/acceptance/modern-editor/documents")
    }
    private func fields(_ name: String) throws -> [String: JSONValue] {
        try #require(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appendingPathComponent(name + ".json"))).object)
    }
    private func encoded(_ fields: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    @Test func independentSnapshotsRetainEveryAdmittedFieldAndCanonicalRoundTrip() throws {
        var count = 0
        // Expected snapshots predate this implementation. Read them verbatim;
        // never regenerate expected documents from the implementation output.
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            let bytes = try Data(contentsOf: url)
            let original = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard original["format"] == .string("seventwo.block-editor.document") else { continue }
            let document = try ModernDocument(json: bytes)
            #expect(JSONValue.object(document.fields) == original)
            #expect(try ModernDocument(json: document.json()) == document)
            #expect(try encoded(document.fields) == document.json())
            count += 1
        }
        #expect(count == 55)
    }

    @Test func explicitNewDocumentDefaultsDoNotSilentlyUpgradeMissingWireFields() throws {
        let document = try ModernDocument(documentID: "new")
        #expect(document.title == "" && document.blocks.isEmpty && document.appearance == .default)
        var missing = document.fields
        for key in ["format", "formatVersion", "documentID", "title", "appearance", "blocks"] {
            missing = document.fields; missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try ModernDocument(fields: missing) }
        }
    }

    @Test(arguments: ["a\nb", "a\rb", "a\r\nb", "a\u{2028}b", "a\u{2029}b"])
    func titleRejectsLineBreaksWithoutConsumingBody(_ title: String) throws {
        let original = try fields("unicode")
        var changed = original; changed["title"] = .string(title)
        #expect(throws: (any Error).self) { try ModernDocument(fields: changed) }
        #expect(try fields("unicode") == original)
    }

    @Test func appearanceAndPaletteRejectUnrecognizedPresetsAndRoles() throws {
        let original = try fields("unicode")
        for key in ["fontFamily", "fontSize", "pageWidth"] {
            var changed = original, appearance = try #require(original["appearance"]?.object)
            appearance[key] = .string("unsupported"); changed["appearance"] = .object(appearance)
            #expect(throws: (any Error).self) { try ModernDocument(fields: changed) }
        }
        for key in ["semanticColor", "semanticBackground"] {
            var changed = original, blocks = try #require(original["blocks"]?.array)
            var first = try #require(blocks[0].object); first[key] = .string("custom-purple")
            blocks[0] = .object(first); changed["blocks"] = .array(blocks)
            #expect(throws: (any Error).self) { try ModernDocument(fields: changed) }
        }
        var extensions = original, appearance = try #require(original["appearance"]?.object)
        appearance["consumer"] = .object(["id": .string("opaque")]); extensions["appearance"] = .object(appearance)
        #expect(try ModernDocument(json: encoded(extensions)).fields == extensions)
    }

    @Test func exactTwoContainersAndScopedIdentitiesAreRequired() throws {
        let original = try fields("columns-rich")
        let layout = try #require(original["blocks"]?.array?.first?.object)
        let columns = try #require(layout["columns"]?.array)
        for invalidColumns in [[], Array(columns.prefix(1)), columns + [.object(["id": .string("third"), "children": .array([])])], [columns[0], columns[0]]] {
            var root = original, invalidLayout = layout
            invalidLayout["columns"] = .array(invalidColumns); root["blocks"] = .array([.object(invalidLayout)])
            #expect(throws: (any Error).self) { try ModernDocument(fields: root) }
        }
        var duplicated = original
        duplicated["blocks"] = .array([.object(layout), .object(layout)])
        #expect(throws: (any Error).self) { try ModernDocument(fields: duplicated) }
        // Separate containers may legitimately reuse a child label; origins are scoped.
        var reused = original, validLayout = layout
        let child = JSONValue.object(try Block.paragraph(id: "same", text: "preserve").fields)
        validLayout["columns"] = .array([.object(["id": .string("first"), "children": .array([child])]), .object(["id": .string("second"), "children": .array([child])])])
        reused["blocks"] = .array([.object(validLayout)])
        #expect(try ModernDocument(fields: reused).fields == reused)
    }

    @Test(arguments: [999.0, 9001, 5000.5, Double.infinity, Double.nan])
    func splitRejectsInvalidBoundsAndNonintegerValues(_ split: Double) throws {
        var root = try fields("columns-rich"), layout = try #require(root["blocks"]?.array?.first?.object)
        layout["splitBasisPoints"] = .number(split); root["blocks"] = .array([.object(layout)])
        #expect(throws: (any Error).self) { try ModernDocument(fields: root) }
    }

    @Test func nestedColumnsRejectEvenThroughToggleDescendantsButIndependentLayoutsRemainValid() throws {
        var root = try fields("columns-rich")
        let layout = try #require(root["blocks"]?.array?.first?.object)
        var outer = layout, columns = try #require(layout["columns"]?.array)
        var first = try #require(columns[0].object)
        first["children"] = .array([.object(["id": .string("toggle"), "type": .string("toggle"), "summary": .array([textNode("Details")]), "children": .array([.object(layout)])])])
        columns[0] = .object(first); outer["columns"] = .array(columns); root["blocks"] = .array([.object(outer)])
        #expect(throws: (any Error).self) { try ModernDocument(fields: root) }
        var independent = layout; independent["id"] = .string("independent")
        root["blocks"] = .array([.object(layout), .object(independent)])
        #expect(try ModernDocument(fields: root).blocks.count == 2)
    }

    @Test func duplicateRawKeysIncludingEscapedKeysRejectBeforeSemanticAdmission() throws {
        for bytes in [#"{"format":"first","format":"second"}"#, #"{"format":"first","\u0066ormat":"second"}"#, #"{"consumer":{"id":"a","id":"b"}}"#] {
            #expect(throws: (any Error).self) { try ModernDocument(json: Data(bytes.utf8)) }
        }
        #expect(throws: (any Error).self) { try ModernDocument(json: Data(#"{"consumer":"unterminated"#.utf8)) }
    }

    @Test func existingLimitsAndOpaqueMetadataArePreserved() throws {
        let large = try ModernDocument(json: Data(contentsOf: fixtures.appendingPathComponent("migrated-5001.json")))
        #expect(large.blocks.count == 5001)
        var fields = try self.fields("unicode")
        var nested: JSONValue = .string("opaque")
        for _ in 0..<101 { nested = .object(["extension": nested]) }
        fields["consumer"] = nested
        #expect(throws: (any Error).self) { try ModernDocument(fields: fields) }
        #expect(throws: (any Error).self) { try ModernDocument(json: Data(repeating: 32, count: 32_000_001)) }
        let block = try Block.paragraph(id: "p", text: "unchanged")
        #expect(throws: (any Error).self) { try ModernDocument(documentID: "large", blocks: Array(repeating: block, count: 10_001)) }
    }

    @Test func modernSnapshotDoesNotBroadenLegacyMarkOrSessionAdmission() throws {
        let modern = try ModernDocument(json: Data(contentsOf: fixtures.appendingPathComponent("unicode.json")))
        #expect(throws: (any Error).self) { try Document(json: modern.json()) }
        let marked = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("color", marks: [.object(["type": .string("semantic-color"), "value": .string("blue")])])])])
        #expect(try ModernDocument(documentID: "modern", blocks: [marked]).blocks == [marked])
        #expect(throws: (any Error).self) { try Document(blocks: [marked]) }
        let legacy = try Document(blocks: [Block.paragraph(id: "p", text: "old")])
        #expect(throws: EditorError.unsupportedVersion(7)) { try WritingSession(documentID: "old", actorID: "a", epoch: "e", document: legacy, protocolVersion: 7) }
        // Legacy unknown block fields retain their original interpretation.
        let opaque = try Block(fields: ["id": .string("legacy-columns"), "type": .string("columns"), "columns": .string("consumer-owned-original"), "semanticColor": .string("consumer-owned-original")])
        #expect(try Document(blocks: [opaque]).blocks == [opaque])
    }
}
