import Foundation
import Testing
import BlockEditorCore

@Suite struct ModernHistorySelectionBridgeTests {
    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func call(_ bridge: EditorBridge, _ name: String, _ handle: String = "a", _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        var input = fields; input["command"] = .string(name); input["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(input)))
    }
    private func success(_ bridge: EditorBridge, _ name: String, _ handle: String = "a", _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        let result = try call(bridge, name, handle, fields); #expect(result["ok"] == .bool(true)); return try #require(result["value"])
    }
    private func create(_ bridge: EditorBridge, _ handle: String = "a", _ document: ModernDocument? = nil) throws {
        let d = try document ?? ModernDocument(documentID: "history", title: "Title", blocks: [Block.paragraph(id: "p", text: "ABC"), Block.paragraph(id: "q", text: "Other")])
        _ = try success(bridge, "createModern", handle, ["actorID": .string(handle), "documentID": .string("history"), "epoch": .string("history"), "collaborationVersion": .number(7), "document": .object(d.fields)])
    }
    private func range(_ bridge: EditorBridge, _ label: String = "p", start: Int = 2, end: Int = 1, handle: String = "a") throws -> ModernTextRange {
        let field = try encoded(WritingField(node: .baseline(blockID: label, path: []), name: "content"))
        return try JSONDecoder().decode(ModernTextRange.self, from: JSONEncoder().encode(success(bridge, "modernCaptureTextRange", handle, ["field": field, "start": .number(Double(start)), "end": .number(Double(end))])))
    }
    private func context(_ range: ModernTextRange) -> ModernLocalSelection {
        ModernLocalSelection(documentID: "history", epoch: "history", observed: range.observed, focus: .text(range.end), selection: .text(WritingTextRange(start: range.start, end: range.end)))
    }
    private func command(_ bridge: EditorBridge, _ name: String, _ target: JSONValue = .null, _ arguments: [String: JSONValue] = [:], handle: String = "a", before: JSONValue? = nil) throws -> JSONValue {
        var request: [String: JSONValue] = ["documentID": .string("history"), "epoch": .string("history"), "command": .string(name), "target": target, "arguments": .object(arguments)]
        if let before { request["historySelection"] = before }
        return try success(bridge, "modernCommand", handle, ["request": .object(request)])
    }
    private func offset(_ bridge: EditorBridge, _ position: JSONValue, handle: String = "a") throws -> Int {
        let resolved = try success(bridge, "modernResolvePosition", handle, ["position": position])
        guard case .number(let value) = resolved["offset"] else { throw EditorError.invalidChange }; return Int(value)
    }
    @Test func localSelectionAndPairedArchiveReturnCanonicalBackwardUndoAndCaretRedoIncludingReopen() throws {
        let bridge = EditorBridge(); try create(bridge); let captured = try range(bridge), before = try encoded(context(captured))
        _ = try success(bridge, "modernSetLocalSelection", "a", ["selection": before])
        #expect(try success(bridge, "modernCapabilities")["localHistorySelectionVersion"] == .number(1))
        _ = try command(bridge, "replaceText", encoded(captured), ["text": .string("X")])
        let saved = try success(bridge, "modernSave"), archive = try success(bridge, "modernExportHistorySelection")
        _ = try success(bridge, "destroy")
        _ = try success(bridge, "restoreModern", "a", ["actorID": .string("a"), "snapshot": saved])
        _ = try success(bridge, "modernRestoreHistorySelection", "a", ["archive": archive])
        #expect(try success(bridge, "modernSave") == saved && success(bridge, "modernExportHistorySelection") == archive)
        let undone = try command(bridge, "undo")
        #expect(try undone["status"] == .string("applied") && undone["focusIntent"] == encoded(ModernFocusIntent.text(captured.end)))
        #expect(try undone["selectionIntent"] == encoded(ModernSelectionIntent.text(WritingTextRange(start: captured.start, end: captured.end))))
        #expect(try offset(bridge, undone["selection"]!["start"]!) == 2 && offset(bridge, undone["selection"]!["end"]!) == 1)
        let stable = try success(bridge, "modernSave"), metadata = try success(bridge, "modernExportHistorySelection"), noop = try command(bridge, "undo")
        #expect(noop["status"] == .string("noop") && noop["focusIntent"] == .null && noop["selectionIntent"] == .null)
        #expect(try success(bridge, "modernSave") == stable && success(bridge, "modernExportHistorySelection") == metadata)
        let redone = try command(bridge, "redo"); #expect(try offset(bridge, redone["focus"]!) == 2 && offset(bridge, redone["selection"]!["start"]!) == 2)
    }
    @Test func checkedInvocationOverrideUsesOriginalInputAndExplicitNoneDoesNotFabricateFocus() throws {
        let bridge = EditorBridge(); try create(bridge); let original = try range(bridge), other = try range(bridge, "q", start: 3, end: 3)
        _ = try success(bridge, "modernSetLocalSelection", "a", ["selection": encoded(context(other))])
        let clipboard = try encoded(ModernClipboard.plain("X")), target = try encoded(ModernPasteTarget(range: original))
        _ = try command(bridge, "paste", target, ["clipboard": clipboard], before: encoded(context(original)))
        let undone = try command(bridge, "undo"); #expect(try undone["focus"] == encoded(original.end) && undone["selection"]?["start"] == encoded(original.start))
        _ = try command(bridge, "setAppearance", encoded(NodeID.document(documentID: "history")), ["field": .string("fontSize"), "value": .string("large")], before: .null)
        let absent = try command(bridge, "undo"); #expect(absent["status"] == .string("applied") && absent["focusIntent"] == .null && absent["selectionIntent"] == .null)
        let saved = try success(bridge, "modernSave"), local = try success(bridge, "modernExportHistorySelection")
        var wrong = try #require(encoded(context(original)).object); wrong["epoch"] = .string("foreign")
        let request: JSONValue = .object(["documentID": .string("history"), "epoch": .string("history"), "command": .string("replaceText"), "target": try encoded(original), "arguments": .object(["text": .string("bad")]), "historySelection": .object(wrong)])
        #expect(try call(bridge, "modernCommand", "a", ["request": request])["ok"] == .bool(false))
        #expect(try success(bridge, "modernSave") == saved && success(bridge, "modernExportHistorySelection") == local)
    }
    @Test func mixedHistoryReturnsExactOriginsAndLocalTypedNodesCannotAuthorizeUnsupportedBlockMutation() throws {
        let bridge = EditorBridge(); try create(bridge); let captured = try range(bridge)
        let q = try encoded(NodeID.baseline(blockID: "q", path: [])), selectedJSON = try success(bridge, "modernCaptureLocalNodes", "a", ["nodes": .array([q])])
        let selected = try JSONDecoder().decode(ModernNodeSelection.self, from: JSONEncoder().encode(selectedJSON)), target = ModernDeleteTarget(nodes: selected, ranges: [captured])
        let before = ModernLocalSelection(documentID: "history", epoch: "history", observed: captured.observed, focus: .text(captured.end), selection: .mixed(target))
        _ = try success(bridge, "modernSetLocalSelection", "a", ["selection": encoded(before)])
        _ = try command(bridge, "delete", encoded(target)); let undone = try command(bridge, "undo")
        #expect(undone["selectionIntent"]?["mixed"] != nil && undone["selection"]?["nodes"]?["nodes"] == .array([q]))
        #expect(try offset(bridge, undone["selection"]!["ranges"]!.array![0]["start"]!) == 2 && offset(bridge, undone["focus"]!) == 1)
        let fields = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"table","type":"table","rows":[{"id":"row","cells":[{"id":"cell","content":[{"type":"text","text":"A"}]}]}]}"#.utf8))
        let d = try ModernDocument(documentID: "history", blocks: [Block(fields: fields.object!)]); try create(bridge, "table", d)
        let row = try encoded(NodeID.baseline(blockID: "table", path: ["rows", "row"])), localNodes = try success(bridge, "modernCaptureLocalNodes", "table", ["nodes": .array([row])]), saved = try success(bridge, "modernSave", "table")
        let req: JSONValue = .object(["documentID": .string("history"), "epoch": .string("history"), "command": .string("delete"), "target": .object(["nodes": localNodes, "ranges": .array([])]), "arguments": .object([:])])
        #expect(try call(bridge, "modernCommand", "table", ["request": req])["ok"] == .bool(false))
        #expect(try success(bridge, "modernSave", "table") == saved)
    }
    @Test func malformedImportOrSelectionAndOtherActorCannotReplaceAcceptedHistoryOrExistingRegistry() throws {
        let bridge = EditorBridge(); try create(bridge); let captured = try range(bridge)
        _ = try command(bridge, "replaceText", encoded(captured), ["text": .string("X")])
        let saved = try success(bridge, "modernSave"), archive = try success(bridge, "modernExportHistorySelection")
        _ = try success(bridge, "restoreModern", "fresh", ["actorID": .string("a"), "snapshot": saved])
        let empty = try success(bridge, "modernExportHistorySelection", "fresh"); var malformed = archive.object!; malformed["extra"] = .bool(true)
        #expect(try call(bridge, "modernRestoreHistorySelection", "fresh", ["archive": .object(malformed)])["ok"] == .bool(false))
        #expect(try success(bridge, "modernSave", "fresh") == saved && success(bridge, "modernExportHistorySelection", "fresh") == empty)
        _ = try success(bridge, "modernRestoreHistorySelection", "fresh", ["archive": archive])
        #expect(try call(bridge, "modernRestoreHistorySelection", "fresh", ["archive": archive])["ok"] == .bool(false))
        _ = try success(bridge, "restoreModern", "other", ["actorID": .string("b"), "snapshot": saved])
        #expect(try call(bridge, "modernRestoreHistorySelection", "other", ["archive": archive])["ok"] == .bool(false))
        var context = try #require(encoded(context(captured)).object); context["pixel"] = .number(10)
        #expect(try call(bridge, "modernSetLocalSelection", "fresh", ["selection": .object(context)])["ok"] == .bool(false))
        #expect(try success(bridge, "modernExportHistorySelection", "fresh") == archive)
    }
}
