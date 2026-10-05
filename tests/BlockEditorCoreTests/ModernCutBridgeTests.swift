import Foundation
import Testing
import BlockEditorCore

@Suite struct ModernCutBridgeTests {
    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func call(_ bridge: EditorBridge, _ command: String, _ handle: String = "a", _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        var input = fields; input["command"] = .string(command); input["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(input)))
    }
    private func success(_ bridge: EditorBridge, _ command: String, _ handle: String = "a", _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        let response = try call(bridge, command, handle, fields); #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func create(_ bridge: EditorBridge, _ handle: String = "a", _ document: ModernDocument? = nil) throws {
        let d = try document ?? ModernDocument(documentID: "cut", title: "Title", blocks: [Block.paragraph(id: "p", text: "ABC")])
        _ = try success(bridge, "createModern", handle, ["actorID": .string(handle), "documentID": .string(d.documentID), "epoch": .string("cut"), "collaborationVersion": .number(7), "document": .object(d.fields)])
    }
    private func prepare(_ bridge: EditorBridge, _ target: JSONValue? = nil) throws -> JSONValue {
        let field = try encoded(WritingField(node: .baseline(blockID: "p", path: []), name: "content"))
        let range = try success(bridge, "modernCaptureTextRange", "a", ["field": field, "start": .number(1), "end": .number(2)])
        return try success(bridge, "modernPrepareCut", "a", ["target": target ?? .object(["ranges": .array([range])])])
    }
    private func finish(_ bridge: EditorBridge, _ preparation: JSONValue, _ published: Bool, _ handle: String = "a", epoch: String = "cut") throws -> JSONValue {
        try success(bridge, "modernFinishCut", handle, ["preparationID": preparation["preparationID"]!, "documentID": .string("cut"), "epoch": .string(epoch), "published": .bool(published)])
    }
    private func history(_ bridge: EditorBridge, _ name: String) throws -> JSONValue {
        try success(bridge, "modernCommand", "a", ["request": .object(["documentID": .string("cut"), "epoch": .string("cut"), "command": .string(name), "target": .null, "arguments": .object([:])])])
    }
    @Test func prepareIsReadOnlyAndFinishNeedsSuccessfulPublicationBeforeOneDeletionAndDuplicateAfterUndoIsNoop() throws {
        let bridge = EditorBridge(); try create(bridge)
        let before = try success(bridge, "modernSave"), preparation = try prepare(bridge)
        #expect(preparation["clipboard"]?["plainText"] == .string("B"))
        #expect(try success(bridge, "modernSave") == before)
        let refused = try finish(bridge, preparation, false)
        #expect(refused["reason"] == .string("clipboardPublicationFailed") && refused["retainedClipboard"] == preparation["clipboard"] && refused["focus"] == .null)
        #expect(try success(bridge, "modernSave") == before)
        let result = try finish(bridge, preparation, true)
        #expect(result["status"] == .string("applied") && result["document"]?["blocks"]?.array?[0]["content"] == .array([textNode("AC")]))
        #expect(result["transaction"]?["actor"] == .string("a") && result["focusIntent"] != .null && result["retainedClipboard"] == .null)
        _ = try history(bridge, "undo"); let undone = try success(bridge, "modernSave")
        #expect(try finish(bridge, preparation, true)["reason"] == .string("cutAlreadyApplied"))
        #expect(try success(bridge, "modernSave") == undone)
        _ = try history(bridge, "redo")
        #expect(try success(bridge, "modernDocument")["blocks"]?.array?[0]["content"] == .array([textNode("AC")]))
    }
    @Test func policyCompositionWrongScopeAndOtherHandleRetainPayloadAndAllowExplicitRetry() throws {
        let bridge = EditorBridge(); try create(bridge); try create(bridge, "b")
        let preparation = try prepare(bridge), before = try success(bridge, "modernSave")
        _ = try success(bridge, "modernSetAuthoringPolicy", "a", ["allowedCommands": .array([])])
        #expect(try success(bridge, "modernCapabilities")["canCut"] == .bool(false))
        let policy = try finish(bridge, preparation, true)
        #expect(policy["reason"] == .string("hostPolicy") && policy["retainedClipboard"] == preparation["clipboard"])
        _ = try success(bridge, "modernSetAuthoringPolicy", "a", ["allowedCommands": .null])
        _ = try success(bridge, "modernComposition", "a", ["active": .bool(true)])
        #expect(try finish(bridge, preparation, true)["reason"] == .string("compositionActive"))
        _ = try success(bridge, "modernComposition", "a", ["active": .bool(false)])
        #expect(try finish(bridge, preparation, true, epoch: "foreign")["reason"] == .string("cutSessionChanged"))
        #expect(try finish(bridge, preparation, true, "b")["reason"] == .string("unknownCutPreparation"))
        #expect(try success(bridge, "modernSave") == before)
        #expect(try finish(bridge, preparation, true)["status"] == .string("applied"))
    }
    @Test func cancelForgetDestroyAndRestoreCannotMakeOldPublicationApplyToNewPreparation() throws {
        let bridge = EditorBridge(); try create(bridge)
        let cancelled = try prepare(bridge), before = try success(bridge, "modernSave")
        _ = try success(bridge, "modernCancelCut", "a", ["preparationID": cancelled["preparationID"]!])
        #expect(try finish(bridge, cancelled, true)["reason"] == .string("cutCancelled"))
        _ = try success(bridge, "modernForgetCut", "a", ["preparationID": cancelled["preparationID"]!])
        #expect(try finish(bridge, cancelled, true)["reason"] == .string("unknownCutPreparation"))
        let pending = try prepare(bridge)
        _ = try success(bridge, "destroy")
        _ = try success(bridge, "restoreModern", "a", ["actorID": .string("a"), "snapshot": before])
        let fresh = try prepare(bridge)
        #expect(fresh["preparationID"] != pending["preparationID"])
        #expect(try finish(bridge, pending, true)["reason"] == .string("unknownCutPreparation"))
        #expect(try success(bridge, "modernSave") == before)
        #expect(try finish(bridge, fresh, true)["status"] == .string("applied"))
    }
    @Test func boundedPreparationCountAndMalformedAcknowledgmentNeverDeleteBeforePublication() throws {
        let bridge = EditorBridge(); try create(bridge)
        let first = try prepare(bridge), before = try success(bridge, "modernSave")
        for _ in 1..<64 { _ = try prepare(bridge) }
        let target = first["target"]!
        #expect(try call(bridge, "modernPrepareCut", "a", ["target": target])["ok"] == .bool(false))
        #expect(try call(bridge, "modernFinishCut", "a", ["preparationID": first["preparationID"]!, "documentID": .string("cut"), "epoch": .string("cut"), "published": .string("true")])["ok"] == .bool(false))
        #expect(try call(bridge, "modernFinishCut", "a", ["preparationID": first["preparationID"]!, "documentID": .string("cut"), "epoch": .string("cut"), "published": .bool(true), "target": target])["ok"] == .bool(false))
        #expect(try success(bridge, "modernSave") == before)
        _ = try success(bridge, "modernForgetCut", "a", ["preparationID": first["preparationID"]!])
        _ = try prepare(bridge)
        #expect(try finish(bridge, first, true)["reason"] == .string("unknownCutPreparation"))
        #expect(try success(bridge, "modernSave") == before)
    }

    @Test func preparationByteBudgetRetainsWholeOpaquePayloadWithoutNarrowingDocumentAdmission() throws {
        let bridge = EditorBridge()
        let opaque = try Block(fields: ["id": .string("p"), "type": .string("consumer-card"), "consumer": .object(["id": .string("keep"), "payload": .string(String(repeating: "x", count: 8_000_000))])])
        let d = try ModernDocument(documentID: "cut", title: "Title", blocks: [opaque]); try create(bridge, "a", d)
        let node = try encoded(NodeID.baseline(blockID: "p", path: []))
        let selection = try success(bridge, "modernCaptureNodes", "a", ["nodes": .array([node])]), target: JSONValue = .object(["nodes": selection, "ranges": .array([])])
        var identifiers: [JSONValue] = []
        for _ in 0..<7 {
            let prepared = try success(bridge, "modernPrepareCut", "a", ["target": target]); identifiers.append(prepared["preparationID"]!)
            #expect(prepared["clipboard"]?["parts"]?.array?[0]["node"]?["value"]?["consumer"] == opaque.fields["consumer"])
        }
        #expect(try call(bridge, "modernPrepareCut", "a", ["target": target])["ok"] == .bool(false))
        #expect(try success(bridge, "modernChanges")["changes"] == .array([]))
        #expect(try success(bridge, "modernDocument") == .object(d.fields))
        _ = try success(bridge, "modernForgetCut", "a", ["preparationID": identifiers[0]])
        let replacement = try success(bridge, "modernPrepareCut", "a", ["target": target])
        #expect(!identifiers.contains(replacement["preparationID"]!))
        #expect(try success(bridge, "modernChanges")["changes"] == .array([]))
    }
}
