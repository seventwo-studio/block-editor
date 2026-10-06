import BlockEditorCore
import Foundation
import Testing

@Suite struct ModernStructuralBridgeTests {
    private func value<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func call(_ bridge: EditorBridge, _ command: String, _ args: [String: JSONValue] = [:], handle: String = "a") throws -> JSONValue {
        var input = args; input["command"] = .string(command); input["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(input)))
    }
    private func success(_ value: JSONValue) throws -> JSONValue { #expect(value["ok"] == .bool(true)); return try #require(value["value"]) }
    private func fixture(_ name: String) throws -> ModernDocument {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/acceptance/modern-editor/documents/" + name + ".json")
        return try ModernDocument(json: Data(contentsOf: path))
    }
    private func create(_ bridge: EditorBridge, document: ModernDocument, handle: String = "a", policy: [String]? = nil) throws {
        var input: [String: JSONValue] = ["document": .object(document.fields), "documentID": .string(document.documentID), "epoch": .string("modern-1"), "actorID": .string(handle), "collaborationVersion": .number(7)]
        if let policy { input["allowedCommands"] = .array(policy.map(JSONValue.string)) }
        _ = try success(call(bridge, "createModern", input, handle: handle))
    }
    private func command(_ bridge: EditorBridge, document: ModernDocument, name: String, target: JSONValue = .null, arguments: [String: JSONValue] = [:], handle: String = "a") throws -> JSONValue {
        try call(bridge, "modernCommand", ["request": .object(["documentID": .string(document.documentID), "epoch": .string("modern-1"), "command": .string(name), "target": target, "arguments": .object(arguments)])], handle: handle)
    }
    private func selection(_ bridge: EditorBridge, nodes: [NodeID], handle: String = "a") throws -> JSONValue {
        try success(call(bridge, "modernCaptureNodes", ["nodes": value(nodes)], handle: handle))
    }
    private func boundary(_ bridge: EditorBridge, after: NodeID? = nil, handle: String = "a") throws -> JSONValue {
        var input: [String: JSONValue] = ["collection": try value(NodeCollection.root)]
        if let after { input["after"] = try value(after) }
        return try success(call(bridge, "modernCaptureBoundary", input, handle: handle))
    }

    @Test func independentNestedMoveFixtureKeepsSelectionOriginAndSingleUndoReopen() throws {
        let bridge = EditorBridge(), baseline = try fixture("nested"), expected = try fixture("nested-moved")
        try create(bridge, document: baseline)
        let identity = NodeID.baseline(blockID: "A", path: [])
        let target = JSONValue.object(["selection": try selection(bridge, nodes: [identity]), "boundary": try boundary(bridge)])
        let result = try success(command(bridge, document: baseline, name: "move", target: target))
        #expect(result["status"] == .string("applied") && result["transaction"]?["actor"] == .string("a"))
        #expect(result["document"] == .object(expected.fields))
        #expect(result["selection"]?["nodes"] == (try value([identity])))
        #expect(result["selectionIntent"]?["nodes"]?["_0"] == result["selection"])
        #expect(result["focusIntent"]?["nodes"]?["_0"] == result["selection"] && result["focus"] == .null)
        let saved = try success(call(bridge, "modernSave")); _ = try success(call(bridge, "destroy"))
        _ = try success(call(bridge, "restoreModern", ["actorID": .string("a"), "snapshot": saved], handle: "resumed"))
        #expect(try success(command(bridge, document: baseline, name: "undo", handle: "resumed"))["document"] == .object(baseline.fields))
        #expect(try success(command(bridge, document: baseline, name: "redo", handle: "resumed"))["document"] == .object(expected.fields))
    }

    @Test func checkedInsertFocusAndWholeBodyDeleteInsertionTargetAreUsableAndAtomic() throws {
        let bridge = EditorBridge(), baseline = try fixture("unicode"); try create(bridge, document: baseline)
        let block = try Block.paragraph(id: "new", text: "Writing")
        let insert = try success(command(bridge, document: baseline, name: "insertBlock", target: boundary(bridge), arguments: ["block": value(block)]))
        #expect(insert["status"] == .string("applied") && insert["focusIntent"]?["text"]?["_0"] == insert["focus"])
        #expect(insert["selectionIntent"]?["text"]?["_0"] == insert["selection"])
        let snapshot = try success(call(bridge, "modernChanges"))
        let creation = try #require(snapshot["changes"]?.array?.first?["id"])
        let insertedIdentity = try JSONDecoder().decode(ChangeID.self, from: JSONEncoder().encode(creation))
        let ids = [NodeID.inserted(creation: ElementID(change: insertedIdentity, index: 0), path: [])] + baseline.blocks.map { .baseline(blockID: $0.id, path: []) }
        let captured = try selection(bridge, nodes: ids)
        let target = JSONValue.object(["nodes": captured, "ranges": .array([])])
        let removed = try success(command(bridge, document: baseline, name: "delete", target: target))
        #expect(removed["document"]?["blocks"]?.array == [] && removed["document"]?["title"] == .string(baseline.title))
        #expect(removed["focus"] == .null && removed["selection"] == .null)
        let insertion = try #require(removed["focusIntent"]?["insertion"]?["_0"])
        let after = try success(command(bridge, document: baseline, name: "undo"))
        #expect(after["document"] == insert["document"])
        _ = try success(command(bridge, document: baseline, name: "redo"))
        let fresh = try success(command(bridge, document: baseline, name: "insertBlock", target: insertion, arguments: ["block": value(Block.paragraph(id: "fresh", text: "Resume"))]))
        #expect(fresh["document"]?["blocks"]?.array?.count == 1 && fresh["document"]?["blocks"]?.array?[0]["id"] == .string("fresh"))
    }

    @Test func malformedTargetsAndPoliciesCompositionAndScopeLeaveStateUnchanged() throws {
        let bridge = EditorBridge(), baseline = try fixture("unicode"); try create(bridge, document: baseline)
        let saved = try success(call(bridge, "modernSave")), a = NodeID.baseline(blockID: "A", path: [])
        var target = try #require(selection(bridge, nodes: [a]).object); target["ignored"] = .bool(true)
        let malformed = JSONValue.object(["selection": .object(target), "boundary": try boundary(bridge)])
        #expect(try command(bridge, document: baseline, name: "move", target: malformed)["ok"] == .bool(false))
        let wrongOrder = try call(bridge, "modernCaptureNodes", ["nodes": value([NodeID.baseline(blockID: "rtl", path: []), a])])
        #expect(wrongOrder["ok"] == .bool(false))
        let selected = try selection(bridge, nodes: [a]), delete = JSONValue.object(["nodes": selected, "ranges": .array([])])
        _ = try success(call(bridge, "modernComposition", ["active": .bool(true)]))
        let composing = try success(command(bridge, document: baseline, name: "delete", target: delete))
        #expect(composing["status"] == .string("unavailable") && composing["reason"] == .string("compositionActive"))
        _ = try success(call(bridge, "modernComposition", ["active": .bool(false)]))
        #expect(try success(call(bridge, "modernSave")) == saved)
        _ = try success(call(bridge, "modernSetAuthoringPolicy", ["allowedCommands": .array([.string("replaceText")])]))
        let denied = try success(command(bridge, document: baseline, name: "delete", target: delete))
        #expect(denied["status"] == .string("unavailable") && denied["reason"] == .string("hostPolicy"))
        let capabilities = try success(call(bridge, "modernCapabilities")); #expect(capabilities["commands"]?.array == [.string("replaceText")])
        #expect(try success(call(bridge, "modernSave")) == saved)
    }
}
