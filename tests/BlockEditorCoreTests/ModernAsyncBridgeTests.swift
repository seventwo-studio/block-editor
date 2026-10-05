import Foundation
import Testing
import BlockEditorCore

@Suite struct ModernAsyncBridgeTests {
    private func fixture(_ name: String = "mixed") throws -> ModernDocument {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ModernDocument(json: Data(contentsOf: root.appendingPathComponent("docs/acceptance/modern-editor/documents/\(name).json")))
    }
    private func call(_ bridge: EditorBridge, _ command: String, _ handle: String = "a", _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        var fields = arguments; fields["command"] = .string(command); fields["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(JSONValue.object(fields))))
    }
    private func success(_ bridge: EditorBridge, _ command: String, _ handle: String = "a", _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        let response = try call(bridge, command, handle, arguments); #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func create(_ bridge: EditorBridge, _ handle: String = "a", _ document: ModernDocument? = nil) throws -> JSONValue {
        let d = try document ?? fixture()
        return try success(bridge, "createModern", handle, ["actorID": .string(handle), "documentID": .string(d.documentID), "epoch": .string("async"), "collaborationVersion": .number(7), "document": .object(d.fields)])
    }
    private func begin(_ bridge: EditorBridge) throws -> JSONValue {
        try success(bridge, "modernBeginAsyncBlock", "a", ["node": .object(["baseline": .object(["blockID": .string("media"), "path": .array([])])]), "requestID": .string("fixture-provider")])
    }
    private let metadata: JSONValue = .object(["src": .string("asset://fixture/completed"), "alt": .string("Completed")])
    private func complete(_ bridge: EditorBridge, _ target: JSONValue, _ handle: String = "a") throws -> JSONValue {
        try success(bridge, "modernCommand", handle, ["request": .object(["documentID": target["documentID"]!, "epoch": target["epoch"]!, "command": .string("completeAsyncBlock"), "target": target, "arguments": .object(["metadata": metadata])])])
    }

    @Test func checkedCompletionReturnsNoFocusAndRequestStateIsSeparateFromAcceptedSave() throws {
        let bridge = EditorBridge(); _ = try create(bridge)
        let saved = try success(bridge, "modernSave"), target = try begin(bridge)
        #expect(try success(bridge, "modernSave") == saved)
        let completed = try complete(bridge, target)
        #expect(completed["status"] == .string("applied") && completed["transaction"]?["actor"] == .string("a"))
        #expect(completed["focus"] == .null && completed["selection"] == .null && completed["focusIntent"] == .null && completed["selectionIntent"] == .null && completed["retainedResult"] == .null)
        let shared = try success(bridge, "modernChanges"), text = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        #expect(!text.contains("requestID") && !text.contains("generation") && !text.contains("fixture-provider"))
        let records = try success(bridge, "modernAsyncRequests")
        #expect(records.array?[0]["status"] == .string("applied") && records.array?[0]["receipt"]?.array?.count == 1)
        let before = try success(bridge, "modernSave"); #expect(try complete(bridge, target)["status"] == .string("noop"))
        #expect(try success(bridge, "modernSave") == before)
        #expect(try success(bridge, "modernCapabilities")["asyncKinds"] == .array([.string("image"), .string("file"), .string("embed")]))
    }
    @Test func acceptedACC15SwitchRetainsResultWithoutReplacementMutationOrOriginAcknowledgment() throws {
        let bridge = EditorBridge(); _ = try create(bridge)
        let target = try begin(bridge), old = try success(bridge, "modernSave"), replacement = try fixture("unicode")
        _ = try create(bridge, "replacement", replacement)
        let before = try success(bridge, "modernSave", "replacement"), outcome = try complete(bridge, target, "replacement")
        #expect(outcome["status"] == .string("unavailable") && outcome["retainedResult"] == metadata && outcome["document"] == .object(replacement.fields))
        #expect(outcome["focus"] == .null && outcome["transaction"] == .null)
        #expect(try success(bridge, "modernSave", "replacement") == before && success(bridge, "modernSave") == old)
        #expect(try success(bridge, "modernAsyncRequests").array?[0]["status"] == .string("pending"))
    }
    @Test func policyCompositionCancelFailureAndReopenPreserveProviderRecordsWithoutAutomaticCompletion() throws {
        let bridge = EditorBridge(); _ = try create(bridge)
        let target = try begin(bridge), before = try success(bridge, "modernSave")
        _ = try success(bridge, "modernSetAuthoringPolicy", "a", ["allowedCommands": .array([.string("replaceTitle")])])
        #expect(try complete(bridge, target)["reason"] == .string("hostPolicy"))
        #expect(try success(bridge, "modernAsyncRequests").array?[0]["result"] == metadata)
        _ = try success(bridge, "modernSetAuthoringPolicy", "a", ["allowedCommands": .null])
        _ = try success(bridge, "modernComposition", "a", ["active": .bool(true)])
        #expect(try complete(bridge, target)["reason"] == .string("compositionActive"))
        _ = try success(bridge, "modernComposition", "a", ["active": .bool(false)])
        _ = try success(bridge, "modernFailAsyncBlock", "a", ["target": target, "reason": .string("Provider interrupted")])
        let archive = try success(bridge, "modernExportAsyncRequests")
        _ = try success(bridge, "restoreModern", "restored", ["actorID": .string("a"), "snapshot": before])
        _ = try success(bridge, "modernRestoreAsyncRequests", "restored", ["archive": archive])
        #expect(try success(bridge, "modernSave", "restored") == before)
        #expect(try success(bridge, "modernAsyncRequests", "restored") == success(bridge, "modernAsyncRequests"))
        #expect(try complete(bridge, target, "restored")["status"] == .string("unavailable"))
        _ = try success(bridge, "modernCancelAsyncBlock", "restored", ["target": target])
        #expect(try success(bridge, "modernAsyncRequests", "restored").array?[0]["status"] == .string("cancelled"))
        #expect(try success(bridge, "modernSave", "restored") == before)
        _ = try success(bridge, "modernForgetAsyncBlock", "restored", ["target": target])
        #expect(try success(bridge, "modernAsyncRequests", "restored") == .array([]))
    }
}
