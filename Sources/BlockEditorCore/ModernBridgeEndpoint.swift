import Foundation

/// Explicit new endpoints share EditorBridge's JNI/WASM transport. Their
/// capability list advertises only commands with implemented core semantics.
final class ModernBridgeEndpoint {
    private var sessions: [String: ModernSession] = [:]
    private var holds: [String: [String: () throws -> Void]] = [:]
    private let commands = ["replaceText", "replaceTitle", "setAppearance", "format", "insertBlock", "move", "delete", "createColumns", "removeColumns", "resizeColumns", "convertBlock", "softBreak", "splitBlock", "mergeBlocks", "undo", "redo"]
    func contains(_ handle: String) -> Bool { sessions[handle] != nil }
    func handles(_ input: JSONValue) -> Bool {
        let command = input["command"]?.string ?? ""
        return command.hasPrefix("modern") || ["createModern", "restoreModern", "cutoverToModern"].contains(command) || contains(input["session"]?.string ?? "")
    }
    func dispatch(_ input: JSONValue) throws -> JSONValue {
        guard let command = input["command"]?.string else { throw EditorError.invalidChange }
        let handle = input["session"]?.string ?? ""
        if command == "modernCapabilities" {
            try allowed(input, ["command", "session"])
            var values: [String: JSONValue] = ["protocolVersion": .number(7), "format": .string(ModernDocument.format), "formatVersion": .number(1),
                "commands": .array(commands.map(JSONValue.string)), "cutoverToModern": .bool(false)]
            if let session = sessions[handle] {
                values["commands"] = .array(commands.filter { session.allowedCommands?.contains($0) ?? true }.map(JSONValue.string))
                values["canUndo"] = .bool(session.canUndo); values["canRedo"] = .bool(session.canRedo)
                values["isComposing"] = .bool(session.isComposing); values["recoveryRequired"] = .bool(session.mergeRecovery != nil)
            }
            return .object(values)
        }
        if command == "createModern" || command == "restoreModern" {
            guard !handle.isEmpty, sessions[handle] == nil, let actor = input["actorID"]?.string else { throw EditorError.invalidChange }
            let session: ModernSession
            if command == "createModern" {
                try allowed(input, ["command", "session", "actorID", "documentID", "epoch", "collaborationVersion", "document", "allowedCommands"])
                guard let version = input["collaborationVersion"]?.numberAsInt else { throw EditorError.invalidChange }
                guard version == 7 else { throw EditorError.unsupportedVersion(version) }
                guard let documentID = input["documentID"]?.string, let epoch = input["epoch"]?.string,
                      let fields = input["document"]?.object else { throw EditorError.invalidChange }
                session = try ModernSession(documentID: documentID, actorID: actor, epoch: epoch, document: ModernDocument(fields: fields))
            } else {
                try allowed(input, ["command", "session", "actorID", "snapshot", "allowedCommands"])
                session = try ModernSession.restore(canonicalEncoder().encode(input["snapshot"] ?? .null), actorID: actor)
            }
            if let policy = input["allowedCommands"] { session.allowedCommands = try authoringPolicy(policy) }
            sessions[handle] = session; return try snapshot(session)
        }
        if command == "cutoverToModern" { throw EditorError.invalidChange }
        guard let session = sessions[handle] else { throw EditorError.invalidChange }
        switch command {
        case "destroy": try allowed(input, ["command", "session"]); sessions.removeValue(forKey: handle); holds.removeValue(forKey: handle); return .null
        case "modernDocument": try allowed(input, ["command", "session"]); return .object(session.document.fields)
        case "modernSnapshot": try allowed(input, ["command", "session"]); return try snapshot(session)
        case "modernSave": try allowed(input, ["command", "session"]); return try JSONDecoder().decode(JSONValue.self, from: session.save())
        case "modernChanges":
            try allowed(input, ["command", "session", "since"])
            let receipt = try input["since"].map { try decode($0, as: WritingSyncState.self) }
            return try encode(session.changes(since: receipt))
        case "modernReceive":
            try allowed(input, ["command", "session", "batch"])
            try session.receive(ModernBatch(json: canonicalEncoder().encode(input["batch"] ?? .null)))
        case "modernRecovery": try allowed(input, ["command", "session"]); return try session.mergeRecovery.map(encode) ?? .null
        case "modernRestoreRecovery":
            try allowed(input, ["command", "session", "recovery"]); try session.restoreRecovery(canonicalEncoder().encode(input["recovery"] ?? .null))
        case "modernRepairUndo", "modernRepairRedo":
            try allowed(input, ["command", "session", "targets"])
            let targets = try decode(input["targets"], as: [ChangeID].self)
            if command == "modernRepairUndo" { try session.repairUndo(targets) } else { try session.repairRedo(targets) }
        case "modernPosition":
            try allowed(input, ["command", "session", "field", "offset", "affinity"])
            return try encode(session.position(in: decode(input["field"], as: WritingField.self), offset: integer(input["offset"]),
                affinity: input["affinity"] == nil ? .before : decode(input["affinity"], as: TextAffinity.self)))
        case "modernResolvePosition":
            try allowed(input, ["command", "session", "position"]); return try encode(session.resolve(decode(input["position"], as: WritingPosition.self)))
        case "modernCaptureTextRange":
            try allowed(input, ["command", "session", "field", "start", "end"])
            return try encode(session.captureTextRange(in: decode(input["field"], as: WritingField.self), start: integer(input["start"]), end: integer(input["end"])))
        case "modernCaptureBoundary":
            try allowed(input, ["command", "session", "collection", "after"])
            let collection = try decode(input["collection"], as: NodeCollection.self)
            let after = try input["after"].map { try decode($0, as: NodeID.self) }
            return try encode(session.captureBoundary(in: collection, after: after))
        case "modernCaptureNodes":
            try allowed(input, ["command", "session", "nodes"])
            return try encode(session.captureNodes(decode(input["nodes"], as: [NodeID].self)))
        case "modernComposition":
            try allowed(input, ["command", "session", "active"]); session.isComposing = try decode(input["active"], as: Bool.self)
        case "modernSetAuthoringPolicy":
            try allowed(input, ["command", "session", "allowedCommands"])
            guard let policy = input["allowedCommands"] else { throw EditorError.invalidChange }
            session.allowedCommands = policy == .null ? nil : try authoringPolicy(policy)
            session.endTypingGroup()
        case "modernEndTypingGroup": try allowed(input, ["command", "session"]); session.endTypingGroup()
        case "modernHoldRemote":
            try allowed(input, ["command", "session", "hold"])
            guard let token = input["hold"]?.string, validToken(token), holds[handle]?[token] == nil else { throw EditorError.invalidChange }
            holds[handle, default: [:]][token] = try session.holdRemoteChanges()
        case "modernReleaseRemote":
            try allowed(input, ["command", "session", "hold"])
            guard let token = input["hold"]?.string, let release = holds[handle]?.removeValue(forKey: token) else { throw EditorError.invalidChange }
            try release()
        case "modernDeferredChanges": try allowed(input, ["command", "session"]); return try JSONDecoder().decode(JSONValue.self, from: session.exportDeferredChanges())
        case "modernRestoreDeferredChanges":
            try allowed(input, ["command", "session", "packets"]); try session.restoreDeferredChanges(canonicalEncoder().encode(input["packets"] ?? .null))
        case "modernRetryDeferredChanges": try allowed(input, ["command", "session"]); try session.retryDeferredChanges()
        case "modernCommand":
            try allowed(input, ["command", "session", "request"]); return try execute(input["request"] ?? .null, session: session)
        default: throw EditorError.invalidChange
        }
        return try snapshot(session)
    }
    private func execute(_ request: JSONValue, session: ModernSession) throws -> JSONValue {
        try allowed(request, ["documentID", "epoch", "command", "target", "arguments"])
        guard request["documentID"] == .string(session.documentID) else { throw EditorError.differentDocument }
        guard request["epoch"] == .string(session.epoch) else { throw ModernSessionError.incompatibleEpoch }
        guard let command = request["command"]?.string, let arguments = request["arguments"], arguments.object != nil else { throw EditorError.invalidChange }
        func result(_ status: String, transaction: ChangeID? = nil, position: WritingPosition? = nil,
                    selection: JSONValue? = nil, focusIntent: ModernFocusIntent? = nil,
                    selectionIntent: ModernSelectionIntent? = nil, reason: String? = nil) throws -> JSONValue {
            var fields = try snapshot(session).object!
            fields["status"] = .string(status); fields["transaction"] = try transaction.map(encode) ?? .null
            fields["focus"] = try position.map(encode) ?? .null
            fields["selection"] = try selection ?? position.map { try encode(WritingTextRange(start: $0, end: $0)) } ?? .null
            fields["focusIntent"] = try (focusIntent ?? position.map(ModernFocusIntent.text)).map(encode) ?? .null
            fields["selectionIntent"] = try (selectionIntent ?? position.map { .text(WritingTextRange(start: $0, end: $0)) }).map(encode) ?? .null
            if let reason { fields["reason"] = .string(reason) }
            return .object(fields)
        }
        guard commands.contains(command) else { return try result("unavailable", reason: "unsupportedCommand") }
        if session.allowedCommands?.contains(command) == false { return try result("unavailable", reason: "hostPolicy") }
        if session.isComposing { return try result("unavailable", reason: "compositionActive") }
        if session.mergeRecovery != nil { return try result("recoveryRequired", reason: "pendingRecovery") }
        let before = Set(session.syncState.received)
        var position: WritingPosition?, selection: JSONValue?
        var focusIntent: ModernFocusIntent?, selectionIntent: ModernSelectionIntent?
        func structural(_ outcome: ModernStructuralResult) throws {
            focusIntent = outcome.focus; selectionIntent = outcome.selection
            if case .text(let caret) = outcome.focus { position = caret }
            if case .nodes(let selected) = outcome.selection { selection = try encode(selected) }
            else if case .text(let range) = outcome.selection { selection = try encode(range) }
        }
        do {
            switch command {
            case "replaceText", "replaceTitle":
                try allowed(arguments, ["text", "typingGroup"])
                guard let text = arguments["text"]?.string else { throw EditorError.invalidChange }
                let target = try decode(request["target"], as: ModernTextRange.self)
                if command == "replaceTitle", target.start.field != session.titleField || target.end.field != session.titleField { throw EditorError.invalidPath }
                if let group = arguments["typingGroup"], group.string == nil { throw EditorError.invalidChange }
                position = try session.replaceText(in: target, with: text, typingGroup: arguments["typingGroup"]?.string)
            case "setAppearance":
                try allowed(arguments, ["field", "value"])
                guard try decode(request["target"], as: NodeID.self) == .document(documentID: session.documentID),
                      let field = arguments["field"]?.string, let value = arguments["value"]?.string else { throw EditorError.invalidChange }
                try session.setAppearance(field: field, value: value)
            case "format":
                try allowed(arguments, ["markType", "mark"])
                guard let type = arguments["markType"]?.string else { throw EditorError.invalidChange }
                let target = try decode(request["target"], as: ModernTextRange.self)
                try session.format(in: target, markType: type, mark: arguments["mark"] == .null ? nil : arguments["mark"])
                let range = WritingTextRange(start: target.start, end: target.end)
                selection = try encode(range); selectionIntent = .text(range)
            case "insertBlock":
                try allowed(arguments, ["block"])
                let boundary = try decode(request["target"], as: ModernBlockBoundary.self)
                let block = try decode(arguments["block"], as: Block.self)
                try structural(session.insertBlock(block, at: boundary))
            case "move":
                try allowed(arguments, [])
                try structural(session.move(decode(request["target"], as: ModernMoveTarget.self)))
            case "delete":
                try allowed(arguments, [])
                try structural(session.delete(decode(request["target"], as: ModernDeleteTarget.self)))
            case "createColumns":
                try allowed(arguments, ["layout"])
                guard let layout = arguments["layout"] else { throw EditorError.invalidChange }
                try structural(session.createColumns(decode(request["target"], as: ModernCreateColumnsTarget.self), layout: layout))
            case "removeColumns":
                try allowed(arguments, [])
                try structural(session.removeColumns(decode(request["target"], as: ModernColumnTarget.self)))
            case "resizeColumns":
                try allowed(arguments, ["splitBasisPoints"])
                try structural(session.resizeColumns(decode(request["target"], as: ModernColumnTarget.self), splitBasisPoints: integer(arguments["splitBasisPoints"])))
            case "convertBlock":
                try structural(session.convertBlock(in: decode(request["target"], as: ModernTextRange.self), to: decode(arguments, as: WritingBlockTarget.self)))
            case "softBreak":
                try allowed(arguments, [])
                position = try session.softBreak(in: decode(request["target"], as: ModernTextRange.self))
            case "splitBlock":
                try allowed(arguments, ["newBlockID"])
                guard let label = arguments["newBlockID"]?.string else { throw EditorError.invalidChange }
                try structural(session.splitBlock(in: decode(request["target"], as: ModernTextRange.self), newBlockID: label))
            case "mergeBlocks":
                try allowed(arguments, [])
                try structural(session.mergeBlocks(decode(request["target"], as: ModernNodeSelection.self)))
            case "undo", "redo":
                try allowed(arguments, [])
                guard request["target"] == nil || request["target"] == .null else { throw EditorError.invalidChange }
                if command == "undo" { try session.undo() } else { try session.redo() }
            default: throw EditorError.invalidChange
            }
        } catch ModernSessionError.unavailable(let reason) { return try result("unavailable", reason: reason) }
        catch ModernSessionError.recoveryRequired { return try result("recoveryRequired", reason: "schemaOrIdentityConflict") }
        catch let error as EditorError {
            if command == "convertBlock", case .invalidDocument = error { return try result("unavailable", reason: "conversionMetadataConflict") }
            if ["createColumns", "removeColumns", "resizeColumns", "convertBlock", "softBreak", "splitBlock", "mergeBlocks"].contains(command), error == .invalidChange || error == .invalidPath {
                return try result("unavailable", reason: ["convertBlock", "softBreak", "splitBlock", "mergeBlocks"].contains(command) ? "invalidWritingTargetOrArguments" : "invalidColumnTargetOrArguments")
            }
            throw error
        }
        let transaction = session.syncState.received.first { !before.contains($0) && $0.actor == session.actorID }
        return try result(transaction == nil ? "noop" : "applied", transaction: transaction, position: position, selection: selection, focusIntent: focusIntent, selectionIntent: selectionIntent)
    }
    private func authoringPolicy(_ value: JSONValue) throws -> Set<String> {
        let policy = try decode(value, as: [String].self)
        guard Set(policy).count == policy.count, Set(policy).isSubset(of: Set(commands)) else { throw EditorError.invalidChange }
        return Set(policy)
    }
    private func snapshot(_ session: ModernSession) throws -> JSONValue {
        .object(["version": .number(7), "document": .object(session.document.fields), "syncState": try encode(session.syncState),
            "canUndo": .bool(session.canUndo), "canRedo": .bool(session.canRedo),
            "recovery": try session.mergeRecovery.map(encode) ?? .null])
    }
    private func allowed(_ value: JSONValue, _ keys: Set<String>) throws {
        guard let fields = value.object, Set(fields.keys).isSubset(of: keys) else { throw EditorError.invalidChange }
    }
    private func decode<T: Codable>(_ value: JSONValue?, as: T.Type) throws -> T {
        guard let value else { throw EditorError.invalidChange }
        let decoded = try JSONDecoder().decode(T.self, from: canonicalEncoder().encode(value))
        guard try encode(decoded) == value else { throw EditorError.invalidChange }
        return decoded
    }
    private func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
    private func integer(_ value: JSONValue?) throws -> Int {
        guard let integer = value?.numberAsInt else { throw EditorError.invalidChange }; return integer
    }
}

private extension JSONValue {
    var numberAsInt: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value,
              abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(exactly: value)
    }
}
