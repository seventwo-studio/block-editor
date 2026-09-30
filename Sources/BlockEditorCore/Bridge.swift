import Foundation

/// A narrow JSON boundary shared by JNI and WASM. One instance per host executor.
public final class EditorBridge {
    private var sessions: [String: EditorSession] = [:]
    public init() {}
    public func call(_ request: Data) -> Data {
        do {
            guard request.count <= 64_000_000 else { throw EditorError.invalidChange }
            let input = try JSONDecoder().decode(JSONValue.self, from: request)
            let result = try dispatch(input)
            return try canonicalEncoder().encode(JSONValue.object(["ok": .bool(true), "value": result]))
        } catch {
            return (try? canonicalEncoder().encode(JSONValue.object(["ok": .bool(false), "error": .string(String(describing: error))]))) ?? Data()
        }
    }
    private func decode<T: Decodable>(_ value: JSONValue?, as: T.Type) throws -> T {
        guard let value else { throw EditorError.invalidChange }
        return try JSONDecoder().decode(T.self, from: canonicalEncoder().encode(value))
    }
    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value))
    }
    private func dispatch(_ input: JSONValue) throws -> JSONValue {
        guard let command = input["command"]?.string else { throw EditorError.invalidChange }
        let handle = input["session"]?.string ?? ""
        if command == "create" || command == "restore" {
            guard !handle.isEmpty, sessions[handle] == nil, let actor = input["actorID"]?.string else { throw EditorError.invalidChange }
            if command == "restore" {
                sessions[handle] = try EditorSession.restore(canonicalEncoder().encode(input["snapshot"] ?? .null), actorID: actor)
            } else {
                guard let documentID = input["documentID"]?.string else { throw EditorError.invalidChange }
                let document = try Document(json: canonicalEncoder().encode(input["blocks"] ?? .array([])))
                sessions[handle] = try EditorSession(documentID: documentID, actorID: actor, document: document)
            }
        }
        guard let session = sessions[handle] else { throw EditorError.invalidChange }
        switch command {
        case "create", "restore", "document": break
        case "close": sessions.removeValue(forKey: handle); return .null
        case "save": return try JSONDecoder().decode(JSONValue.self, from: session.save())
        case "position":
            return try encode(session.position(at: decode(input["address"], as: TextAddress.self),
                offset: decode(input["offset"], as: Int.self),
                affinity: input["affinity"] == nil ? .before : decode(input["affinity"], as: TextAffinity.self)))
        case "resolvePosition": return .number(Double(try session.offset(of: decode(input["position"], as: TextPosition.self))))
        case "syncState": return try encode(session.syncState)
        case "changes": return try encode(session.changes(since: input["since"] == nil ? SyncState() : decode(input["since"], as: SyncState.self)))
        case "receive": try session.receive(decode(input["batch"], as: ChangeBatch.self))
        case "presence":
            try session.receivePresence(decode(input["presence"], as: Presence.self)); return try encode(session.presence)
        case "removePresence": session.removePresence(actor: input["actorID"]?.string ?? ""); return try encode(session.presence)
        case "undo": try session.undo()
        case "redo": try session.redo()
        case "insert": try session.insert(decode(input["block"], as: Block.self), after: input["after"]?.string)
        case "move": try session.move(blockID: input["blockID"]?.string ?? "", after: input["after"]?.string)
        case "delete": try session.delete(blockID: input["blockID"]?.string ?? "")
        case "setField":
            try session.setField(blockID: input["blockID"]?.string ?? "", path: decode(input["path"], as: [String].self), value: input["value"] ?? .null)
        case "setText":
            try session.setText(at: decode(input["address"], as: TextAddress.self), to: input["text"]?.string ?? "")
        case "setInline":
            try session.setInline(at: decode(input["address"], as: TextAddress.self), nodes: decode(input["nodes"], as: [JSONValue].self))
        case "replaceText", "format":
            let address = try decode(input["address"], as: TextAddress.self)
            let start = try decode(input["start"], as: Int.self), end = try decode(input["end"], as: Int.self)
            guard start >= 0, end >= start else { throw EditorError.invalidRange }
            if command == "replaceText" {
                try session.replaceText(at: address, range: start..<end, with: input["text"]?.string ?? "", marks: input["marks"]?.array)
            } else {
                try session.format(at: address, range: start..<end, markType: input["markType"]?.string ?? "", mark: input["mark"] == .null ? nil : input["mark"])
            }
        case "allowedBlockTypes": session.allowedBlockTypes = input["types"]?.array.map { Set($0.compactMap(\.string)) }
        case "markdown": return .string(try Markdown.serialize(session.document))
        default: throw EditorError.invalidChange
        }
        return .object(["blocks": try encode(session.document.blocks), "canUndo": .bool(session.canUndo), "canRedo": .bool(session.canRedo)])
    }
}
