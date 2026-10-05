import Foundation
import Testing
@testable import BlockEditorCore

@Suite struct ModernMigrationBridgeTests {
    private func json<Value: Encodable>(_ value: Value) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
    private func call(_ b: EditorBridge, _ name: String, _ fields: [String: JSONValue] = [:], handle: String = "fresh") throws -> JSONValue {
        var input = fields; input["command"] = .string(name); input["session"] = .string(handle)
        return try JSONDecoder().decode(JSONValue.self, from: b.call(canonicalEncoder().encode(input)))
    }
    private func success(_ b: EditorBridge, _ name: String, _ fields: [String: JSONValue] = [:], handle: String = "fresh") throws -> JSONValue {
        let r = try call(b, name, fields, handle: handle); #expect(r["ok"] == .bool(true)); return try #require(r["value"])
    }
    private func archive(_ bytes: Data = Data(#"[{"id":"p","type":"paragraph","content":[{"type":"text","text":"ABC"}]}]"#.utf8)) -> ModernCutoverArchive {
        ModernCutoverArchive(documentID: "d", epoch: "new", source: .document(format: .blockArray, bytes: bytes), originals: [bytes])
    }
    private func prepare(_ b: EditorBridge, _ archive: ModernCutoverArchive) throws -> (String, Data) {
        let value = try success(b, "modernPrepareCutover", ["archive": json(archive)]), id = try #require(value["archiveID"]?.string)
        #expect(value["status"] == .string("prepared")); return (id, try archive.json())
    }
    private func verify(_ b: EditorBridge, _ id: String, _ bytes: Data) throws {
        _ = try success(b, "modernVerifyCutoverReadback", ["archiveID": .string(id), "offset": .number(0), "bytes": .string(bytes.base64EncodedString())])
    }
    private func activation(_ id: String) -> [String: JSONValue] {
        ["archiveID": .string(id), "actorID": .string("a"), "oldWritersStopped": .bool(true), "archivePersisted": .bool(true), "resetUndoAcknowledged": .bool(true)]
    }
    @Test func chunkedArchiveExactReadbackFreshSessionAndDuplicateActivationStaySeparateFromLegacy() throws {
        let b = EditorBridge(), a = archive(), bytes = try a.json()
        let began = try success(b, "modernBeginCutoverArchive", ["byteCount": .number(Double(bytes.count))]), id = try #require(began["archiveID"]?.string)
        let first = bytes.prefix(37), second = bytes.dropFirst(37)
        let chunk: [String: JSONValue] = ["archiveID": .string(id), "offset": .number(0), "bytes": .string(first.base64EncodedString())]
        #expect(try success(b, "modernAppendCutoverArchive", chunk)["receivedBytes"] == .number(37))
        #expect(try success(b, "modernAppendCutoverArchive", chunk)["receivedBytes"] == .number(37))
        #expect(try call(b, "modernPrepareCutover", ["archiveID": .string(id)])["ok"] == .bool(false))
        _ = try success(b, "modernAppendCutoverArchive", ["archiveID": .string(id), "offset": .number(37), "bytes": .string(second.base64EncodedString())])
        let ready = try success(b, "modernPrepareCutover", ["archiveID": .string(id)])
        #expect(ready["status"] == .string("prepared") && ready["document"]?["title"] == .string(""))
        let exported = try success(b, "modernCutoverArchiveBytes", ["archiveID": .string(id), "offset": .number(0), "length": .number(Double(bytes.count))])
        #expect(exported["bytes"] == .string(bytes.base64EncodedString()))
        #expect(try call(b, "cutoverToModern", activation(id))["ok"] == .bool(false))
        #expect(try call(b, "modernVerifyCutoverReadback", ["archiveID": .string(id), "offset": .number(0), "bytes": .string(Data("wrong".utf8).base64EncodedString())])["ok"] == .bool(false))
        try verify(b, id, bytes)
        for field in ["oldWritersStopped", "archivePersisted", "resetUndoAcknowledged"] {
            var input = activation(id); input[field] = .bool(false); #expect(try call(b, "cutoverToModern", input)["ok"] == .bool(false))
        }
        let created = try success(b, "cutoverToModern", activation(id))
        #expect(created["version"] == .number(7) && created["canUndo"] == .bool(false) && created["originMapping"]?.array?.count == 1)
        #expect(try success(b, "modernChanges")["changes"] == .array([]))
        let saved = try success(b, "modernSave")
        #expect(try call(b, "cutoverToModern", activation(id), handle: "another")["ok"] == .bool(false))
        #expect(try success(b, "modernSave") == saved)
        _ = try success(b, "restoreModern", ["actorID": .string("a"), "snapshot": saved], handle: "reopen")
        #expect(try success(b, "modernDocument", handle: "reopen") == created["document"])
    }
    @Test func uploadGapsConflictingRetriesUnknownKeysAndReadbackGapsNeverAdvanceProgress() throws {
        let b = EditorBridge(), a = archive(), bytes = try a.json(), begin = try success(b, "modernBeginCutoverArchive", ["byteCount": .number(Double(bytes.count))]), id = try #require(begin["archiveID"]?.string)
        let attempts: [[String: JSONValue]] = [["archiveID": .string(id), "offset": .number(1), "bytes": .string("QQ==")], ["archiveID": .string(id), "offset": .number(0), "bytes": .string("QQ=="), "unknown": .bool(true)]]
        for fields in attempts {
            #expect(try call(b, "modernAppendCutoverArchive", fields)["ok"] == .bool(false))
        }
        _ = try success(b, "modernAppendCutoverArchive", ["archiveID": .string(id), "offset": .number(0), "bytes": .string(bytes.base64EncodedString())])
        #expect(try call(b, "modernAppendCutoverArchive", ["archiveID": .string(id), "offset": .number(0), "bytes": .string("QQ==")])["ok"] == .bool(false))
        #expect(try success(b, "modernPrepareCutover", ["archiveID": .string(id)])["verifiedBytes"] == .number(0))
        #expect(try call(b, "modernVerifyCutoverReadback", ["archiveID": .string(id), "offset": .number(1), "bytes": .string(bytes.dropFirst().base64EncodedString())])["ok"] == .bool(false))
        try verify(b, id, bytes); try verify(b, id, bytes)
        #expect(try success(b, "modernPrepareCutover", ["archiveID": .string(id)])["verifiedBytes"] == .number(Double(bytes.count)))
        _ = try success(b, "modernForgetCutoverArchive", ["archiveID": .string(id)])
        #expect(try call(b, "cutoverToModern", activation(id))["ok"] == .bool(false))
    }
    @Test func incompatibleArchivesStayExportableAndCannotReplaceAnyExistingSessionHandle() throws {
        let b = EditorBridge(), raw = Data(#"[{"id":"A","type":"columns","vendor":{"columns":["opaque"]}}]"#.utf8), a = archive(raw)
        let refused = try success(b, "modernPrepareCutover", ["archive": json(a)]), id = try #require(refused["archiveID"]?.string), bytes = try a.json()
        #expect(refused["status"] == .string("unavailable") && refused["reason"] == .string("incompatibleLegacyRepresentation"))
        #expect(try success(b, "modernCutoverArchiveBytes", ["archiveID": .string(id), "offset": .number(0), "length": .number(Double(bytes.count))])["bytes"] == .string(bytes.base64EncodedString()))
        let (valid, data) = try prepare(b, archive()); try verify(b, valid, data)
        _ = try success(b, "create", ["actorID": .string("old"), "documentID": .string("d"), "collaborationVersion": .number(2), "blocks": .array([])], handle: "old")
        let saved = try success(b, "save", handle: "old")
        #expect(try call(b, "cutoverToModern", activation(valid), handle: "old")["ok"] == .bool(false))
        #expect(try success(b, "save", handle: "old") == saved)
        #expect(try success(b, "cutoverToModern", activation(valid))["canUndo"] == .bool(false))
    }
    @Test func boundedReservationsReleaseWithoutTighteningAcceptedDocumentLimits() throws {
        let b = EditorBridge(); var ids: [String] = []
        for _ in 0..<8 { ids.append(try #require(success(b, "modernBeginCutoverArchive", ["byteCount": .number(1)])["archiveID"]?.string)) }
        #expect(try call(b, "modernBeginCutoverArchive", ["byteCount": .number(1)])["ok"] == .bool(false))
        _ = try success(b, "modernForgetCutoverArchive", ["archiveID": .string(ids[0])])
        #expect(try success(b, "modernBeginCutoverArchive", ["byteCount": .number(1)])["status"] == .string("uploading"))
        let other = EditorBridge(), reserve = try success(other, "modernBeginCutoverArchive", ["byteCount": .number(384_000_000)]), id = try #require(reserve["archiveID"]?.string)
        #expect(try call(other, "modernBeginCutoverArchive", ["byteCount": .number(1)])["ok"] == .bool(false))
        _ = try success(other, "modernForgetCutoverArchive", ["archiveID": .string(id)])
        #expect(try success(other, "modernBeginCutoverArchive", ["byteCount": .number(1)])["status"] == .string("uploading"))
    }
    @Test func validLargeOriginalsCrossTheABIInChunksWithoutClippingOpaqueDocumentData() throws {
        let b = EditorBridge(), payload = String(repeating: "x", count: 25_000_000)
        let raw = Data((#"[{"id":"opaque","type":"consumer","payload":""# + payload + #""}]"#).utf8), a = archive(raw), bytes = try a.json()
        #expect(bytes.count > 64_000_000 && raw.count < 32_000_000)
        let began = try success(b, "modernBeginCutoverArchive", ["byteCount": .number(Double(bytes.count))]), id = try #require(began["archiveID"]?.string)
        for offset in stride(from: 0, to: bytes.count, by: 8_000_000) {
            let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + 8_000_000))
            _ = try success(b, "modernAppendCutoverArchive", ["archiveID": .string(id), "offset": .number(Double(offset)), "bytes": .string(chunk.base64EncodedString())])
        }
        let prepared = try success(b, "modernPrepareCutover", ["archiveID": .string(id)])
        #expect(prepared["status"] == .string("prepared") && prepared["document"]?["blocks"]?.array?.first?["payload"] == .string(payload))
        for offset in stride(from: 0, to: bytes.count, by: 8_000_000) {
            let length = min(bytes.count - offset, 8_000_000)
            let exported = try success(b, "modernCutoverArchiveBytes", ["archiveID": .string(id), "offset": .number(Double(offset)), "length": .number(Double(length))])
            let chunk = try #require(exported["bytes"]?.string)
            #expect(Data(base64Encoded: chunk) == bytes.subdata(in: offset..<(offset + length)))
            let verified = try success(b, "modernVerifyCutoverReadback", ["archiveID": .string(id), "offset": .number(Double(offset)), "bytes": .string(chunk)])
            #expect(verified["verifiedBytes"] == .number(Double(offset + length)) && verified["document"] == nil)
        }
        let fresh = try success(b, "cutoverToModern", activation(id))
        #expect(fresh["document"]?["blocks"]?.array?.first?["payload"] == .string(payload) && fresh["canUndo"] == .bool(false))
    }
}
