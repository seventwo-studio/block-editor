import Foundation

/// Explicit new endpoints share EditorBridge's JNI/WASM transport. Their
/// capability list advertises only commands with implemented core semantics.
final class ModernBridgeEndpoint {
    private var sessions: [String: ModernSession] = [:]
    private var holds: [String: [String: () throws -> Void]] = [:]
    private struct CutPublication { let preparation: ModernCutPreparation; let bytes: Int }
    private var cuts: [String: [String: CutPublication]] = [:]
    private let commands = ModernSession.authorCommands
    private let cutover = ModernCutoverBridge()
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
                "commands": .array(commands.map(JSONValue.string)), "cutoverToModern": .bool(true)]
            if let session = sessions[handle] {
                values["commands"] = .array(commands.filter { session.allowedCommands?.contains($0) ?? true }.map(JSONValue.string))
                values["canUndo"] = .bool(session.canUndo); values["canRedo"] = .bool(session.canRedo)
                values["isComposing"] = .bool(session.isComposing); values["recoveryRequired"] = .bool(session.mergeRecovery != nil)
            }
            let asyncEnabled = sessions[handle]?.allowedCommands?.contains("completeAsyncBlock") ?? true
            values["codeLanguages"] = .array(ModernCodeLanguages.supported.map(JSONValue.string))
            values["tableActions"] = .array((sessions[handle]?.allowedCommands?.contains("tableStructure") ?? true) ? ModernTableAction.allCases.map { .string($0.rawValue) } : [])
            values["allowedBlockTypes"] = sessions[handle]?.allowedBlockTypes.map { .array($0.sorted().map(JSONValue.string)) } ?? .null
            values["allowedMarkTypes"] = sessions[handle]?.allowedMarkTypes.map { .array($0.sorted().map(JSONValue.string)) } ?? .null
            values["asyncKinds"] = .array(asyncEnabled ? ["image", "file", "embed"].map(JSONValue.string) : [])
            values["clipboardVersion"] = .number(2); values["canCopy"] = .bool(true)
            values["localHistorySelectionVersion"] = .number(1)
            let cutSession = sessions[handle]
            values["canCut"] = .bool(cutSession.map { !$0.isComposing && $0.mergeRecovery == nil &&
                ($0.allowedCommands == nil || $0.allowedCommands!.contains("delete") || $0.allowedCommands!.contains("replaceTitle")) } ?? true)
            let listEnabled = sessions[handle]?.allowedCommands?.contains("listStructure") ?? true
            values["listActions"] = .array([ModernListAction.indent, .outdent, .reorder, .setStyle, .setChecked].filter {
                listEnabled && (sessions[handle]?.allowedListActions?.contains($0) ?? true)
            }.map { .string($0.rawValue) })
            return .object(values)
        }
        if command == "modernClipboard" {
            try allowed(input, ["command", "session", "parts", "text", "mode", "encoded"])
            if let encoded = input["encoded"]?.string {
                guard input["parts"] == nil, input["text"] == nil, input["mode"] == nil else { throw EditorError.invalidChange }
                return try encode(ModernClipboard(json: Data(encoded.utf8)))
            }
            if let parts = input["parts"] {
                guard input["text"] == nil, input["mode"] == nil else { throw EditorError.invalidChange }
                return try encode(ModernClipboard(parts: decode(parts, as: [WritingClipboardPart].self)))
            }
            guard let text = input["text"]?.string else { throw EditorError.invalidChange }
            switch input["mode"]?.string ?? "plain" {
            case "plain": return try encode(ModernClipboard.plain(text))
            case "multiline": return try encode(ModernClipboard.multiline(text))
            case "markdown": return try encode(ModernClipboard.markdown(text))
            default: throw EditorError.invalidChange
            }
        }
        if command == "modernInsertionValue" {
            try allowed(input, ["command", "session", "descriptorID", "id", "childIDs"])
            guard let descriptorID = input["descriptorID"]?.string, let id = input["id"]?.string else { throw EditorError.invalidChange }
            return try ModernInsertionCatalog.value(descriptorID, id: id, childIDs: decode(input["childIDs"], as: [String].self))
        }
        if command == "modernInsertionCatalog" {
            try allowed(input, ["command", "session", "query"])
            return try encode(ModernInsertionCatalog.search(input["query"]?.string ?? "").filter { sessions[handle]?.allowedBlockTypes?.contains($0.blockType) ?? true })
        }
        if command == "createModern" || command == "restoreModern" {
            guard !handle.isEmpty, sessions[handle] == nil, let actor = input["actorID"]?.string else { throw EditorError.invalidChange }
            let session: ModernSession
            if command == "createModern" {
                try allowed(input, ["command", "session", "actorID", "documentID", "epoch", "collaborationVersion", "document", "allowedCommands", "allowedListActions", "allowedBlockTypes", "allowedMarkTypes"])
                guard let version = input["collaborationVersion"]?.numberAsInt else { throw EditorError.invalidChange }
                guard version == 7 else { throw EditorError.unsupportedVersion(version) }
                guard let documentID = input["documentID"]?.string, let epoch = input["epoch"]?.string,
                      let fields = input["document"]?.object else { throw EditorError.invalidChange }
                session = try ModernSession(documentID: documentID, actorID: actor, epoch: epoch, document: ModernDocument(fields: fields))
            } else {
                try allowed(input, ["command", "session", "actorID", "snapshot", "allowedCommands", "allowedListActions", "allowedBlockTypes", "allowedMarkTypes"])
                session = try ModernSession.restore(canonicalEncoder().encode(input["snapshot"] ?? .null), actorID: actor)
            }
            if let policy = input["allowedCommands"] { session.allowedCommands = try authoringPolicy(policy) }
            if let policy = input["allowedListActions"] { session.allowedListActions = try listPolicy(policy) }
            if let policy = input["allowedBlockTypes"] { session.allowedBlockTypes = try contentPolicy(policy, blocks: true) }
            if let policy = input["allowedMarkTypes"] { session.allowedMarkTypes = try contentPolicy(policy, blocks: false) }
            sessions[handle] = session; return try snapshot(session)
        }
        if cutover.handles(command) {
            if command == "cutoverToModern" { guard !handle.isEmpty, sessions[handle] == nil else { throw EditorError.invalidChange } }
            return try cutover.dispatch(input) { session in
                let result = try self.snapshot(session); self.sessions[handle] = session; return result
            }
        }
        guard let session = sessions[handle] else { throw EditorError.invalidChange }
        if ["modernCaptureLocalNodes", "modernSetLocalSelection", "modernLocalSelection", "modernExportHistorySelection", "modernRestoreHistorySelection"].contains(command) {
            return try localSelectionCommand(input, session: session, command: command)
        }
        switch command {
        case "destroy": try allowed(input, ["command", "session"]); sessions.removeValue(forKey: handle); holds.removeValue(forKey: handle); cuts.removeValue(forKey: handle); return .null
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
        case "modernNode":
            try allowed(input, ["command", "session", "address"])
            return try encode(session.node(at: decode(input["address"], as: NodeAddress.self)))
        case "modernNodes":
            try allowed(input, ["command", "session", "collection"])
            return try encode(session.nodes(in: decode(input["collection"], as: NodeCollection.self)))
        case "modernField":
            try allowed(input, ["command", "session", "node", "name"])
            return try encode(session.field(node: decode(input["node"], as: NodeID.self), name: input["name"]?.string ?? "content"))
        case "modernText":
            try allowed(input, ["command", "session", "field"])
            return .string(try session.text(in: decode(input["field"], as: WritingField.self)))
        case "modernLogicalFields":
            try allowed(input, ["command", "session", "collapsed", "includingTitle"])
            return try encode(session.logicalFields(collapsed: Set(input["collapsed"].map { try decode($0, as: [NodeID].self) } ?? []), includingTitle: input["includingTitle"] != .bool(false)))
        case "modernParentCollection":
            try allowed(input, ["command", "session", "node"])
            return try encode(session.parentCollection(of: decode(input["node"], as: NodeID.self)))
        case "modernCaptureTextSpan":
            try allowed(input, ["command", "session", "start", "end", "collapsed"])
            return try encode(session.captureTextSpan(from: decode(input["start"], as: WritingPosition.self), to: decode(input["end"], as: WritingPosition.self), collapsed: Set(input["collapsed"].map { try decode($0, as: [NodeID].self) } ?? [])))
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
        case "modernCapturePasteBoundary":
            try allowed(input, ["command", "session", "collection", "after"])
            let after = try input["after"].map { try decode($0, as: NodeID.self) }
            return try encode(session.capturePasteBoundary(in: decode(input["collection"], as: NodeCollection.self), after: after))
        case "modernCaptureListBoundary":
            try allowed(input, ["command", "session", "collection", "after"])
            let after = try input["after"].map { try decode($0, as: NodeID.self) }
            return try encode(session.captureListBoundary(in: decode(input["collection"], as: NodeCollection.self), after: after))
        case "modernAvailability":
            try allowed(input, ["command", "session", "name"])
            guard let name = input["name"]?.string else { throw EditorError.invalidChange }
            return try encode(session.availability(for: name))
        case "modernCaptureTableTarget":
            try allowed(input, ["command", "session", "table", "row", "cell"])
            let row = try input["row"].map { try decode($0, as: NodeID.self) }
            let cell = try input["cell"].map { try decode($0, as: NodeID.self) }
            return try encode(session.captureTableTarget(table: decode(input["table"], as: NodeID.self), row: row, cell: cell))
        case "modernCaptureCodeTarget":
            try allowed(input, ["command", "session", "node"])
            return try encode(session.captureCodeTarget(decode(input["node"], as: NodeID.self)))
        case "modernCaptureMediaTarget":
            try allowed(input, ["command", "session", "node"])
            return try encode(session.captureMediaTarget(decode(input["node"], as: NodeID.self)))
        case "modernRetainAsyncResult":
            try allowed(input, ["command", "session", "target", "metadata", "reason"])
            guard let metadata = input["metadata"]?.object else { throw EditorError.invalidChange }
            try session.retainAsyncBlockResult(decode(input["target"], as: ModernAsyncTarget.self), metadata: metadata, reason: input["reason"]?.string ?? "awaitingPersistence")
        case "modernCaptureListNodes":
            try allowed(input, ["command", "session", "nodes"])
            return try encode(session.captureListNodes(decode(input["nodes"], as: [NodeID].self)))
        case "modernCaptureNodes":
            try allowed(input, ["command", "session", "nodes"])
            return try encode(session.captureNodes(decode(input["nodes"], as: [NodeID].self)))
        case "modernCopy":
            try allowed(input, ["command", "session", "target"])
            return try encode(session.copyClipboard(decode(input["target"], as: ModernDeleteTarget.self)))
        case "modernPrepareCut":
            try allowed(input, ["command", "session", "target"])
            guard (cuts[handle]?.count ?? 0) < 64 else { throw EditorError.recoveryCapacityExceeded }
            let preparation = try session.prepareCut(decode(input["target"], as: ModernDeleteTarget.self))
            let identifier = UUID().uuidString
            let response: JSONValue = .object(["preparationID": .string(identifier), "documentID": .string(session.documentID),
                "epoch": .string(session.epoch), "clipboard": try encode(preparation.clipboard), "target": try encode(preparation.target)])
            let bytes = try canonicalEncoder().encode(response).count
            let used = cuts[handle]?.values.reduce(0, { $0 + $1.bytes }) ?? 0
            guard bytes <= 64_000_000 - used - 1024 else { throw EditorError.recoveryCapacityExceeded }
            cuts[handle, default: [:]][identifier] = CutPublication(preparation: preparation, bytes: bytes)
            return response
        case "modernFinishCut":
            try allowed(input, ["command", "session", "preparationID", "documentID", "epoch", "published"])
            guard let identifier = input["preparationID"]?.string else { throw EditorError.invalidChange }
            let published = try decode(input["published"], as: Bool.self)
            guard let record = cuts[handle]?[identifier] else {
                return try cutResponse(ModernCutOutcome(status: "unavailable", reason: "unknownCutPreparation", transaction: nil, result: nil, retainedClipboard: nil), session: session)
            }
            guard input["documentID"] == .string(session.documentID), input["epoch"] == .string(session.epoch) else {
                return try cutResponse(ModernCutOutcome(status: "unavailable", reason: "cutSessionChanged", transaction: nil, result: nil,
                    retainedClipboard: record.preparation.clipboard), session: session)
            }
            return try cutResponse(session.finishCut(record.preparation, published: published), session: session)
        case "modernCancelCut", "modernForgetCut":
            try allowed(input, ["command", "session", "preparationID"])
            guard let identifier = input["preparationID"]?.string else { throw EditorError.invalidChange }
            if command == "modernForgetCut" { cuts[handle]?.removeValue(forKey: identifier) }
            else if let record = cuts[handle]?[identifier] { try session.cancelCut(record.preparation) }
        case "modernMarkState":
            try allowed(input, ["command", "session", "range", "ranges", "type"])
            guard let type = input["type"]?.string else { throw EditorError.invalidChange }
            guard (input["range"] != nil) != (input["ranges"] != nil) else { throw EditorError.invalidChange }
            return try encode(session.markState(in: input["ranges"].map { try decode($0, as: [ModernTextRange].self) } ?? [decode(input["range"], as: ModernTextRange.self)], type: type))
        case "modernSemanticState":
            try allowed(input, ["command", "session", "target", "kind"])
            return try encode(session.semanticState(decode(input["target"], as: ModernSemanticTarget.self), kind: decode(input["kind"], as: ModernSemanticKind.self)))
        case "modernBeginAsyncBlock":
            try allowed(input, ["command", "session", "node", "requestID"])
            guard let requestID = input["requestID"]?.string else { throw EditorError.invalidChange }
            return try encode(session.beginAsyncBlock(decode(input["node"], as: NodeID.self), requestID: requestID))
        case "modernAsyncRequests":
            try allowed(input, ["command", "session"]); return try encode(session.asyncRequests)
        case "modernExportAsyncRequests":
            try allowed(input, ["command", "session"]); return try JSONDecoder().decode(JSONValue.self, from: session.exportAsyncRequests())
        case "modernRestoreAsyncRequests":
            try allowed(input, ["command", "session", "archive"]); try session.restoreAsyncRequests(canonicalEncoder().encode(input["archive"] ?? .null))
        case "modernCancelAsyncBlock", "modernForgetAsyncBlock":
            try allowed(input, ["command", "session", "target"])
            let target = try decode(input["target"], as: ModernAsyncTarget.self)
            if command == "modernCancelAsyncBlock" { try session.cancelAsyncBlock(target) } else { try session.forgetAsyncBlock(target) }
        case "modernFailAsyncBlock":
            try allowed(input, ["command", "session", "target", "reason"])
            guard let reason = input["reason"]?.string else { throw EditorError.invalidChange }
            try session.failAsyncBlock(decode(input["target"], as: ModernAsyncTarget.self), reason: reason)
        case "modernComposition":
            try allowed(input, ["command", "session", "active"]); session.isComposing = try decode(input["active"], as: Bool.self)
        case "modernSetAuthoringPolicy":
            try allowed(input, ["command", "session", "allowedCommands"])
            guard let policy = input["allowedCommands"] else { throw EditorError.invalidChange }
            session.allowedCommands = policy == .null ? nil : try authoringPolicy(policy)
            session.endTypingGroup()
        case "modernSetContentPolicy":
            try allowed(input, ["command", "session", "allowedBlockTypes", "allowedMarkTypes"])
            guard let blocks = input["allowedBlockTypes"], let marks = input["allowedMarkTypes"] else { throw EditorError.invalidChange }
            let blockTypes = try blocks == .null ? nil : contentPolicy(blocks, blocks: true)
            let markTypes = try marks == .null ? nil : contentPolicy(marks, blocks: false)
            session.allowedBlockTypes = blockTypes; session.allowedMarkTypes = markTypes
        case "modernSetListPolicy":
            try allowed(input, ["command", "session", "allowedListActions"])
            guard let policy = input["allowedListActions"] else { throw EditorError.invalidChange }
            session.allowedListActions = policy == .null ? nil : try listPolicy(policy)
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
    private func localSelectionCommand(_ input: JSONValue, session: ModernSession, command: String) throws -> JSONValue {
        switch command {
        case "modernCaptureLocalNodes":
            try allowed(input, ["command", "session", "nodes"])
            return try encode(session.captureLocalNodes(decode(input["nodes"], as: [NodeID].self)))
        case "modernSetLocalSelection":
            try allowed(input, ["command", "session", "selection"])
            guard let value = input["selection"] else { throw EditorError.invalidChange }
            try session.setLocalSelection(value == .null ? nil : decode(value, as: ModernLocalSelection.self))
        case "modernLocalSelection":
            try allowed(input, ["command", "session"]); return try session.resolvedLocalSelection().map(encode) ?? .null
        case "modernExportHistorySelection":
            try allowed(input, ["command", "session"]); return try JSONDecoder().decode(JSONValue.self, from: session.exportHistorySelection())
        case "modernRestoreHistorySelection":
            try allowed(input, ["command", "session", "archive"])
            try session.restoreHistorySelection(canonicalEncoder().encode(input["archive"] ?? .null))
        default: throw EditorError.invalidChange
        }
        return try snapshot(session)
    }
    private func execute(_ request: JSONValue, session: ModernSession) throws -> JSONValue {
        try allowed(request, ["documentID", "epoch", "command", "target", "arguments", "historySelection"])
        if let value = request["historySelection"] {
            guard let command = request["command"]?.string, command != "undo", command != "redo" else { throw EditorError.invalidChange }
            let before = try value == .null ? nil : decode(value, as: ModernLocalSelection.self)
            var inner = request.object!; inner.removeValue(forKey: "historySelection")
            return try session.withHistorySelection(before) { try self.executeCommand(.object(inner), session: session) }
        }
        return try executeCommand(request, session: session)
    }
    private func executeCommand(_ request: JSONValue, session: ModernSession) throws -> JSONValue {
        try allowed(request, ["documentID", "epoch", "command", "target", "arguments"])
        guard let command = request["command"]?.string, let arguments = request["arguments"], arguments.object != nil else { throw EditorError.invalidChange }
        if command != "completeAsyncBlock" && command != "paste" {
            guard request["documentID"] == .string(session.documentID) else { throw EditorError.differentDocument }
            guard request["epoch"] == .string(session.epoch) else { throw ModernSessionError.incompatibleEpoch }
        }
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

        if command == "paste" {
            try allowed(arguments, ["clipboard", "mode", "newIDs", "policy"])
            let target = try decode(request["target"], as: ModernPasteTarget.self)
            guard let payload = arguments["clipboard"] else { throw EditorError.invalidChange }
            if payload == .null { return try result("noop", reason: "clipboardNoResult") }
            let clipboard = try ModernClipboard(json: canonicalEncoder().encode(payload))
            let mode = try arguments["mode"].map { try decode($0, as: ModernPasteMode.self) } ?? .rich
            let ids = try arguments["newIDs"].map { try decode($0, as: [String].self) }
            let policy = try arguments["policy"].map { try decode($0, as: WritingPastePolicy.self) } ?? WritingPastePolicy()
            func retained(_ status: String, _ reason: String) throws -> JSONValue {
                var response = try result(status, reason: reason).object!
                response["retainedClipboard"] = try encode(clipboard); return .object(response)
            }
            guard request["documentID"] == .string(session.documentID), request["epoch"] == .string(session.epoch) else { return try retained("unavailable", "clipboardScopeChanged") }
            let before = Set(session.syncState.received)
            do {
                let outcome = try session.paste(clipboard, at: target, mode: mode, newIDs: ids, policy: policy)
                let transaction = session.syncState.received.first { !before.contains($0) && $0.actor == session.actorID }
                let caret: WritingPosition? = { if case .text(let position) = outcome.focus { return position }; return nil }()
                let selection = try outcome.selection.map { selection -> JSONValue in
                    switch selection { case .text(let range): return try encode(range); case .nodes(let nodes): return try encode(nodes); case .mixed(let mixed): return try encode(mixed) }
                }
                var response = try result(transaction == nil ? "noop" : "applied", transaction: transaction, position: caret, selection: selection,
                    focusIntent: outcome.focus, selectionIntent: outcome.selection).object!
                response["retainedClipboard"] = .null; return .object(response)
            } catch ModernSessionError.unavailable(let reason) { return try retained("unavailable", reason) }
            catch ModernSessionError.compositionActive { return try retained("unavailable", "compositionActive") }
            catch ModernSessionError.recoveryRequired { return try retained("recoveryRequired", "pendingRecovery") }
            catch is EditorError { return try retained("unavailable", "invalidPasteTargetOrAdmission") }
            catch ModernSessionError.incompatibleEpoch { return try retained("unavailable", "clipboardScopeChanged") }
        }
        if command == "completeAsyncBlock" {
            try allowed(arguments, ["metadata"])
            let target = try decode(request["target"], as: ModernAsyncTarget.self)
            guard let metadata = arguments["metadata"]?.object else { throw EditorError.invalidChange }
            try validateModernAsyncMetadata(metadata, kind: target.origin.kind)
            let before = Set(session.syncState.received)
            let outcome: ModernAsyncOutcome
            if request["documentID"] != .string(target.documentID) || request["epoch"] != .string(target.epoch) {
                outcome = ModernAsyncOutcome(status: "unavailable", reason: "asyncRequestScopeChanged", retainedResult: metadata)
            } else { outcome = try session.completeAsyncBlock(target, metadata: metadata) }
            let transaction = session.syncState.received.first { !before.contains($0) && $0.actor == session.actorID }
            var response = try result(outcome.status, transaction: transaction, reason: outcome.reason).object!
            response["retainedResult"] = outcome.retainedResult.map(JSONValue.object) ?? .null
            return .object(response)
        }
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
            else if case .mixed(let mixed) = outcome.selection { selection = try encode(mixed) }
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
            case "setSemanticColor":
                try allowed(arguments, ["kind", "role"])
                guard let role = arguments["role"], role == .null || role.string != nil else { throw EditorError.invalidChange }
                try structural(session.setSemanticColor(decode(request["target"], as: ModernSemanticTarget.self),
                    kind: decode(arguments["kind"], as: ModernSemanticKind.self), role: role.string))
            case "setLink":
                try allowed(arguments, ["href", "label"])
                guard let href = arguments["href"], href == .null || href.string != nil else { throw EditorError.invalidChange }
                if let label = arguments["label"], label.string == nil { throw EditorError.invalidChange }
                try structural(session.setLink(in: decode(request["target"], as: ModernTextRange.self), href: href.string, label: arguments["label"]?.string))
            case "codeProperties":
                try allowed(arguments, ["language"])
                guard let language = arguments["language"], language == .null || language.string != nil else { throw EditorError.invalidChange }
                try structural(session.codeProperties(decode(request["target"], as: ModernCodeTarget.self), language: language.string))
            case "format":
                try allowed(arguments, ["markType", "mark"])
                guard let type = arguments["markType"]?.string else { throw EditorError.invalidChange }
                if request["target"]?["ranges"] != nil {
                    guard case .object(let fields) = request["target"] else { throw EditorError.invalidChange }
                    try allowed(.object(fields), ["ranges"])
                    let target = try decode(request["target"], as: ModernTextSpanTarget.self)
                    try structural(session.format(in: target.ranges, markType: type, mark: arguments["mark"] == .null ? nil : arguments["mark"]))
                } else {
                    let target = try decode(request["target"], as: ModernTextRange.self)
                    try structural(session.format(in: target, markType: type, mark: arguments["mark"] == .null ? nil : arguments["mark"]))
                }
            case "insertBlock":
                try allowed(arguments, ["block"])
                let boundary = try decode(request["target"], as: ModernBlockBoundary.self)
                let block = try decode(arguments["block"], as: Block.self)
                try structural(session.insertBlock(block, at: boundary))
            case "duplicate":
                try allowed(arguments, ["newBlockIDs"])
                let ids = try decode(arguments["newBlockIDs"], as: [String].self)
                try structural(session.duplicate(decode(request["target"], as: ModernDuplicateTarget.self), newBlockIDs: ids))
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
                if request["target"]?["nodes"] != nil {
                    try structural(session.convertBlocks(decode(request["target"], as: ModernNodeSelection.self), to: decode(arguments, as: WritingBlockTarget.self)))
                } else { try structural(session.convertBlock(in: decode(request["target"], as: ModernTextRange.self), to: decode(arguments, as: WritingBlockTarget.self))) }
            case "typingShortcut":
                try allowed(arguments, [])
                try structural(session.typingShortcut(in: decode(request["target"], as: ModernTextRange.self)))
            case "softBreak":
                try allowed(arguments, [])
                position = try session.softBreak(in: decode(request["target"], as: ModernTextRange.self))
            case "splitBlock":
                try allowed(arguments, ["newBlockID"])
                guard let label = arguments["newBlockID"]?.string else { throw EditorError.invalidChange }
                try structural(session.splitBlock(in: decode(request["target"], as: ModernTextRange.self), newBlockID: label))
            case "tableStructure":
                try allowed(arguments, ["action", "newIDs", "header"])
                let action = try decode(arguments["action"], as: ModernTableAction.self)
                let ids = try arguments["newIDs"].map { try decode($0, as: [String].self) } ?? []
                let header = try arguments["header"].map { try decode($0, as: Bool.self) }
                try structural(session.tableStructure(decode(request["target"], as: ModernTableTarget.self), action: action, newIDs: ids, header: header))
            case "mediaProperties":
                try allowed(arguments, ["metadata"])
                guard let metadata = arguments["metadata"]?.object else { throw EditorError.invalidChange }
                try structural(session.mediaProperties(decode(request["target"], as: ModernMediaTarget.self), metadata: metadata))
            case "listStructure":
                try allowed(arguments, ["action", "style", "checked"])
                let action = try decode(arguments["action"], as: ModernListAction.self)
                if let style = arguments["style"], style.string == nil { throw EditorError.invalidChange }
                if let checked = arguments["checked"], checked != .bool(true), checked != .bool(false) { throw EditorError.invalidChange }
                try structural(session.listStructure(decode(request["target"], as: ModernListTarget.self), action: action,
                    style: arguments["style"]?.string, checked: arguments["checked"].flatMap { if case .bool(let value) = $0 { return value }; return nil }))
            case "mergeBlocks":
                try allowed(arguments, [])
                try structural(session.mergeBlocks(decode(request["target"], as: ModernNodeSelection.self)))
            case "undo", "redo":
                try allowed(arguments, [])
                guard request["target"] == nil || request["target"] == .null else { throw EditorError.invalidChange }
                if command == "undo" { try session.undo() } else { try session.redo() }
                if Set(session.syncState.received) != before, let restored = session.localSelection {
                    focusIntent = restored.focus; selectionIntent = restored.selection
                    if case .text(let caret) = restored.focus { position = caret }
                    if let intent = restored.selection {
                        switch intent { case .text(let range): selection = try encode(range); case .nodes(let nodes): selection = try encode(nodes); case .mixed(let mixed): selection = try encode(mixed) }
                    }
                }
            default: throw EditorError.invalidChange
            }
        } catch ModernSessionError.unavailable(let reason) { return try result("unavailable", reason: reason) }
        catch ModernSessionError.recoveryRequired { return try result("recoveryRequired", reason: "schemaOrIdentityConflict") }
        catch let error as EditorError {
            if command == "convertBlock", case .invalidDocument = error { return try result("unavailable", reason: "conversionMetadataConflict") }
            if ["tableStructure", "mediaProperties", "duplicate", "createColumns", "removeColumns", "resizeColumns", "convertBlock", "softBreak", "splitBlock", "mergeBlocks", "listStructure", "setSemanticColor", "setLink"].contains(command), error == .invalidChange || error == .invalidPath {
                return try result("unavailable", reason: ["tableStructure", "mediaProperties", "duplicate", "convertBlock", "softBreak", "splitBlock", "mergeBlocks", "listStructure", "setSemanticColor", "setLink"].contains(command) ? "invalidWritingTargetOrArguments" : "invalidColumnTargetOrArguments")
            }
            throw error
        }
        let transaction = session.syncState.received.first { !before.contains($0) && $0.actor == session.actorID }
        return try result(transaction == nil ? "noop" : "applied", transaction: transaction, position: position, selection: selection, focusIntent: focusIntent, selectionIntent: selectionIntent)
    }
    private func listPolicy(_ value: JSONValue) throws -> Set<ModernListAction> {
        guard let values = value.array, values.count <= 5 else { throw EditorError.invalidChange }
        var actions = Set<ModernListAction>()
        for value in values {
            guard let name = value.string, let action = ModernListAction(rawValue: name), actions.insert(action).inserted else { throw EditorError.invalidChange }
        }
        return actions
    }
    private func cutResponse(_ outcome: ModernCutOutcome, session: ModernSession) throws -> JSONValue {
        var response = try snapshot(session).object!
        response["status"] = .string(outcome.status); response["reason"] = outcome.reason.map(JSONValue.string) ?? .null
        response["transaction"] = try outcome.transaction.map(encode) ?? .null
        response["retainedClipboard"] = try outcome.retainedClipboard.map(encode) ?? .null
        response["focusIntent"] = try outcome.result.map { try encode($0.focus) } ?? .null
        response["selectionIntent"] = try outcome.result?.selection.map(encode) ?? .null
        response["focus"] = try outcome.result.flatMap { if case .text(let caret) = $0.focus { return caret }; return nil }.map(encode) ?? .null
        response["selection"] = try outcome.result?.selection.map {
            switch $0 { case .text(let range): return try encode(range); case .nodes(let nodes): return try encode(nodes); case .mixed(let mixed): return try encode(mixed) }
        } ?? .null
        return .object(response)
    }
    private func contentPolicy(_ value: JSONValue, blocks: Bool) throws -> Set<String> {
        let values = try decode(value, as: [String].self)
        let supported: Set<String> = blocks ? ["paragraph", "heading", "quote", "callout", "list", "toggle", "code", "table", "divider", "columns", "image", "file", "embed", "math"] : ["bold", "italic", "strikethrough", "code", "link", "semantic-color", "semantic-background"]
        guard values.count == Set(values).count, Set(values).isSubset(of: supported) else { throw EditorError.invalidChange }
        return Set(values)
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
