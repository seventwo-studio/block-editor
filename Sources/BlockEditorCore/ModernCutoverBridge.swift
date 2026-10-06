import Foundation

/// Archive upload/readback is local executor state, never replicated or activated
/// by receiving bytes. Chunking preserves valid archive limits at the 64 MB ABI.
final class ModernCutoverBridge {
    private struct Upload { let expected: Int; var bytes = Data() }
    private struct Prepared { let plan: ModernCutoverPreparation; var verified = 0; var applied = false }
    private var uploads: [String: Upload] = [:]
    private var prepared: [String: Prepared] = [:]
    private let names = ["modernBeginCutoverArchive", "modernAppendCutoverArchive", "modernPrepareCutover", "modernCutoverArchiveBytes", "modernVerifyCutoverReadback", "modernRemapCutoverPosition", "modernForgetCutoverArchive", "cutoverToModern"]
    func handles(_ command: String) -> Bool { names.contains(command) }
    private var reserved: Int { uploads.values.reduce(0) { $0 + $1.expected } + prepared.values.reduce(0) { $0 + $1.plan.archiveBytes.count } }
    private func reserve(_ bytes: Int) throws {
        guard uploads.count + prepared.count < 8, bytes > 0, bytes <= 384_000_000 - reserved else { throw EditorError.recoveryCapacityExceeded }
    }
    private func allowed(_ input: JSONValue, _ keys: Set<String>) throws {
        guard let fields = input.object, Set(fields.keys).isSubset(of: keys.union(["command", "session"])) else { throw EditorError.invalidChange }
    }
    private func integer(_ value: JSONValue?) throws -> Int {
        guard case .number(let n) = value, n.isFinite, n.rounded() == n, n >= 0, n <= 384_000_000 else { throw EditorError.invalidChange }; return Int(n)
    }
    private func bytes(_ value: JSONValue?) throws -> Data {
        guard let text = value?.string, let data = Data(base64Encoded: text), data.count <= 8_000_000,
              data.base64EncodedString() == text else { throw EditorError.invalidChange }; return data
    }
    private func status(_ id: String) -> JSONValue {
        if let value = prepared[id] {
            return .object(["archiveID": .string(id), "byteCount": .number(Double(value.plan.archiveBytes.count)), "verifiedBytes": .number(Double(value.verified)),
                "status": .string(value.applied ? "applied" : "prepared")])
        }
        let value = uploads[id]!
        return .object(["archiveID": .string(id), "byteCount": .number(Double(value.expected)), "receivedBytes": .number(Double(value.bytes.count)), "status": .string("uploading")])
    }
    private func json<Value: Encodable>(_ value: Value) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
    func dispatch(_ input: JSONValue, create: (ModernSession) throws -> JSONValue) throws -> JSONValue {
        let command = input["command"]?.string ?? ""
        if command == "modernBeginCutoverArchive" {
            try allowed(input, ["byteCount"]); let count = try integer(input["byteCount"]); try reserve(count)
            let id = UUID().uuidString; uploads[id] = Upload(expected: count); return status(id)
        }
        if command == "modernPrepareCutover", let value = input["archive"] {
            try allowed(input, ["archive"])
            let archive = try ModernCutoverArchive(json: canonicalEncoder().encode(value)), bytes = try archive.json(); try reserve(bytes.count)
            let id = UUID().uuidString; uploads[id] = Upload(expected: bytes.count, bytes: bytes)
            return try prepare(id)
        }
        guard let id = input["archiveID"]?.string else { throw EditorError.invalidChange }
        if command == "modernForgetCutoverArchive" {
            try allowed(input, ["archiveID"]); uploads.removeValue(forKey: id); prepared.removeValue(forKey: id); return .null
        }
        guard uploads[id] != nil || prepared[id] != nil else { throw EditorError.invalidChange }
        switch command {
        case "modernAppendCutoverArchive":
            try allowed(input, ["archiveID", "offset", "bytes"])
            guard var value = uploads[id] else { throw EditorError.invalidChange }
            let offset = try integer(input["offset"]), data = try bytes(input["bytes"])
            guard !data.isEmpty, offset <= value.bytes.count, data.count <= value.expected - offset else { throw EditorError.invalidChange }
            if offset < value.bytes.count {
                guard offset + data.count <= value.bytes.count, value.bytes.subdata(in: offset..<(offset + data.count)) == data else { throw EditorError.invalidChange }
            } else { value.bytes.append(data); uploads[id] = value }
            return status(id)
        case "modernPrepareCutover":
            try allowed(input, ["archiveID"]); return try prepare(id)
        case "modernCutoverArchiveBytes":
            try allowed(input, ["archiveID", "offset", "length"])
            let data = prepared[id]?.plan.archiveBytes ?? uploads[id]!.bytes
            let offset = try integer(input["offset"]), length = try integer(input["length"])
            guard length <= 8_000_000, offset <= data.count, length <= data.count - offset else { throw EditorError.invalidRange }
            return .object(["archiveID": .string(id), "byteCount": .number(Double(data.count)), "offset": .number(Double(offset)),
                            "bytes": .string(data.subdata(in: offset..<(offset + length)).base64EncodedString())])
        case "modernVerifyCutoverReadback":
            try allowed(input, ["archiveID", "offset", "bytes"])
            guard var value = prepared[id], !value.applied else { throw EditorError.invalidChange }
            let offset = try integer(input["offset"]), data = try bytes(input["bytes"]), total = value.plan.archiveBytes.count
            guard !data.isEmpty, offset <= value.verified, data.count <= total - offset,
                  value.plan.archiveBytes.subdata(in: offset..<(offset + data.count)) == data else { throw ModernCutoverError.archiveReadbackMismatch }
            if offset < value.verified { guard offset + data.count <= value.verified else { throw EditorError.invalidChange } }
            else { value.verified += data.count; prepared[id] = value }
            return status(id)
        case "modernRemapCutoverPosition":
            try allowed(input, ["archiveID", "position", "kind"])
            guard let value = prepared[id], let position = input["position"] else { throw EditorError.invalidChange }
            let data = try canonicalEncoder().encode(position), result: WritingPosition
            if input["kind"] == .string("writing") {
                let old = try JSONDecoder().decode(WritingPosition.self, from: data); guard try json(old) == position else { throw EditorError.invalidChange }; result = try value.plan.remap(old)
            } else if input["kind"] == .string("text") {
                let old = try JSONDecoder().decode(TextPosition.self, from: data); guard try json(old) == position else { throw EditorError.invalidChange }; result = try value.plan.remap(old)
            } else { throw EditorError.invalidChange }
            return try json(result)
        case "cutoverToModern":
            try allowed(input, ["archiveID", "actorID", "oldWritersStopped", "archivePersisted", "resetUndoAcknowledged"])
            guard var value = prepared[id], !value.applied, value.verified == value.plan.archiveBytes.count,
                  let actor = input["actorID"]?.string else { throw ModernCutoverError.archiveReadbackMismatch }
            let session = try value.plan.makeSession(actorID: actor, archiveReadback: value.plan.archiveBytes,
                oldWritersStopped: input["oldWritersStopped"] == .bool(true), archivePersisted: input["archivePersisted"] == .bool(true),
                resetUndoAcknowledged: input["resetUndoAcknowledged"] == .bool(true))
            let result = try create(session); value.applied = true; prepared[id] = value
            var fields = result.object!; fields["originMapping"] = try json(value.plan.originMapping); fields["archiveID"] = .string(id)
            return .object(fields)
        default: throw EditorError.invalidChange
        }
    }
    private func prepare(_ id: String) throws -> JSONValue {
        if let value = prepared[id] { return try preparedStatus(id, value.plan) }
        guard let value = uploads[id], value.bytes.count == value.expected else { throw EditorError.invalidChange }
        do {
            let plan = try ProtocolMigration.prepareModernCutover(ModernCutoverArchive(json: value.bytes))
            guard plan.archiveBytes.count <= 384_000_000 - (reserved - value.expected) else { throw EditorError.recoveryCapacityExceeded }
            prepared[id] = Prepared(plan: plan); uploads.removeValue(forKey: id); return try preparedStatus(id, plan)
        } catch ModernCutoverError.incompatibleRepresentation {
            return .object(["archiveID": .string(id), "status": .string("unavailable"), "reason": .string("incompatibleLegacyRepresentation")])
        } catch ModernCutoverError.unreconciledInput {
            return .object(["archiveID": .string(id), "status": .string("unavailable"), "reason": .string("unreconciledLegacyInput")])
        }
    }
    private func preparedStatus(_ id: String, _ plan: ModernCutoverPreparation) throws -> JSONValue {
        var fields = status(id).object!; fields["document"] = .object(plan.document.fields)
        fields["originMapping"] = try json(plan.originMapping); return .object(fields)
    }
}
