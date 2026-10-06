import Foundation
import Testing
import BlockEditorCore

@Suite struct ModernPasteBridgeTests {
    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func call(_ bridge: EditorBridge, _ command: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        var input = fields; input["command"] = .string(command); input["session"] = .string("a")
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(input)))
    }
    private func success(_ bridge: EditorBridge, _ command: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        let response = try call(bridge, command, fields); #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func create(_ bridge: EditorBridge) throws {
        let d = try ModernDocument(documentID: "paste", blocks: [Block.paragraph(id: "p", text: "ABC")])
        _ = try success(bridge, "createModern", ["actorID": .string("a"), "documentID": .string("paste"), "epoch": .string("paste"), "collaborationVersion": .number(7), "document": .object(d.fields)])
    }
    private func target(_ bridge: EditorBridge) throws -> JSONValue {
        let field = WritingField(node: .baseline(blockID: "p", path: []), name: "content")
        let range = try success(bridge, "modernCaptureTextRange", ["field": encoded(field), "start": .number(1), "end": .number(2)])
        return .object(["range": range])
    }
    private func request(_ target: JSONValue, _ clipboard: JSONValue, extra: [String: JSONValue] = [:], epoch: String = "paste") -> JSONValue {
        var args = extra; args["clipboard"] = clipboard
        return .object(["documentID": .string("paste"), "epoch": .string(epoch), "command": .string("paste"), "target": target, "arguments": .object(args)])
    }
    @Test func checkedRichReplacementReturnsOneTransactionAndCaretWithoutChangingClipboard() throws {
        let bridge = EditorBridge(); try create(bridge)
        let target = try target(bridge), clipboard = try encoded(ModernClipboard.plain("世界😀"))
        let caps = try success(bridge, "modernCapabilities"); #expect(caps["commands"]?.array?.contains(.string("paste")) == true)
        let result = try success(bridge, "modernCommand", ["request": request(target, clipboard)])
        #expect(result["status"] == .string("applied") && result["transaction"]?["actor"] == .string("a") && result["retainedClipboard"] == .null)
        #expect(result["document"]?["blocks"]?.array?[0]["content"] == .array([textNode("A世界😀C")]))
        let position = try #require(result["focus"]), resolved = try success(bridge, "modernResolvePosition", ["position": position])
        #expect(resolved["offset"] == .number(5))
        let history = try success(bridge, "modernChanges"); #expect(history["changes"]?.array?.count == 1)
        _ = try success(bridge, "modernCommand", ["request": .object(["documentID": .string("paste"), "epoch": .string("paste"), "command": .string("undo"), "target": .null, "arguments": .object([:])])])
        #expect(try success(bridge, "modernDocument")["blocks"]?.array?[0]["content"] == .array([textNode("ABC")]))
    }
    @Test func unavailablePolicyCompositionScopeAndAdmissionRetainExactRichPayloadForExplicitRetry() throws {
        let bridge = EditorBridge(); try create(bridge)
        let target = try target(bridge), clipboard = try encoded(ModernClipboard.multiline("New\n")), before = try success(bridge, "modernSave")
        _ = try success(bridge, "modernSetAuthoringPolicy", ["allowedCommands": .array([])])
        let policy = try success(bridge, "modernCommand", ["request": request(target, clipboard)])
        #expect(policy["reason"] == .string("hostPolicy") && policy["retainedClipboard"] == clipboard && policy["focus"] == .null)
        _ = try success(bridge, "modernSetAuthoringPolicy", ["allowedCommands": .null])
        _ = try success(bridge, "modernComposition", ["active": .bool(true)])
        let composing = try success(bridge, "modernCommand", ["request": request(target, clipboard)])
        #expect(composing["reason"] == .string("compositionActive") && composing["retainedClipboard"] == clipboard)
        _ = try success(bridge, "modernComposition", ["active": .bool(false)])
        let foreign = try success(bridge, "modernCommand", ["request": request(target, clipboard, epoch: "foreign")])
        #expect(foreign["status"] == .string("unavailable") && foreign["retainedClipboard"] == clipboard)
        let rejected = try success(bridge, "modernCommand", ["request": request(target, clipboard, extra: ["newIDs": .array([.string("p")])])])
        #expect(rejected["status"] == .string("unavailable") && rejected["retainedClipboard"] == clipboard)
        #expect(try success(bridge, "modernSave") == before)
        let retry = try success(bridge, "modernCommand", ["request": request(target, clipboard, extra: ["mode": .string("plainText"), "newIDs": .array([.string("tail")])])])
        #expect(retry["status"] == .string("applied") && retry["retainedClipboard"] == .null)
    }
    @Test func noProviderResultIsNoopAndMalformedVersionOrExtraFieldsRejectUnchanged() throws {
        let bridge = EditorBridge(); try create(bridge)
        let target = try target(bridge), clipboard = try encoded(ModernClipboard.plain("New")), before = try success(bridge, "modernSave")
        let result = try success(bridge, "modernCommand", ["request": request(target, .null)])
        #expect(result["status"] == .string("noop") && result["transaction"] == .null && result["focus"] == .null)
        var malformed = clipboard.object!; malformed["version"] = .number(1)
        #expect(try call(bridge, "modernCommand", ["request": request(target, .object(malformed))])["ok"] == .bool(false))
        var extra = target.object!; extra["numericOffset"] = .number(0)
        #expect(try call(bridge, "modernCommand", ["request": request(.object(extra), clipboard)])["ok"] == .bool(false))
        #expect(try success(bridge, "modernSave") == before)
    }
    @Test func genericCollectionCaptureExposesExplicitBoundaryAndPlainPasteCaretAtLastLineEnd() throws {
        let bridge = EditorBridge(); try create(bridge)
        let boundary = try success(bridge, "modernCapturePasteBoundary", ["collection": encoded(NodeCollection.root)])
        let target: JSONValue = .object(["boundary": boundary]), clipboard = try encoded(ModernClipboard.plain("One\nTwo"))
        let pasted = try success(bridge, "modernCommand", ["request": request(target, clipboard, extra: ["mode": .string("plainText"), "newIDs": .array([.string("one"), .string("two")])])])
        #expect(pasted["document"]?["blocks"]?.array?.map { $0["id"]!.string! } == ["one", "two", "p"])
        let position = try #require(pasted["focus"]), resolved = try success(bridge, "modernResolvePosition", ["position": position])
        #expect(resolved["offset"] == .number(3))
        #expect(position["field"]?["name"] == .string("content"))
    }
}
