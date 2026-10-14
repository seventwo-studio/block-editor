@testable import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernSnapshotDeltaTests {
    @Test func admittedRootMasksMatchCompleteSnapshotsThroughPeerUndoAndStructuralFallback() throws {
        let toggle = try Block(fields: ["id": .string("t"), "type": .string("toggle"), "summary": .array([textNode("Summary")]),
            "children": .array([.object(Block.paragraph(id: "p", text: "One😀").fields)])])
        let original = try ModernDocument(documentID: "root-deltas", title: "Title", blocks: [toggle, .paragraph(id: "q", text: "Two")])
        let a = try ModernSession(documentID: original.documentID, actorID: "a", epoch: "e", document: original)
        let b = try ModernSession(documentID: original.documentID, actorID: "b", epoch: "e", document: original)
        let p = try a.field(node: a.node(at: NodeAddress("t", path: ["children", "p"])))
        let q = try b.field(node: b.node(at: NodeAddress("q")))
        var previous = original
        func check() throws {
            let current = a.document
            #expect(ModernSnapshotDelta.changes(from: previous, to: current) ==
                ModernSnapshotDelta.changes(from: .object(previous.fields), to: .object(current.fields)))
            #expect(try ModernDocument(fields: current.fields).json() == current.json())
            previous = current
        }
        try a.replaceText(in: p, range: 5..<5, with: "!"); try check()
        try b.replaceText(in: q, range: 3..<3, with: " peer")
        try a.receive(b.changes()); try check()
        #expect(ModernSnapshotDelta.changes(from: original, to: a.document, limit: 1) == nil)
        try a.undo(); try check()
        #expect(try a.text(in: p) == "One😀" && a.text(in: q) == "Two peer")
        try a.redo(); try check()
        try a.setAppearance(field: "fontSize", value: "large"); try check()
        try a.replaceText(in: a.titleField, range: 5..<5, with: " é"); try check()
        try a.move(p.node, into: .root, after: a.node(at: NodeAddress("t"))); try check()
        try a.undo(); try check()
        let reopened = try ModernSession.restore(a.save(), actorID: "a")
        #expect(ModernSnapshotDelta.changes(from: a.document, to: reopened.document) == [])
    }
    @Test func unrelatedEqualValuedDocumentsCannotBorrowRootMasksOrHideOpaqueBitChanges() throws {
        var fields = try ModernDocument(documentID: "opaque-delta", blocks: [.paragraph(id: "p", text: "Same")]).fields
        fields["opaque"] = .object(["zero": .number(-0.0), "text": .string("é")])
        let before = try ModernDocument(fields: fields)
        fields["opaque"] = .object(["zero": .number(0), "text": .string("é")])
        let after = try ModernDocument(fields: fields)
        #expect(before == after) // Original public semantic equality is retained.
        let changes = try #require(ModernSnapshotDelta.changes(from: before, to: after))
        #expect(changes.count == 2)
        #expect(changes == ModernSnapshotDelta.changes(from: .object(before.fields), to: .object(after.fields)))
    }
    @Test func rawKeyReplacementAndNumericPathOrderingRemainExact() throws {
        let before: JSONValue = .object(["parent": .object(["é": .string("old"), "a": .number(1)])])
        let after: JSONValue = .object(["parent": .object(["é": .string("new"), "a": .number(2)])])
        let replaced = try #require(ModernSnapshotDelta.changes(from: before, to: after))
        #expect(replaced.count == 1)
        #expect(replaced[0]["path"] == .array([.string("parent")]))
        let raw = try JSONEncoder().encode(replaced[0]["value"]!)
        #expect(String(decoding: raw, as: UTF8.self).contains("é"))
        var values = Array(repeating: JSONValue.number(0), count: 12)
        let original: JSONValue = .object(["z": .array(values), "a": .bool(false)])
        values[10] = .number(10); values[2] = .number(2)
        let edited: JSONValue = .object(["a": .bool(true), "z": .array(values)])
        let changes = try #require(ModernSnapshotDelta.changes(from: original, to: edited))
        #expect(changes.map { $0["path"]! } == [.array([.string("a")]), .array([.string("z"), .number(2)]), .array([.string("z"), .number(10)])])
        #expect(ModernSnapshotDelta.changes(from: original, to: edited, limit: 2) == nil)
    }
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
