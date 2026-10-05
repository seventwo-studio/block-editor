import Foundation
import Testing
import BlockEditorCore

@Suite struct ModernClipboardBridgeTests {
    private func call(_ bridge: EditorBridge, _ command: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        var fields = args; fields["command"] = .string(command); fields["session"] = .string("a")
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(JSONValue.object(fields))))
    }
    private func success(_ bridge: EditorBridge, _ command: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let response = try call(bridge, command, args); #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func create(_ bridge: EditorBridge) throws {
        let d = try ModernDocument(documentID: "clipboard", title: "Title", blocks: [Block.paragraph(id: "p", text: "世界😀")])
        _ = try success(bridge, "createModern", ["actorID": .string("a"), "documentID": .string("clipboard"), "epoch": .string("copy"), "collaborationVersion": .number(7), "document": .object(d.fields)])
    }
    private var node: JSONValue { .object(["baseline": .object(["blockID": .string("p"), "path": .array([])])]) }
    @Test func checkedCopyReturnsVersionedPayloadAndFallbackWithoutDocumentHistoryOrFocusMutation() throws {
        let bridge = EditorBridge(); try create(bridge)
        let before = try success(bridge, "modernSave"), selected = try success(bridge, "modernCaptureNodes", ["nodes": .array([node])])
        _ = try success(bridge, "modernSetAuthoringPolicy", ["allowedCommands": .array([])])
        _ = try success(bridge, "modernComposition", ["active": .bool(true)])
        let target: JSONValue = .object(["nodes": selected, "ranges": .array([])])
        let value = try success(bridge, "modernCopy", ["target": target])
        #expect(value["version"] == .number(2) && value["collaborationVersion"] == .number(7) && value["plainText"] == .string("世界😀"))
        #expect(try ModernClipboard(json: JSONEncoder().encode(value)).plainText == "世界😀")
        #expect(try success(bridge, "modernSave") == before)
        let caps = try success(bridge, "modernCapabilities")
        #expect(caps["canCopy"] == .bool(true) && caps["clipboardVersion"] == .number(2))
        #expect(caps["commands"]?.array?.contains(.string("paste")) == false)
    }
    @Test func foreignForgedAndExtraTargetFieldsRejectCopyUnchanged() throws {
        let bridge = EditorBridge(); try create(bridge)
        let before = try success(bridge, "modernSave"), selected = try success(bridge, "modernCaptureNodes", ["nodes": .array([node])])
        var forged = selected.object!; forged["epoch"] = .string("foreign")
        let targets: [JSONValue] = [.object(["nodes": .object(forged), "ranges": .array([])]),
            .object(["nodes": selected, "ranges": .array([]), "unknown": .bool(true)]), .object(["ranges": .array([])])]
        for target in targets {
            #expect(try call(bridge, "modernCopy", ["target": target])["ok"] == .bool(false))
            #expect(try success(bridge, "modernSave") == before)
        }
    }
}
