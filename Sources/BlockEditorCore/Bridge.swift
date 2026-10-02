import Foundation

/// A narrow JSON boundary shared by JNI and WASM. One instance per host executor.
public final class EditorBridge {
    private var sessions: [String: EditorSession] = [:]
    private var writingSessions: [String: WritingSession] = [:]
    public init() {}
    public func call(_ request: Data) -> Data {
        do {
            guard request.count <= 64_000_000 else { throw EditorError.invalidChange }
            let input = try JSONDecoder().decode(JSONValue.self, from: request)
            let result = try dispatch(input)
            return try canonicalEncoder().encode(JSONValue.object(["ok": .bool(true), "value": result]))
        } catch {
            if case WritingSessionError.recoveryRequired(let recovery) = error, let value = try? encode(recovery) {
                return (try? canonicalEncoder().encode(JSONValue.object([
                    "ok": .bool(false), "error": .string("writingRecoveryRequired"), "recovery": value]))) ?? Data()
            }
            if case EditorError.mergeRecoveryRequired(let recovery) = error,
               let value = try? encode(recovery) {
                return (try? canonicalEncoder().encode(JSONValue.object([
                    "ok": .bool(false), "error": .string("mergeRecoveryRequired"), "recovery": value]))) ?? Data()
            }
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
        if (command == "create" && [.number(3), .number(4), .number(5)].contains(input["collaborationVersion"])) ||
           (command == "restore" && [.number(3), .number(4), .number(5)].contains(input["snapshot"]?["version"])) || command == "cutoverToV3" {
            guard !handle.isEmpty, sessions[handle] == nil, writingSessions[handle] == nil,
                  let actor = input["actorID"]?.string else { throw EditorError.invalidChange }
            let writing: WritingSession
            if command == "restore" {
                writing = try WritingSession.restore(canonicalEncoder().encode(input["snapshot"] ?? .null), actorID: actor)
            } else if command == "cutoverToV3" {
                writing = try ProtocolMigration.cutoverToV3(decode(input["archive"], as: WritingCutoverArchive.self), actorID: actor,
                    oldWritersStopped: decode(input["oldWritersStopped"], as: Bool.self),
                    archivePersisted: decode(input["archivePersisted"], as: Bool.self),
                    resetUndoAcknowledged: decode(input["resetUndoAcknowledged"], as: Bool.self))
            } else {
                guard let documentID = input["documentID"]?.string, let epoch = input["epoch"]?.string else { throw EditorError.invalidChange }
                writing = try WritingSession(documentID: documentID, actorID: actor, epoch: epoch,
                    document: Document(json: canonicalEncoder().encode(input["blocks"] ?? .array([]))),
                    protocolVersion: decode(input["collaborationVersion"], as: Int.self))
            }
            writingSessions[handle] = writing
            return try writingSnapshot(writing)
        }
        if let writing = writingSessions[handle] { return try dispatchWriting(input, command: command, handle: handle, session: writing) }
        if command == "create" || command == "restore" || command == "cutoverToV2" {
            guard !handle.isEmpty, sessions[handle] == nil, let actor = input["actorID"]?.string else { throw EditorError.invalidChange }
            if command == "cutoverToV2" {
                guard let documentID = input["documentID"]?.string else { throw EditorError.invalidChange }
                sessions[handle] = try ProtocolMigration.cutoverToV2(canonicalEncoder().encode(input["snapshot"] ?? .null), newDocumentID: documentID, actorID: actor)
            } else if command == "restore" {
                sessions[handle] = try EditorSession.restore(canonicalEncoder().encode(input["snapshot"] ?? .null), actorID: actor)
            } else {
                guard let documentID = input["documentID"]?.string else { throw EditorError.invalidChange }
                let document = try Document(json: canonicalEncoder().encode(input["blocks"] ?? .array([])))
                sessions[handle] = try EditorSession(documentID: documentID, actorID: actor, document: document,
                    collaborationVersion: input["collaborationVersion"] == nil ? 1 : decode(input["collaborationVersion"], as: Int.self))
            }
        }
        guard let session = sessions[handle] else { throw EditorError.invalidChange }
        switch command {
        case "create", "restore", "cutoverToV2", "document": break
        case "close": sessions.removeValue(forKey: handle); return .null
        case "save": return try JSONDecoder().decode(JSONValue.self, from: session.save())
        case "mergeRecovery": return try session.mergeRecovery.map { try encode($0) } ?? .null
        case "repairMerge": try session.repairMerge(decode(input["repairs"], as: [MergeRepair].self))
        case "node": return try encode(session.node(at: decode(input["address"], as: NodeAddress.self)))
        case "nodeAddress": return try encode(session.address(of: decode(input["identity"], as: NodeID.self)))
        case "nodes": return try encode(session.nodes(in: decode(input["collection"], as: NodeCollection.self)))
        case "textAddress": return try encode(session.textAddress(of: decode(input["identity"], as: NodeID.self), field: input["field"]?.string ?? "content"))
        case "insertNode":
            let identity = try session.insertNode(input["value"] ?? .null, into: decode(input["collection"], as: NodeCollection.self),
                after: input["after"] == nil || input["after"] == .null ? nil : decode(input["after"], as: NodeID.self))
            return .object(["identity": try encode(identity), "snapshot": try snapshot(session)])
        case "moveNode":
            try session.moveNode(decode(input["identity"], as: NodeID.self), into: decode(input["collection"], as: NodeCollection.self),
                after: input["after"] == nil || input["after"] == .null ? nil : decode(input["after"], as: NodeID.self))
        case "deleteNode": try session.deleteNode(decode(input["identity"], as: NodeID.self))
        case "indent": try session.indent(decode(input["identity"], as: NodeID.self))
        case "outdent": try session.outdent(decode(input["identity"], as: NodeID.self))
        case "setNodeField":
            try session.setNodeField(decode(input["identity"], as: NodeID.self), path: decode(input["path"], as: [String].self), value: input["value"] ?? .null)
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
        return try snapshot(session)
    }
    private func snapshot(_ session: EditorSession) throws -> JSONValue {
        .object(["blocks": try encode(session.document.blocks), "canUndo": .bool(session.canUndo), "canRedo": .bool(session.canRedo)])
    }
    private func writingSnapshot(_ session: WritingSession) throws -> JSONValue {
        .object(["blocks": try encode(session.document.blocks), "canUndo": .bool(session.canUndo), "canRedo": .bool(session.canRedo)])
    }
    private func dispatchWriting(_ input: JSONValue, command: String, handle: String, session: WritingSession) throws -> JSONValue {
        switch command {
        case "document": break
        case "close": writingSessions.removeValue(forKey: handle); return .null
        case "save": return try JSONDecoder().decode(JSONValue.self, from: session.save())
        case "syncState": return try encode(session.syncState)
        case "changes": return try encode(session.changes(since: input["since"] == nil ? WritingSyncState() : decode(input["since"], as: WritingSyncState.self)))
        case "receive": try session.receive(decode(input["batch"], as: WritingBatch.self))
        case "mergeRecovery": return try session.mergeRecovery.map { try encode($0) } ?? .null
        case "restoreRecovery": try session.restoreRecovery(canonicalEncoder().encode(input["recovery"] ?? .null))
        case "repairWritingUndo": try session.repairUndo(decode(input["target"], as: ChangeID.self))
        case "repairWritingRedo": try session.repairRedo(decode(input["target"], as: ChangeID.self))
        case "repairWritingText": try session.repairText(node: decode(input["identity"], as: NodeID.self), field: decode(input["field"], as: String.self), text: decode(input["text"], as: String.self))
        case "node": return try encode(session.node(at: decode(input["address"], as: NodeAddress.self)))
        case "setNodeField": try session.setNodeField(decode(input["identity"], as: NodeID.self), path: decode(input["path"], as: [String].self), value: input["value"] ?? .null)
        case "nodeAddress": return try encode(session.address(of: decode(input["identity"], as: NodeID.self)))
        case "textAddress": return try encode(session.textAddress(of: decode(input["identity"], as: NodeID.self), field: input["field"]?.string ?? "content"))
        case "position": return try encode(session.position(at: decode(input["address"], as: TextAddress.self), offset: decode(input["offset"], as: Int.self), affinity: input["affinity"] == nil ? .before : decode(input["affinity"], as: TextAffinity.self)))
        case "resolvePosition": return try encode(session.resolve(decode(input["position"], as: WritingPosition.self)))
        case "composition": session.isComposing = try decode(input["active"], as: Bool.self)
        case "undo": try session.undo()
        case "redo": try session.redo()
        case "replaceText", "splitParagraph", "softBreak", "format":
            let address = try decode(input["address"], as: TextAddress.self)
            let start = try decode(input["start"], as: Int.self), end = try decode(input["end"], as: Int.self)
            guard start >= 0, end >= start else { throw EditorError.invalidRange }
            let range = start..<end
            if command == "format" {
                try session.format(at: address, range: range, markType: input["markType"]?.string ?? "", mark: input["mark"] == .null ? nil : input["mark"])
                break
            }
            let position: WritingPosition
            if command == "splitParagraph" {
                guard let blockID = input["newBlockID"]?.string else { throw EditorError.invalidChange }
                position = try session.splitParagraph(at: address, range: range, newBlockID: blockID)
            } else if command == "softBreak" { position = try session.softBreak(at: address, range: range) }
            else { position = try session.replaceText(at: address, range: range, with: input["text"]?.string ?? "", marks: input["marks"]?.array) }
            return .object(["snapshot": try writingSnapshot(session), "position": try encode(position)])
        case "selectedText":
            let start = try decode(input["start"], as: Int.self), end = try decode(input["end"], as: Int.self)
            guard start >= 0, end >= start else { throw EditorError.invalidRange }
            return try encode(session.selectedText(at: decode(input["address"], as: TextAddress.self), range: start..<end))
        case "writingSelection": return try encode(session.selection(from: decode(input["anchor"], as: WritingPosition.self), to: decode(input["focus"], as: WritingPosition.self)))
        case "copySelection": return try encode(session.copy(decode(input["selection"], as: WritingSelection.self)))
        case "copyClipboard": return try encode(session.copyClipboard(decode(input["selection"], as: WritingSelection.self)))
        case "clipboardText":
            guard let text = input["text"]?.string, text.utf16.count <= 1_000_000 else { throw EditorError.invalidRange }
            let clipboard: WritingClipboard
            switch input["format"]?.string ?? "inline" {
            case "inline": clipboard = .plainText(text)
            case "multiline": clipboard = try .multilineText(text)
            case "markdown": clipboard = try .markdown(text)
            default: throw EditorError.invalidChange
            }
            return try encode(clipboard)
        case "pasteBlocks":
            let policy = input["policy"] == nil ? WritingPastePolicy() : try decode(input["policy"], as: WritingPastePolicy.self)
            let position = try session.pasteBlocks(decode(input["clipboard"], as: WritingClipboard.self), replacing: decode(input["range"], as: WritingTextRange.self), policy: policy)
            return .object(["snapshot": try writingSnapshot(session), "position": try encode(position)])
        case "pasteInline":
            let policy = input["policy"] == nil ? WritingPastePolicy() : try decode(input["policy"], as: WritingPastePolicy.self)
            let position = try session.pasteInline(decode(input["clipboard"], as: WritingClipboard.self), replacing: decode(input["range"], as: WritingTextRange.self), policy: policy)
            return .object(["snapshot": try writingSnapshot(session), "position": try encode(position)])
        case "pasteCollection":
            let policy = input["policy"] == nil ? WritingPastePolicy() : try decode(input["policy"], as: WritingPastePolicy.self)
            let after = input["after"] == nil || input["after"] == .null ? nil : try decode(input["after"], as: NodeID.self)
            let selection = try session.pasteCollection(decode(input["clipboard"], as: WritingClipboard.self), into: decode(input["collection"], as: NodeCollection.self), after: after, policy: policy)
            return .object(["snapshot": try writingSnapshot(session), "selection": try encode(selection)])
        case "deleteSelection":
            let selected = try session.delete(decode(input["selection"], as: WritingSelection.self))
            return .object(["snapshot": try writingSnapshot(session), "selection": try encode(selected)])
        case "moveSelection", "duplicateSelection":
            let selected = try decode(input["selection"], as: WritingSelection.self)
            let collection = try decode(input["collection"], as: NodeCollection.self)
            let after = input["after"] == nil || input["after"] == .null ? nil : try decode(input["after"], as: NodeID.self)
            let result = command == "moveSelection" ? try session.move(selected, into: collection, after: after) : try session.duplicate(selected, into: collection, after: after)
            return .object(["snapshot": try writingSnapshot(session), "selection": try encode(result)])
        case "collectionNodes": return try encode(session.collectionNodes(in: decode(input["collection"], as: NodeCollection.self)))
        case "insertCollectionNodes":
            guard let values = input["values"]?.array else { throw EditorError.invalidChange }
            let collection = try decode(input["collection"], as: NodeCollection.self)
            let after = input["after"] == nil || input["after"] == .null ? nil : try decode(input["after"], as: NodeID.self)
            let result = try session.insertCollectionNodes(values, into: collection, after: after)
            return .object(["snapshot": try writingSnapshot(session), "selection": try encode(result)])
        case "allowedBlockTypes":
            if input["types"] == .null { session.allowedBlockTypes = nil }
            else {
                guard let values = input["types"]?.array, values.allSatisfy({ $0.string != nil }) else { throw EditorError.invalidChange }
                session.allowedBlockTypes = Set(values.compactMap(\.string))
            }
        case "convertBlock", "markdownShortcut", "enterListItem":
            let address = try decode(input["address"], as: TextAddress.self)
            let position: WritingPosition
            if command == "convertBlock" {
                position = try session.convertBlock(at: address, offset: decode(input["offset"], as: Int.self), to: decode(input["target"], as: WritingBlockTarget.self))
            } else if command == "markdownShortcut" {
                position = try session.markdownShortcut(at: address, offset: decode(input["offset"], as: Int.self))
            } else {
                let start = try decode(input["start"], as: Int.self), end = try decode(input["end"], as: Int.self)
                guard start >= 0, end >= start else { throw EditorError.invalidRange }
                position = try session.enterListItem(at: address, range: start..<end, newItemID: decode(input["newItemID"], as: String.self))
            }
            return .object(["snapshot": try writingSnapshot(session), "position": try encode(position)])
        case "mergeParagraphs":
            let position = try session.mergeParagraphs(left: decode(input["left"], as: NodeID.self), right: decode(input["right"], as: NodeID.self))
            return .object(["snapshot": try writingSnapshot(session), "position": try encode(position)])
        case "markdown": return .string(try Markdown.serialize(session.document))
        default: throw EditorError.invalidChange
        }
        return try writingSnapshot(session)
    }
}
