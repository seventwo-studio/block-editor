import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernBridgeTests {
    private func value<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func call(_ bridge: EditorBridge, _ command: String, _ handle: String = "a", _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        var fields = args; fields["command"] = .string(command); fields["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(fields)))
    }
    private func success(_ response: JSONValue) throws -> JSONValue {
        #expect(response["ok"] == .bool(true)); return try #require(response["value"])
    }
    private func document() throws -> ModernDocument { try ModernDocument(documentID: "modern", title: "A", blocks: [Block.paragraph(id: "p", text: "abcd")]) }
    private func create(_ bridge: EditorBridge, _ handle: String, policy: [String]? = nil) throws -> JSONValue {
        var input: [String: JSONValue] = ["actorID": .string(handle), "documentID": .string("modern"), "epoch": .string("modern-1"),
            "collaborationVersion": .number(7), "document": .object(try document().fields)]
        if let policy { input["allowedCommands"] = .array(policy.map(JSONValue.string)) }
        return try success(call(bridge, "createModern", handle, input))
    }
    private func field(_ title: Bool = false) throws -> JSONValue {
        try value(WritingField(node: title ? .document(documentID: "modern") : .baseline(blockID: "p", path: []), name: title ? "title" : "content"))
    }
    private func capture(_ bridge: EditorBridge, _ handle: String, _ start: Int, _ end: Int, title: Bool = false) throws -> JSONValue {
        try success(call(bridge, "modernCaptureTextRange", handle, ["field": field(title), "start": .number(Double(start)), "end": .number(Double(end))]))
    }
    private func command(_ bridge: EditorBridge, _ handle: String, _ command: String, target: JSONValue = .null,
                         arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        try call(bridge, "modernCommand", handle, ["request": .object(["documentID": .string("modern"), "epoch": .string("modern-1"),
            "command": .string(command), "target": target, "arguments": .object(arguments)])])
    }
    private func exchange(_ bridge: EditorBridge, _ a: String, _ b: String) throws {
        let first = try success(call(bridge, "modernChanges", a)), second = try success(call(bridge, "modernChanges", b))
        _ = try success(call(bridge, "modernReceive", a, ["batch": second])); _ = try success(call(bridge, "modernReceive", b, ["batch": first]))
    }

    @Test func explicitModernEndpointsReturnCheckedTransactionsFocusAndSavedAuthorHistory() throws {
        let bridge = EditorBridge(), initial = try create(bridge, "a")
        #expect(initial["version"] == .number(7) && initial["canUndo"] == .bool(false))
        let capabilities = try success(call(bridge, "modernCapabilities"))
        #expect(capabilities["protocolVersion"] == .number(7) && capabilities["cutoverToModern"] == .bool(false))
        #expect(capabilities["commands"]?.array?.count == 19)
        let target = try capture(bridge, "a", 0, 0, title: true)
        let edited = try success(command(bridge, "a", "replaceTitle", target: target, arguments: ["text": .string("Studio ")]))
        #expect(edited["status"] == .string("applied") && edited["document"]?["title"] == .string("Studio A"))
        let expectedTitleField = try field(true)
        #expect(edited["transaction"]?["actor"] == .string("a") && edited["focus"]?["field"] == expectedTitleField)
        let metadataTarget = try value(NodeID.document(documentID: "modern"))
        let appearance = try success(command(bridge, "a", "setAppearance", target: metadataTarget, arguments: ["field": .string("fontSize"), "value": .string("large")]))
        #expect(appearance["status"] == .string("applied") && appearance["focus"] == .null)
        let saved = try success(call(bridge, "modernSave"))
        _ = try success(call(bridge, "restoreModern", "restored", ["actorID": .string("a"), "snapshot": saved]))
        let undone = try success(command(bridge, "restored", "undo"))
        #expect(undone["document"]?["title"] == .string("Studio A") && undone["document"]?["appearance"]?["fontSize"] == .string("default"))
        let undoneTitle = try success(command(bridge, "restored", "undo"))
        #expect(undoneTitle["document"] == initial["document"] && undoneTitle["canRedo"] == .bool(true))
        _ = try success(command(bridge, "restored", "redo")); _ = try success(command(bridge, "restored", "redo"))
        let restored = try success(call(bridge, "modernDocument", "restored"))
        #expect(restored == appearance["document"])
        let noChange = try success(command(bridge, "restored", "setAppearance", target: metadataTarget, arguments: ["field": .string("fontSize"), "value": .string("large")]))
        #expect(noChange["status"] == .string("noop") && noChange["transaction"] == .null)
    }

    @Test func capturedBackwardReplacementPreservesPeerInsertionThroughTheBridge() throws {
        let bridge = EditorBridge(); _ = try create(bridge, "a"); _ = try create(bridge, "b")
        let selected = try capture(bridge, "a", 3, 1), peer = try capture(bridge, "b", 2, 2)
        _ = try success(command(bridge, "b", "replaceText", target: peer, arguments: ["text": .string("X")]))
        try exchange(bridge, "a", "b")
        let result = try success(command(bridge, "a", "replaceText", target: selected, arguments: ["text": .string("😀")]))
        #expect(result["document"]?["blocks"]?.array?[0]["content"]?.array == [textNode("a😀Xd")])
        let resolved = try success(call(bridge, "modernResolvePosition", "a", ["position": try #require(result["focus"])]))
        #expect(resolved["offset"] == .number(3))
        try exchange(bridge, "a", "b")
        let peerDocument = try success(call(bridge, "modernDocument", "b")); #expect(peerDocument == result["document"])
        let undo = try success(command(bridge, "a", "undo"))
        #expect(undo["document"]?["blocks"]?.array?[0]["content"]?.array == [textNode("abXcd")])
    }

    @Test func capturedFormattingPreservesDirectionAndLeavesUnobservedPeerAtomsUnformatted() throws {
        let bridge = EditorBridge(); _ = try create(bridge, "a"); _ = try create(bridge, "b")
        let selected = try capture(bridge, "a", 4, 0), peer = try capture(bridge, "b", 2, 2)
        _ = try success(command(bridge, "b", "replaceText", target: peer, arguments: ["text": .string("X")]))
        try exchange(bridge, "a", "b")
        let mark = JSONValue.object(["type": .string("semantic-color"), "value": .string("blue")])
        let result = try success(command(bridge, "a", "format", target: selected, arguments: ["markType": .string("semantic-color"), "mark": mark]))
        #expect(result["document"]?["blocks"]?.array?[0]["content"]?.array == [textNode("ab", marks: [mark]), textNode("X"), textNode("cd", marks: [mark])])
        #expect(result["selection"]?["start"] == selected["start"] && result["selection"]?["end"] == selected["end"])
    }

    @Test func localPolicyAndCompositionReturnUnchangedUnavailableAndPreservePeerRichContent() throws {
        let bridge = EditorBridge(); _ = try create(bridge, "a", policy: ["replaceText", "replaceTitle", "undo", "redo"]); _ = try create(bridge, "b")
        let target = try capture(bridge, "a", 0, 4)
        let denied = try success(command(bridge, "a", "format", target: target, arguments: ["markType": .string("bold"), "mark": .object(["type": .string("bold")])]))
        #expect(denied["status"] == .string("unavailable") && denied["reason"] == .string("hostPolicy") && denied["transaction"] == .null)
        let peer = try capture(bridge, "b", 0, 4)
        _ = try success(command(bridge, "b", "format", target: peer, arguments: ["markType": .string("bold"), "mark": .object(["type": .string("bold")])]))
        try exchange(bridge, "a", "b")
        let a = try success(call(bridge, "modernDocument", "a")), b = try success(call(bridge, "modernDocument", "b")); #expect(a == b)
        let capabilities = try success(call(bridge, "modernCapabilities", "a"))
        #expect(capabilities["commands"]?.array?.contains(.string("format")) == false)
        _ = try success(call(bridge, "modernComposition", "a", ["active": .bool(true)]))
        let title = try capture(bridge, "a", 0, 0, title: true)
        let unavailable = try success(command(bridge, "a", "replaceTitle", target: title, arguments: ["text": .string("draft")]))
        #expect(unavailable["status"] == .string("unavailable") && unavailable["reason"] == .string("compositionActive") && unavailable["document"] == a)
        let columns = try success(command(bridge, "a", "createColumns"))
        #expect(columns["status"] == .string("unavailable") && columns["reason"] == .string("hostPolicy"))
    }

    @Test func legacyEntryPointsHandleCollisionsAndMalformedModernRequestsDoNotPromoteOrMutate() throws {
        let bridge = EditorBridge(), initial = try create(bridge, "a")
        let old = try call(bridge, "create", "old", ["actorID": .string("old"), "documentID": .string("modern"), "epoch": .string("modern-1"), "collaborationVersion": .number(7)])
        #expect(old["ok"] == .bool(false))
        let collision = try call(bridge, "create", "a", ["actorID": .string("old"), "documentID": .string("modern")]); #expect(collision["ok"] == .bool(false))
        #expect(try call(bridge, "undo", "a")["ok"] == .bool(false))
        let base = try document().json(), documentJSON = String(decoding: base, as: UTF8.self)
        let raw = "{\"command\":\"createModern\",\"session\":\"raw\",\"actorID\":\"raw\",\"documentID\":\"modern\",\"epoch\":\"modern-1\",\"collaborationVersion\":7,\"document\":" + documentJSON.dropLast() + ",\"opaque\":9007199254740993}}"
        #expect(try JSONDecoder().decode(JSONValue.self, from: bridge.call(Data(raw.utf8)))["ok"] == .bool(false))
        let duplicate = "{\"command\":\"modernDocument\",\"session\":\"a\",\"session\":\"raw\"}"
        #expect(try JSONDecoder().decode(JSONValue.self, from: bridge.call(Data(duplicate.utf8)))["ok"] == .bool(false))
        _ = try create(bridge, "raw")
        let target = try capture(bridge, "a", 0, 0, title: true)
        var badTarget = try #require(target.object); badTarget["ignored"] = .bool(true)
        #expect(try command(bridge, "a", "replaceTitle", target: .object(badTarget), arguments: ["text": .string("bad")])["ok"] == .bool(false))
        let after = try success(call(bridge, "modernDocument", "a")); #expect(after == initial["document"])
    }

    @Test func heldPacketsExportRestoreAndReleaseWithoutPrematureReceipts() throws {
        let bridge = EditorBridge(); _ = try create(bridge, "a"); _ = try create(bridge, "b"); _ = try create(bridge, "c")
        _ = try success(call(bridge, "modernHoldRemote", "a", ["hold": .string("composition")]))
        let peer = try capture(bridge, "b", 1, 1, title: true)
        _ = try success(command(bridge, "b", "replaceTitle", target: peer, arguments: ["text": .string("peer")]))
        let packet = try success(call(bridge, "modernChanges", "b"))
        let held = try success(call(bridge, "modernReceive", "a", ["batch": packet]))
        #expect(held["syncState"]?["received"]?.array == [])
        let packets = try success(call(bridge, "modernDeferredChanges", "a"))
        _ = try success(call(bridge, "modernHoldRemote", "c", ["hold": .string("restored")]))
        let restored = try success(call(bridge, "modernRestoreDeferredChanges", "c", ["packets": packets]))
        #expect(restored["syncState"]?["received"]?.array == [])
        let a = try success(call(bridge, "modernReleaseRemote", "a", ["hold": .string("composition")]))
        let c = try success(call(bridge, "modernReleaseRemote", "c", ["hold": .string("restored")]))
        #expect(a["document"] == c["document"] && c["document"]?["title"] == .string("Apeer"))
        #expect(c["syncState"]?["received"]?.array?.count == 1)
    }
}
