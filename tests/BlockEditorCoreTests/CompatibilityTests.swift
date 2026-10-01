import BlockEditorCore
import Foundation
import Testing

@Test func documentMigrationCorpusRetainsEveryFieldAndRejectsInvalidKnownShapes() throws {
    let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    for sample in try #require(corpus["valid"]?.array) {
        let blocks = try #require(sample["blocks"])
        let session = try LegacyMigration.importDocument(JSONEncoder().encode(blocks), newDocumentID: "migration", actorID: "local")
        #expect(try JSONDecoder().decode(JSONValue.self, from: session.document.json()) == blocks)
        try session.insert(.paragraph(id: "additional", text: "Temporary edit"))
        try session.undo()
        let restored = try EditorSession.restore(session.save(), actorID: "local")
        #expect(try JSONDecoder().decode(JSONValue.self, from: restored.document.json()) == blocks)
    }
    for sample in try #require(corpus["invalid"]?.array) {
        let data = try JSONEncoder().encode(try #require(sample["blocks"]))
        #expect(throws: EditorError.self) { try LegacyMigration.importDocument(data, newDocumentID: "invalid", actorID: "local") }
    }
}

@Test func reusedChildIDsRemainIndependentlyEditable() throws {
    let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let sample = try #require(corpus["valid"]?.array?.first { $0["name"]?.string == "scoped child identities and opaque metadata" })
    let session = try LegacyMigration.importDocument(JSONEncoder().encode(sample["blocks"]), newDocumentID: "scoped", actorID: "a")
    let left = TextAddress("a", path: ["items", "shared", "content"])
    let right = TextAddress("b", path: ["items", "shared", "content"])
    let cell = TextAddress("t", path: ["rows", "one", "cells", "shared", "content"])
    let otherCell = TextAddress("t", path: ["rows", "two", "cells", "shared", "content"])
    try session.setText(at: left, to: "Edited list")
    try session.setText(at: cell, to: "Edited cell")
    let restored = try EditorSession.restore(session.save(), actorID: "a")
    #expect(try restored.text(at: left) == "Edited list")
    #expect(try restored.text(at: right) == "Before")
    #expect(try restored.text(at: cell) == "Edited cell")
    #expect(try restored.text(at: otherCell) == "Before")
    try restored.undo(); try restored.undo()
    #expect(try JSONDecoder().decode(JSONValue.self, from: restored.document.json()) == sample["blocks"])
}

@Test func sharedBridgeFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "bridge", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let bridge = EditorBridge()
    var last: JSONValue = .null
    for request in try #require(fixture["requests"]?.array) {
        last = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(request)))
        #expect(last["ok"] == .bool(true))
    }
    #expect(last["value"] == fixture["expected"])
}

@Test func sharedStructureBridgeFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "structure", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let bridge = EditorBridge()
    var captured: [String: JSONValue] = [:]
    for step in try #require(fixture["steps"]?.array) {
        var request = try #require(step["request"]?.object)
        for (key, source) in step["bindings"]?.object ?? [:] {
            let name = try #require(source.string)
            request[key] = try #require(captured[name])
        }
        let response = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(JSONValue.object(request))))
        #expect(response["ok"] == .bool(true), "\(request["command"] ?? .null): \(response)")
        if let name = step["capture"]?.string { captured[name] = response["value"] }
    }
    for pair in fixture["equal"]?.array ?? [] {
        let names = try #require(pair.array).compactMap { $0.string }
        #expect(try #require(captured[names[0]]) == #require(captured[names[1]]), "\(names)")
    }
    #expect(captured["final"] == fixture["expected"])
    #expect(captured["resolvedPosition"] == fixture["expectedPosition"])
    #expect(captured["cutover"] == fixture["expectedCutover"])
    #expect(captured["cutoverChanges"]?["version"] == .number(2))
    for (name, blocks) in fixture["expectedBlocks"]?.object ?? [:] {
        #expect(try #require(captured[name]?["blocks"]) == blocks, "\(name) preserved document")
    }
}

@Test func sharedRecoveryBridgeFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "recovery", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let bridge = EditorBridge()
    var captured: [String: JSONValue] = [:]
    for step in try #require(fixture["steps"]?.array) {
        var request = try #require(step["request"]?.object)
        for (key, source) in step["bindings"]?.object ?? [:] {
            let path: [String]
            if let values = source.array { path = values.compactMap { $0.string } }
            else { path = [try #require(source.string)] }
            let name = try #require(path.first)
            let root = try #require(captured[name])
            request[key] = try #require(root.value(at: Array(path.dropFirst())))
        }
        let response = try JSONDecoder().decode(JSONValue.self, from: bridge.call(JSONEncoder().encode(JSONValue.object(request))))
        if let error = step["error"] {
            #expect(response["ok"] == .bool(false)); #expect(response["error"] == error)
            if let name = step["capture"]?.string { captured[name] = try #require(response["recovery"]) }
        } else {
            #expect(response["ok"] == .bool(true), "\(response)")
            if let name = step["capture"]?.string { captured[name] = try #require(response["value"]) }
        }
    }
    for pair in try #require(fixture["equal"]?.array) {
        let values = try #require(pair.array)
        let names = values.compactMap { $0.string }
        #expect(captured[names[0]] == captured[names[1]])
    }
    #expect(captured["cleared"] == .null)
    #expect(captured["proposalA"]?["reason"] == .string("identityConflict"))
    #expect(captured["proposalA"]?["batch"]?["changes"]?.array?.count == 2)
    #expect(captured["finalA"] == fixture["expected"])
    #expect(captured["afterUndo"] == fixture["expectedAfterUndo"])
}

@Test func v2StructuralReplayPreservesTheMigrationCorpus() throws {
    let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
    let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    for sample in try #require(corpus["valid"]?.array) {
        let blocks = try #require(sample["blocks"])
        let document = try Document(json: JSONEncoder().encode(blocks))
        let session = try EditorSession(documentID: "v2-corpus", actorID: "a", document: document, collaborationVersion: 2)
        try session.insert(.paragraph(id: "temporary")); try session.undo()
        let restored = try EditorSession.restore(session.save(), actorID: "a")
        #expect(try JSONDecoder().decode(JSONValue.self, from: restored.document.json()) == blocks)
    }
}

@Test func invalidKnownShapesAreRejectedWithoutChangingTheDocument() throws {
    let session = try EditorSession(documentID: "doc", actorID: "a", document: Document(blocks: [.paragraph(id: "p", text: "keep")]))
    let before = try session.document
    #expect(throws: EditorError.self) {
        try session.insert(Block(fields: ["id": .string("h"), "type": .string("heading"), "level": .number(8)]))
    }
    #expect(throws: EditorError.self) {
        try session.setInline(at: TextAddress("p"), nodes: [.object(["type": .string("text"), "text": .string("bad"), "marks": .array([.object(["type": .string("unknown")])])])])
    }
    #expect(try session.document == before)
    #expect(!session.canUndo)
}
