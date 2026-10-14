@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernSnapshotDeltaTests {
    private func call(_ bridge: EditorBridge, _ command: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        var fields = args; fields["command"] = .string(command); fields["session"] = .string("snapshot")
        let response = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(fields)))
        #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func create(_ bridge: EditorBridge) throws -> JSONValue {
        let document = try ModernDocument(documentID: "snapshot", title: "Title", blocks: [Block.paragraph(id: "p", text: "ABC")])
        return try call(bridge, "createModern", ["documentID": .string("snapshot"), "actorID": .string("writer"),
            "epoch": .string("epoch"), "collaborationVersion": .number(7), "document": .object(document.fields)])
    }
    @Test func optInResponsesRetainLegacyShapeAndReconstructUnicodeAfterExternalWritingAndHandleReplacement() throws {
        let bridge = EditorBridge(), initial = try create(bridge)
        #expect(initial["documentSnapshot"] == nil)
        #expect(try call(bridge, "modernCapabilities")["documentSnapshotVersion"] == .number(1))
        let first = try call(bridge, "modernSnapshot", ["documentSnapshotVersion": .number(1)])
        #expect(first["document"] == initial["document"] && first["documentSnapshot"]?["changes"] == nil)
        let token = try #require(first["documentSnapshot"]?["token"])
        let field: JSONValue = .object(["node": .object(["baseline": .object(["blockID": .string("p"), "path": .array([])])]), "name": .string("content")])
        let range = try call(bridge, "modernCaptureTextRange", ["field": field, "start": .number(0), "end": .number(3)])
        let request: JSONValue = .object(["documentID": .string("snapshot"), "epoch": .string("epoch"), "command": .string("replaceText"),
            "target": range, "arguments": .object(["text": .string("東京😀é")])])
        // A default caller may edit between negotiated reads of the same session.
        let legacy = try call(bridge, "modernCommand", ["request": request])
        #expect(legacy["documentSnapshot"] == nil)
        let next = try call(bridge, "modernEndTypingGroup", ["documentSnapshotVersion": .number(1), "knownDocumentToken": token])
        let expected = try ModernDocument(documentID: "snapshot", title: "Title", blocks: [Block.paragraph(id: "p", text: "東京😀é")])
        #expect(legacy["document"] == .object(expected.fields))
        #expect(next["document"] == nil && next["canUndo"] == .bool(true) && next["syncState"] == legacy["syncState"])
        #expect(next["documentSnapshot"]?["baseToken"] == token)
        #expect(next["documentSnapshot"]?["changes"] == .array([.object(["path": .array([.string("blocks"), .number(0), .string("content"), .number(0), .string("text")]), "value": .string("東京😀é")])]))
        let current = try #require(next["documentSnapshot"]?["token"])
        let unchanged = try call(bridge, "modernSnapshot", ["documentSnapshotVersion": .number(1), "knownDocumentToken": current])
        #expect(unchanged["documentSnapshot"]?["changes"] == .array([]) && unchanged["documentSnapshot"]?["token"] == current)
        let fallback = try call(bridge, "modernSnapshot", ["documentSnapshotVersion": .number(1), "knownDocumentToken": .string("foreign")])
        #expect(fallback["document"] == .object(expected.fields) && fallback["documentSnapshot"]?["changes"] == nil)
        _ = try call(bridge, "destroy"); _ = try create(bridge)
        let recreated = try call(bridge, "modernSnapshot", ["documentSnapshotVersion": .number(1), "knownDocumentToken": current])
        #expect(recreated["document"] == initial["document"] && recreated["documentSnapshot"]?["changes"] == nil)
        #expect(recreated["documentSnapshot"]?["token"] != current)
    }
    @Test func exactOpaqueNumbersAndUnicodeDoNotUseNormalizedEqualityAndLargeChangesFallBack() throws {
        let before: JSONValue = .object(["opaque": .object(["zero": .number(-0.0), "text": .string("é"), "__proto__": .object(["retain": .bool(true)])])])
        let after: JSONValue = .object(["opaque": .object(["zero": .number(0), "text": .string("é"), "__proto__": .object(["retain": .bool(false)])])])
        let expected: [JSONValue] = [.object(["path": .array([.string("opaque"), .string("__proto__"), .string("retain")]), "value": .bool(false)]),
            .object(["path": .array([.string("opaque"), .string("text")]), "value": .string("é")]),
            .object(["path": .array([.string("opaque"), .string("zero")]), "value": .number(0)])]
        #expect(ModernSnapshotDelta.changes(from: before, to: after) == expected)
        #expect(!ModernSnapshotDelta.equal(before, after))
        #expect(ModernSnapshotDelta.changes(from: before, to: after, limit: 2) == nil)
        #expect(ModernSnapshotDelta.changes(from: before, to: before) == [])
    }
    @Test func malformedNegotiationRejectsBeforeAuthoringOrLocalSelectionChanges() throws {
        let bridge = EditorBridge(); _ = try create(bridge)
        let saved = try call(bridge, "modernSave"), history = try call(bridge, "modernExportHistorySelection")
        for extra: [String: JSONValue] in [["documentSnapshotVersion": .number(2)], ["knownDocumentToken": .string("unnegotiated")],
            ["documentSnapshotVersion": .number(1), "knownDocumentToken": .array([])],
            ["documentSnapshotVersion": .number(1), "knownDocumentToken": .string("")]] {
            var request = extra; request["command"] = .string("modernSetLocalSelection"); request["session"] = .string("snapshot"); request["selection"] = .null
            let response = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(request)))
            #expect(response["ok"] == .bool(false))
        }
        #expect(try call(bridge, "modernSave") == saved && call(bridge, "modernExportHistorySelection") == history)
    }
}
