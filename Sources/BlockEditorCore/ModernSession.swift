import Foundation

/// Protocol-7 operations. Structural/compound layout commands are added only
/// once their admission and retained-origin replay semantics are implemented.
public enum ModernOperation: Codable, Equatable, Sendable {
    case createColumns(ModernColumnCreation)
    case removeColumns(layout: NodeID, source: NodePlacementID)
    case resizeColumns(layout: NodeID, splitBasisPoints: Int)
    case convertBlock(node: NodeID, type: String, attributes: [String: JSONValue])
    case schemaConvert(WritingSchemaConversion)
    case splitBlock(ModernBlockSplit)
    case mergeBlocks(ModernBlockJoin)
    case structure(Mutation)
    case text(WritingMutation)
    case setAppearance(field: String, value: String)
}
public enum ModernChangeBody: Codable, Equatable, Sendable {
    case edit([ModernOperation])
    case setActive(targets: [ChangeID], active: Bool)
}
public struct ModernChange: Codable, Equatable, Sendable {
    public let id: ChangeID
    public let observed: [ChangeID]
    public let body: ModernChangeBody
    public init(id: ChangeID, observed: [ChangeID], body: ModernChangeBody) {
        self.id = id; self.observed = observed; self.body = body
    }
}

/// A captured range names the causal state in which its atoms were selected.
/// Peer insertions after capture are not selected merely by lying between the
/// same endpoints. Direction is retained by the two anchored positions.
public struct ModernTextRange: Codable, Equatable, Sendable {
    public let start: WritingPosition
    public let end: WritingPosition
    public let observed: [ChangeID]
    public init(start: WritingPosition, end: WritingPosition, observed: [ChangeID]) {
        self.start = start; self.end = end; self.observed = observed
    }
}

/// Raw JSON goes through duplicate-key/numeric inspection before typed decoding.
/// The baseline keeps its explicit ModernDocument admission boundary.
public struct ModernBatch: Encodable, Equatable, Sendable {
    public let version: Int
    public let documentID: String
    public let epoch: String
    public let baseline: ModernDocument
    public let changes: [ModernChange]
    public init(documentID: String, epoch: String, baseline: ModernDocument, changes: [ModernChange], version: Int = 7) {
        self.version = version; self.documentID = documentID; self.epoch = epoch; self.baseline = baseline; self.changes = changes
    }
    public init(json: Data) throws { self = try decodeModernBatch(modernWireValue(json)) }
    public func json() throws -> Data { try canonicalEncoder().encode(self) }
}
public struct ModernRecovery: Encodable, Equatable, Sendable {
    public let reason: MergeRecoveryReason
    public let batch: ModernBatch
}
public enum ModernSessionError: Error, Equatable, Sendable {
    case incompatibleEpoch, compositionActive, unavailable(String), recoveryRequired(ModernRecovery)
}

/// Explicit protocol-7 session over the existing structural/scalar projections.
/// Confine it to one executor. Native composition drafts and transport ownership
/// stay with the host; held packets and recovery are separately exportable.
public final class ModernSession {
    public let documentID: String
    public let actorID: String
    public let epoch: String
    public let baseline: ModernDocument
    public let protocolVersion = 7
    public private(set) var document: ModernDocument
    public private(set) var mergeRecovery: ModernRecovery?
    /// Local host policy restricts authoring only; peer admission/preservation is unchanged.
    public var allowedCommands: Set<String>? { didSet { endTypingGroup() } }
    public var onWillReceive: (() -> Void)?
    public var onChange: ((ModernDocument, ModernChange?) -> Void)?
    public var isComposing = false { didSet { if oldValue != isComposing { endTypingGroup() } } }
    private let seed: ModernProjectionSeed
    var structure: StructuralState
    private var projection: WritingProjection
    private var log: [ChangeID: ModernChange] = [:]
    private var counter: UInt64 = 0
    private var undoStack: [[ChangeID]] = [], redoStack: [[ChangeID]] = []
    private var typingGroup: String?
    private var publishing = false
    private var remoteHolds = 0
    private var deferred: [ModernBatch] = []
    private var deferredBytes = 0, drainingCount = 0, drainingBytes = 0
    private var draining = false

    public init(documentID: String, actorID: String, epoch: String, document: ModernDocument) throws {
        guard documentID == document.documentID else { throw EditorError.differentDocument }
        guard validToken(actorID), validToken(epoch) else { throw EditorError.invalidChange }
        self.documentID = documentID; self.actorID = actorID; self.epoch = epoch; baseline = document
        seed = ModernProjectionSeed(document)
        structure = seed.structure
        projection = try WritingProjection(seeds: seed.atoms, edits: [], emptyFields: seed.fields)
        self.document = document
    }
    public var titleField: WritingField { seed.title }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var syncState: WritingSyncState {
        WritingSyncState(documentID: documentID, epoch: epoch, received: log.keys.sorted(), version: 7)
    }
    public func endTypingGroup() { typingGroup = nil }
    public func node(at address: NodeAddress) throws -> NodeID { try structure.node(at: address) }
    public func field(node: NodeID, name: String = "content") throws -> WritingField {
        let field = WritingField(node: node, name: name); try validateField(field); return try projection.destination(of: field)
    }
    public func text(in field: WritingField) throws -> String { try validateField(field); return try projection.text(in: projection.destination(of: field)) }
    public func changes(since receipt: WritingSyncState? = nil) throws -> ModernBatch {
        if let receipt {
            guard receipt.version == 7 else { throw EditorError.unsupportedVersion(receipt.version) }
            guard receipt.documentID == documentID else { throw EditorError.differentDocument }
            guard receipt.epoch == epoch else { throw ModernSessionError.incompatibleEpoch }
            guard receipt.received.count <= 100_000, Set(receipt.received).count == receipt.received.count,
                  receipt.received.allSatisfy(validModernChangeID) else { throw EditorError.invalidChange }
        }
        let received = Set(receipt?.received ?? [])
        return batch(log.values.filter { !received.contains($0.id) })
    }

    /// Host supplies one token for adjacent ordinary input and calls
    /// endTypingGroup at focus/selection/paste/composition/command boundaries.
    /// The token is local history state, never replicated content.
    @discardableResult public func replaceText(in field: WritingField, range: Range<Int>, with text: String,
                                               typingGroup group: String? = nil) throws -> WritingPosition {
        try authoringAllowed(command: field == titleField ? "replaceTitle" : "replaceText")
        if let group, !validToken(group) { throw EditorError.invalidChange }
        guard text.utf16.count <= 100_000 else { throw EditorError.invalidRange }
        let field = try projection.destination(of: field)
        try validatePlainText(text, field: field)
        return try replaceSelected(field: field, selected: selection(field, range), text: text, group: group)
    }
    func replaceSelected(field: WritingField, selected: (keys: [WritingAtomKey], edge: WritingEdge, marks: [JSONValue], position: WritingPosition), text: String, group: String?) throws -> WritingPosition {
        if selected.keys.isEmpty && text.isEmpty { return selected.position }
        let id = try nextID()
        var operations: [ModernOperation] = selected.keys.isEmpty ? [] : [.text(.delete(keys: selected.keys))]
        var edge = selected.edge, last: WritingAtomKey?
        for (index, scalar) in text.unicodeScalars.enumerated() {
            let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index))
            let marks = plainField(field) ? [] : selected.marks
            let atom = WritingAtomSeed(key: key, node: textNode(String(scalar), marks: marks), edge: edge,
                route: edge.anchor.map(WritingRoute.follow) ?? .field(field))
            operations.append(.text(.insert(atom))); edge = .after(key); last = key
        }
        try perform(id, operations, group: group)
        return last.map { WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: $0, affinity: .after) } ?? selected.position
    }
    @discardableResult public func replaceTitle(range: Range<Int>, with text: String) throws -> WritingPosition {
        endTypingGroup(); return try replaceText(in: titleField, range: range, with: text)
    }
    public func setAppearance(field: String, value: String) throws {
        try authoringAllowed(command: "setAppearance"); try validateAppearance(field: field, value: value); endTypingGroup()
        if document.fields["appearance"]?[field] == .string(value) { return }
        try perform(nextID(), [.setAppearance(field: field, value: value)])
    }
    public func format(in field: WritingField, range: Range<Int>, markType: String, mark: JSONValue?) throws {
        try authoringAllowed(command: "format"); try validateField(field)
        let field = try projection.destination(of: field)
        guard !plainField(field) else { throw EditorError.invalidChange }
        try validateModernMark(type: markType, mark: mark); endTypingGroup()
        let selected = try selection(field, range)
        if !selected.keys.isEmpty { try perform(nextID(), [.text(.format(keys: selected.keys, type: markType, mark: mark))]) }
    }
    public func undo() throws { try toggle(active: false) }
    public func redo() throws { try toggle(active: true) }

    public func position(in field: WritingField, offset: Int, affinity: TextAffinity = .before) throws -> WritingPosition {
        try validateField(field)
        let field = try projection.destination(of: field)
        guard modernScalarBoundary(offset, in: projection.text(in: field)) else { throw EditorError.invalidRange }
        var cursor = 0
        for key in projection.visibleKeys(in: field) {
            let value = try projection.value(of: key), length = plainText([value]).utf16.count
            if offset == cursor && affinity == .before { return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: affinity) }
            if offset > cursor && offset < cursor + length {
                guard value["type"] != .string("text") else { throw EditorError.invalidRange }
                return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: affinity, intraAtomOffset: offset - cursor)
            }
            cursor += length
            if offset == cursor && affinity == .after { return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: affinity) }
        }
        guard offset == 0 || offset == cursor else { throw EditorError.invalidRange }
        // A captured nonempty field end follows the observed last atom, so a
        // later peer suffix does not move an existing caret past that suffix.
        if offset > 0, let last = projection.visibleKeys(in: field).last {
            return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: last, affinity: .after)
        }
        return WritingPosition(documentID: documentID, epoch: epoch, field: field, affinity: offset == 0 ? .after : .before)
    }
    public func resolve(_ position: WritingPosition) throws -> ResolvedWritingPosition { try modernResolve(position, in: modernCurrentReplay) }
    func modernResolve(_ position: WritingPosition, in replay: (WritingProjection, ModernDocument, StructuralState), observed: [ChangeID]? = nil) throws -> ResolvedWritingPosition {
        guard position.documentID == documentID else { throw EditorError.differentDocument }
        guard position.epoch == epoch else { throw ModernSessionError.incompatibleEpoch }
        let projection = replay.0, shape = replay.2
        guard projection.hasField(position.field) else { throw EditorError.invalidPath }
        let history: [ChangeID: ModernChange]
        if let observed {
            let cohort = try closure(observed, before: ChangeID(counter: UInt64.max, actor: actorID), in: log)
            history = log.filter { cohort.contains($0.key) }
        } else { history = log }
        if let anchor = position.anchor {
            guard anchor.element.index >= 0, projection.retainedKeys.contains(anchor),
                  modernRelatedFields(anchor.origin, position.field, changes: Array(history.values)) else { throw EditorError.invalidChange }
        }
        let active = activeStates(history)
        return try resolveWritingPosition(position, projection: projection, structure: shape) { field in
            guard case .inserted(let creation, let path) = field.node, path.isEmpty, active[creation.change] == false,
                  case .edit(let operations)? = history[creation.change]?.body else { return nil }
            let boundaries = operations.compactMap { operation -> (WritingField, WritingEdge)? in
                if case .splitBlock(let split) = operation, split.destination == field { return (split.source, split.edge) }; return nil
            }
            return boundaries.count == 1 ? boundaries[0] : nil
        }
    }
    public func captureTextRange(in field: WritingField, start: Int, end: Int) throws -> ModernTextRange {
        ModernTextRange(start: try position(in: field, offset: start), end: try position(in: field, offset: end), observed: frontier(log))
    }
    @discardableResult public func replaceText(in range: ModernTextRange, with text: String, typingGroup group: String? = nil) throws -> WritingPosition {
        try authoringAllowed(command: range.start.field == titleField ? "replaceTitle" : "replaceText")
        if let group, !validToken(group) { throw EditorError.invalidChange }
        guard text.utf16.count <= 100_000, range.start.field == range.end.field else { throw EditorError.invalidRange }
        let selected = try capturedSelection(range)
        let field = try selected.position.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: selected.position.field)
        try validatePlainText(text, field: field)
        return try replaceSelected(field: field, selected: selected, text: text, group: group)
    }
    public func format(in range: ModernTextRange, markType: String, mark: JSONValue?) throws {
        try authoringAllowed(command: "format"); try validateModernMark(type: markType, mark: mark)
        guard range.start.field == range.end.field else { throw EditorError.invalidChange }
        let selected = try capturedSelection(range)
        let field = try selected.position.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: selected.position.field)
        guard !plainField(field) else { throw EditorError.invalidChange }
        endTypingGroup()
        if !selected.keys.isEmpty { try perform(nextID(), [.text(.format(keys: selected.keys, type: markType, mark: mark))]) }
    }
    func modernCapturedCaret(_ range: ModernTextRange) throws -> WritingPosition {
        guard range.start.field == range.end.field else { throw EditorError.invalidRange }
        let captured = try modernCapturedReplay(range.observed)
        let start = try modernResolve(range.start, in: captured, observed: range.observed), end = try modernResolve(range.end, in: captured, observed: range.observed)
        guard start.address == end.address, start.offset == end.offset else { throw EditorError.invalidRange }
        _ = try resolve(range.start)
        let field = try range.start.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: range.start.field)
        return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: range.start.anchor,
            affinity: range.start.affinity, intraAtomOffset: range.start.intraAtomOffset)
    }
    private func capturedSelection(_ range: ModernTextRange) throws -> (keys: [WritingAtomKey], edge: WritingEdge, marks: [JSONValue], position: WritingPosition) {
        guard range.start.field == range.end.field else { throw EditorError.invalidRange }
        let captured = try modernCapturedReplay(range.observed)
        let start = try modernResolve(range.start, in: captured, observed: range.observed), end = try modernResolve(range.end, in: captured, observed: range.observed)
        guard start.address == end.address else { throw EditorError.invalidRange }
        _ = try resolve(range.start); _ = try resolve(range.end)
        let field = try range.start.anchor.map { try captured.0.field(of: $0) } ?? captured.0.destination(of: range.start.field)
        return try selection(field, min(start.offset, end.offset)..<max(start.offset, end.offset), in: captured.0)
    }

    public func receive(_ incoming: ModernBatch) throws {
        guard !publishing else { throw EditorError.invalidChange }
        try validateScope(incoming)
        if remoteHolds > 0 {
            let bytes = try incoming.json().count
            guard deferred.count + drainingCount < 64, bytes <= 64_000_000 - deferredBytes - drainingBytes - deferred.count - drainingCount - 3 else { throw EditorError.recoveryCapacityExceeded }
            deferred.append(incoming); deferredBytes += bytes; return
        }
        var candidate = try candidateIncludingRecovery()
        for change in incoming.changes {
            if let prior = candidate[change.id], prior != change { throw EditorError.conflictingChange }
            candidate[change.id] = change
        }
        if candidate == log { return }
        try capacity(candidate)
        let result = try replayOrRetain(candidate)
        publishing = true; onWillReceive?(); publishing = false
        accept(candidate, result, change: nil)
    }
    public func holdRemoteChanges() throws -> () throws -> Void {
        guard !publishing, remoteHolds < 64 else { throw EditorError.invalidChange }
        remoteHolds += 1
        var released = false
        return { [weak self] in
            guard !released, let self else { return }
            released = true; self.remoteHolds -= 1
            if self.remoteHolds == 0 { try self.retryDeferredChanges() }
        }
    }
    public func exportDeferredChanges() throws -> Data { try canonicalEncoder().encode(deferred) }
    public func restoreDeferredChanges(_ data: Data) throws {
        guard let packets = try modernWireValue(data).array, packets.count <= 64 else { throw EditorError.invalidChange }
        // Parse every packet before the first admission so a malformed envelope
        // cannot partially restore an otherwise valid export.
        let decoded = try packets.map(decodeModernBatch)
        for packet in decoded { try validateScope(packet) }
        for packet in decoded { try receive(packet) }
    }
    public func retryDeferredChanges() throws {
        guard remoteHolds == 0, !publishing, !draining else { throw EditorError.invalidChange }
        let pending = deferred
        draining = true; drainingCount = pending.count; drainingBytes = deferredBytes
        deferred = []; deferredBytes = 0
        defer { draining = false; drainingCount = 0; drainingBytes = 0 }
        var failed: [ModernBatch] = [], failure: Error?
        for packet in pending {
            var keep = false
            do { try receive(packet) } catch {
                if case ModernSessionError.recoveryRequired = error { }
                else { failed.append(packet); keep = true }
                if failure == nil { failure = error }
            }
            if !keep { drainingCount -= 1; drainingBytes -= try packet.json().count }
        }
        deferred.insert(contentsOf: failed, at: 0)
        deferredBytes += try failed.reduce(0) { try $0 + $1.json().count }
        if let failure, mergeRecovery != nil || !failed.isEmpty { throw failure }
    }
    public func exportRecovery() throws -> Data? { try mergeRecovery.map { try canonicalEncoder().encode($0) } }
    public func restoreRecovery(_ data: Data) throws {
        let value = try modernWireValue(data)
        guard Set(value.object?.keys ?? Dictionary<String, JSONValue>().keys) == ["reason", "batch"] else { throw EditorError.invalidChange }
        _ = try JSONDecoder().decode(MergeRecoveryReason.self, from: canonicalEncoder().encode(value["reason"] ?? .null))
        try receive(decodeModernBatch(value["batch"] ?? .null))
    }
    public func repairUndo(_ targets: [ChangeID]) throws { try repairHistory(targets, active: false) }
    public func repairRedo(_ targets: [ChangeID]) throws { try repairHistory(targets, active: true) }
    private func repairHistory(_ targets: [ChangeID], active: Bool) throws {
        guard !publishing, !isComposing, mergeRecovery != nil else { throw EditorError.invalidChange }
        let known = Set((undoStack + redoStack).flatMap { $0 })
        guard !targets.isEmpty, targets.allSatisfy({ known.contains($0) }) else { throw EditorError.invalidChange }
        var candidate = try candidateIncludingRecovery()
        let id = try nextID(in: candidate)
        let change = ModernChange(id: id, observed: frontier(candidate), body: .setActive(targets: targets, active: active))
        candidate[id] = change; try capacity(candidate)
        let result = try replayOrRetain(candidate)
        accept(candidate, result, change: change)
    }

    public func save() throws -> Data {
        var fields = try jsonValue(batch(Array(log.values))).object!
        fields["localHistory"] = .object(["actorID": .string(actorID), "undo": try jsonValue(undoStack), "redo": try jsonValue(redoStack)])
        let data = try canonicalEncoder().encode(fields)
        guard data.count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
        return data
    }
    public static func restore(_ data: Data, actorID: String) throws -> ModernSession {
        var fields = try modernWireValue(data).object ?? [:]
        let history = fields.removeValue(forKey: "localHistory")
        let batch = try decodeModernBatch(.object(fields))
        guard batch.version == 7 else { throw EditorError.unsupportedVersion(batch.version) }
        let session = try ModernSession(documentID: batch.documentID, actorID: actorID, epoch: batch.epoch, document: batch.baseline)
        try session.receive(batch)
        if let history {
            guard let fields = history.object, Set(fields.keys) == ["actorID", "undo", "redo"],
                  let owner = fields["actorID"]?.string, validToken(owner) else { throw EditorError.invalidChange }
            let undo = try JSONDecoder().decode([[ChangeID]].self, from: canonicalEncoder().encode(fields["undo"]!))
            let redo = try JSONDecoder().decode([[ChangeID]].self, from: canonicalEncoder().encode(fields["redo"]!))
            let all = (undo + redo).flatMap { $0 }, active = session.activeStates(session.log)
            guard all.count <= 100_000, Set(all).count == all.count, (undo + redo).allSatisfy({ !$0.isEmpty }), all.allSatisfy({ id in
                guard id.actor == owner, let change = session.log[id] else { return false }
                if case .edit = change.body { return true }; return false
            }), undo.flatMap({ $0 }).allSatisfy({ active[$0] ?? true }), redo.flatMap({ $0 }).allSatisfy({ !(active[$0] ?? true) }) else { throw EditorError.invalidChange }
            // Reject ignored keys in nested IDs instead of accepting lossy history.
            guard try jsonValue(undo) == fields["undo"], try jsonValue(redo) == fields["redo"] else { throw EditorError.invalidChange }
            if owner == actorID { session.undoStack = undo; session.redoStack = redo }
        }
        return session
    }

    private func validateScope(_ packet: ModernBatch) throws {
        guard packet.version == 7 else { throw EditorError.unsupportedVersion(packet.version) }
        guard packet.documentID == documentID, packet.baseline.documentID == documentID, packet.baseline == baseline else { throw EditorError.differentDocument }
        guard packet.epoch == epoch else { throw ModernSessionError.incompatibleEpoch }
        guard packet.changes.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
        try validateResources(packet.changes)
        guard try packet.json().count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
    }
    private func validateField(_ field: WritingField) throws {
        guard projection.hasField(field) else { throw EditorError.invalidPath }
        if field != titleField { _ = try structure.address(of: projection.destination(of: field).node) }
    }
    private func plainField(_ field: WritingField) -> Bool { field == titleField || ["code", "expression"].contains(field.name) }
    private func validatePlainText(_ text: String, field: WritingField) throws {
        try validateField(field)
        if field == titleField && text.unicodeScalars.contains(where: { [10, 13, 0x2028, 0x2029].contains($0.value) }) { throw EditorError.invalidChange }
    }
    func authoringAllowed(command: String? = nil) throws {
        guard !publishing else { throw EditorError.invalidChange }
        guard !isComposing else { throw ModernSessionError.compositionActive }
        if let command, allowedCommands?.contains(command) == false { throw ModernSessionError.unavailable("hostPolicy") }
        if let recovery = mergeRecovery { throw ModernSessionError.recoveryRequired(recovery) }
    }
    func nextID(in candidate: [ChangeID: ModernChange]? = nil) throws -> ChangeID {
        let value = candidate?.keys.map(\.counter).max() ?? counter
        guard value < 9_007_199_254_740_991 else { throw EditorError.invalidChange }
        return ChangeID(counter: value + 1, actor: actorID)
    }
    private func batch(_ changes: [ModernChange]) -> ModernBatch {
        ModernBatch(documentID: documentID, epoch: epoch, baseline: baseline, changes: changes.sorted { $0.id < $1.id })
    }
    private func capacity(_ candidate: [ChangeID: ModernChange]) throws {
        guard candidate.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
        try validateResources(Array(candidate.values))
        let edits = candidate.values.filter { if case .edit = $0.body { return true }; return false }.map(\.id).sorted()
        guard try batch(Array(candidate.values)).json().count <= 64_000_000 - 1024 - canonicalEncoder().encode(edits).count - edits.count * 2 else { throw EditorError.recoveryCapacityExceeded }
    }
    private func candidateIncludingRecovery() throws -> [ChangeID: ModernChange] {
        var result = log
        for change in mergeRecovery?.batch.changes ?? [] {
            if let prior = result[change.id], prior != change { throw EditorError.conflictingChange }
            result[change.id] = change
        }
        return result
    }
    var modernObserved: [ChangeID] { frontier(log) }
    var modernCurrentReplay: (WritingProjection, ModernDocument, StructuralState) { (projection, document, structure) }
    func modernCapturedStructure(_ observed: [ChangeID]) throws -> StructuralState {
        try modernCapturedReplay(observed).2
    }
    func modernCapturedReplay(_ observed: [ChangeID]) throws -> (WritingProjection, ModernDocument, StructuralState) {
        let cohort = try closure(observed, before: ChangeID(counter: UInt64.max, actor: actorID), in: log)
        return try replay(log.filter { cohort.contains($0.key) })
    }
    func modernCapturedSelection(_ range: ModernTextRange) throws -> (keys: [WritingAtomKey], edge: WritingEdge, marks: [JSONValue], position: WritingPosition) {
        try capturedSelection(range)
    }
    func perform(_ id: ChangeID, _ operations: [ModernOperation], group: String? = nil) throws {
        try performReturning(id, operations, group: group) { _, _ in () }
    }
    func performReturning<Result>(_ id: ChangeID, _ operations: [ModernOperation], group: String? = nil,
        result makeResult: ((WritingProjection, ModernDocument, StructuralState), [ChangeID]) throws -> Result) throws -> Result {
        try authoringAllowed()
        let change = ModernChange(id: id, observed: frontier(log), body: .edit(operations))
        var candidate = log; candidate[id] = change; try capacity(candidate)
        let result = try replay(candidate), outcome = try makeResult(result, frontier(candidate))
        if let group, group == typingGroup, !undoStack.isEmpty { undoStack[undoStack.count - 1].append(id) }
        else { undoStack.append([id]) }
        typingGroup = group; redoStack = []
        accept(candidate, result, change: change)
        return outcome
    }
    private func toggle(active: Bool) throws {
        try authoringAllowed(command: active ? "redo" : "undo"); endTypingGroup()
        guard let targets = active ? redoStack.last : undoStack.last else { return }
        let change = ModernChange(id: try nextID(), observed: frontier(log), body: .setActive(targets: targets, active: active))
        var candidate = log; candidate[change.id] = change; try capacity(candidate)
        let result = try replayOrRetain(candidate)
        accept(candidate, result, change: change)
    }
    private func activeStates(_ candidate: [ChangeID: ModernChange]) -> [ChangeID: Bool] {
        var result: [ChangeID: Bool] = [:]
        for change in candidate.values.sorted(by: { $0.id < $1.id }) {
            if case .setActive(let targets, let active) = change.body { for target in targets { result[target] = active } }
        }
        return result
    }
    private func accept(_ candidate: [ChangeID: ModernChange], _ result: (WritingProjection, ModernDocument, StructuralState), change: ModernChange?) {
        let active = activeStates(candidate)
        var newUndo = undoStack.map { $0.filter { active[$0] ?? true } }.filter { !$0.isEmpty }
        var newRedo = redoStack.map { $0.filter { !(active[$0] ?? true) } }.filter { !$0.isEmpty }
        // Newly moved groups append after the existing destination stack, so
        // successive Undo/Redo preserve LIFO order across save and peer replay.
        for group in undoStack {
            let disabled = group.filter { !(active[$0] ?? true) }
            if !disabled.isEmpty { newRedo.append(disabled) }
        }
        for group in redoStack {
            let enabled = group.filter { active[$0] ?? true }
            if !enabled.isEmpty { newUndo.append(enabled) }
        }
        undoStack = newUndo; redoStack = newRedo
        log = candidate; counter = candidate.keys.map(\.counter).max() ?? 0
        projection = result.0; document = result.1; structure = result.2; mergeRecovery = nil
        publishing = true; onChange?(document, change); publishing = false
    }
    private func replayOrRetain(_ candidate: [ChangeID: ModernChange]) throws -> (WritingProjection, ModernDocument, StructuralState) {
        do { return try replay(candidate) }
        catch let error as WritingProjectionError {
            let recovery = ModernRecovery(reason: error == .missingAtom ? .schemaConstraint : .identityConflict, batch: batch(Array(candidate.values)))
            mergeRecovery = recovery; throw ModernSessionError.recoveryRequired(recovery)
        } catch EditorError.structuralConflict {
            let recovery = ModernRecovery(reason: .identityConflict, batch: batch(Array(candidate.values)))
            mergeRecovery = recovery; throw ModernSessionError.recoveryRequired(recovery)
        } catch EditorError.invalidDocument {
            let recovery = ModernRecovery(reason: .schemaConstraint, batch: batch(Array(candidate.values)))
            mergeRecovery = recovery; throw ModernSessionError.recoveryRequired(recovery)
        }
    }
    private func selection(_ field: WritingField, _ range: Range<Int>, in captured: WritingProjection? = nil) throws -> (keys: [WritingAtomKey], edge: WritingEdge, marks: [JSONValue], position: WritingPosition) {
        if captured == nil { try validateField(field) }
        let projection = captured ?? self.projection
        var cursor = 0, boundaries: Set<Int> = [0], selected: [WritingAtomKey] = []
        var previous: WritingAtomKey?, next: WritingAtomKey?, marks: [JSONValue] = []
        for key in projection.visibleKeys(in: field) {
            let value = try projection.value(of: key)
            if cursor < range.lowerBound { previous = key; marks = value["marks"]?.array ?? [] }
            if cursor >= range.lowerBound && next == nil { next = key; if previous == nil { marks = value["marks"]?.array ?? [] } }
            if cursor >= range.lowerBound && cursor < range.upperBound { selected.append(key) }
            cursor += plainText([value]).utf16.count; boundaries.insert(cursor)
        }
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound) else { throw EditorError.invalidRange }
        let edge: WritingEdge
        if let previous, previous.element.change.counter > 0 { edge = .after(previous) }
        else { edge = next.map(WritingEdge.before) ?? previous.map(WritingEdge.after) ?? .start }
        return (selected, edge, marks, WritingPosition(documentID: documentID, epoch: epoch, field: field,
            anchor: next ?? previous, affinity: next == nil ? .after : .before))
    }

    private func replay(_ candidate: [ChangeID: ModernChange]) throws -> (WritingProjection, ModernDocument, StructuralState) {
        let ordered = candidate.values.sorted { $0.id < $1.id }
        let registered = try modernBirthRegistry(ordered, baseline: seed.structure)
        let registry = registered.structure, registeredBirths = registered.births
        let schemaFields = Set(ordered.flatMap { change -> [WritingField] in
            guard case .edit(let operations) = change.body else { return [] }
            return operations.flatMap { operation -> [WritingField] in
                if case .schemaConvert(let conversion) = operation { return [conversion.source, conversion.destination] }; return []
            }
        })
        let registeredSeeds = seedWritingAtoms(registeredBirths)
        try preflight(ordered, fields: Set(registeredBirths.keys), seeds: registeredSeeds.atoms)
        let active = activeStates(candidate)
        var raw = Materialized(); raw.structure = seed.structure
        var births = seed.births
        var collectionBirths = modernCollectionBirths(seed.structure)
        var available = Dictionary(uniqueKeysWithValues: registeredSeeds.atoms.map { ($0.key, $0.node) })
        var routes: [ModernColumnRoute] = []
        var appearance = baseline.fields["appearance"]!.object!
        var previousAuthor: [String: ChangeID] = [:]
        for change in ordered {
            guard validModernChangeID(change.id) else { throw EditorError.invalidChange }
            let cohort = try closure(change.observed, before: change.id, in: candidate)
            if let previous = previousAuthor[change.id.actor], !cohort.contains(previous) { throw EditorError.invalidChange }
            previousAuthor[change.id.actor] = change.id
            switch change.body {
            case .setActive(let targets, _):
                guard !targets.isEmpty, targets.count <= 100_000, Set(targets).count == targets.count else { throw EditorError.invalidChange }
                for target in targets {
                    guard target.actor == change.id.actor, target < change.id, cohort.contains(target),
                          let original = candidate[target], case .edit = original.body else { throw EditorError.invalidChange }
                }
            case .edit(let operations):
                guard !operations.isEmpty, operations.count <= 100_000 else { throw EditorError.invalidChange }
                var introduced = Set<ElementID>(), registers = Set<String>()
                var causalTextProjection: WritingProjection?
                func reference(_ key: WritingAtomKey) throws {
                    try modernReference(key.origin.node, before: change.id, cohort: cohort, registry: registry)
                    guard registeredBirths[key.origin] != nil, raw.structure!.nodes[key.origin.node] != nil else { throw EditorError.invalidChange }
                    let id = key.element
                    guard id.index >= 0, id.index <= 2_147_483_647,
                          id.change.counter == 0 ? id.change.actor.isEmpty : validModernChangeID(id.change) && (id.change == change.id || cohort.contains(id.change)),
                          available[key] != nil else { throw EditorError.invalidChange }
                }
                func keys(_ keys: [WritingAtomKey]) throws {
                    guard !keys.isEmpty, keys.count <= 100_000, Set(keys).count == keys.count else { throw EditorError.invalidChange }
                    for key in keys { try reference(key) }
                }
                for operation in operations {
                    switch operation {
                    case .structure(let mutation):
                        try validateModernStructure(mutation, change: change.id, cohort: cohort, registry: registry, structure: projectModernColumnRoutes(raw.structure!, routes: routes), introduced: &introduced)
                        try apply([mutation], enabled: active[change.id] ?? true, to: &raw)
                        retainModernFieldBirths(in: raw.structure!, births: &births)
                        collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                    case .createColumns(let value):
                        let captured = try causalColumnStructure(cohort, in: candidate)
                        try validateModernColumnCreation(value, in: captured)
                        for node in value.nodes { try modernReference(node, before: change.id, cohort: cohort, registry: registry) }
                        if let owner = value.collection.owner { try modernReference(owner, before: change.id, cohort: cohort, registry: registry) }
                        for source in value.sources + [value.after].compactMap({ $0 }) {
                            try modernColumnPlacementReference(source, change: change.id, cohort: cohort, registry: registry)
                        }
                        for index in 0...value.nodes.count {
                            guard introduced.insert(ElementID(change: change.id, index: index)).inserted else { throw EditorError.invalidChange }
                        }
                        let enabled = active[change.id] ?? true
                        try applyModernColumnCreation(value, enabled: enabled, raw: &raw)
                        retainModernFieldBirths(in: raw.structure!, births: &births)
                        collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                        routes.append(modernCreationRoute(value, enabled: enabled))
                    case .removeColumns(let layout, let source):
                        try modernReference(layout, before: change.id, cohort: cohort, registry: registry)
                        try modernColumnPlacementReference(source, change: change.id, cohort: cohort, registry: registry)
                        let captured = try causalColumnStructure(cohort, in: candidate)
                        _ = try captured.address(of: layout); _ = try modernColumnIDs(layout, in: captured)
                        guard try captured.effectivePlacements()[layout]?.id == source,
                              introduced.insert(ElementID(change: change.id, index: 0)).inserted else { throw EditorError.invalidChange }
                        routes.append(try modernRemovalRoute(layout, source: source, change: change.id, enabled: active[change.id] ?? true, structure: raw.structure!))
                    case .resizeColumns(let layout, let split):
                        try modernReference(layout, before: change.id, cohort: cohort, registry: registry)
                        _ = try modernColumnIDs(layout, in: raw.structure!)
                        let captured = try causalColumnStructure(cohort, in: candidate)
                        _ = try captured.address(of: layout)
                        guard (1000...9000).contains(split) else { throw EditorError.invalidChange }
                        try apply([.setNodeField(identity: layout, path: ["splitBasisPoints"], value: .number(Double(split)))], enabled: active[change.id] ?? true, to: &raw)
                    case .convertBlock(let node, let type, let attributes):
                        try modernReference(node, before: change.id, cohort: cohort, registry: registry)
                        let captured = try causalColumnStructure(cohort, in: candidate)
                        guard let original = captured.nodes[node], let current = raw.structure!.nodes[node] else { throw EditorError.invalidChange }
                        _ = try captured.address(of: node)
                        _ = try writingConvertedBlock(original, type: type, attributes: attributes, modern: true)
                        if active[change.id] ?? true {
                            raw.structure!.nodes[node] = try writingConvertedBlock(current, type: type, attributes: attributes, modern: true)
                            raw.structure!.touched.insert(node)
                        }
                    case .schemaConvert(let conversion):
                        try modernReference(conversion.node, before: change.id, cohort: cohort, registry: registry)
                        try modernReference(conversion.source.node, before: change.id, cohort: cohort, registry: registry)
                        let authored = try causalWritingReplay(cohort, in: candidate)
                        try validateModernSchemaConversion(conversion, change: change.id, structure: authored.1, projection: authored.0)
                        try applyWritingSchemaConversion(conversion, change: change.id, enabled: active[change.id] ?? true,
                            raw: &raw, births: &births, collectionBirths: &collectionBirths, introduced: &introduced, modern: true)
                    case .splitBlock(let split):
                        try validateTargetScope(split.range.start.documentID, split.range.start.epoch)
                        try validateTargetScope(split.range.end.documentID, split.range.end.epoch)
                        let capturedIDs = try closure(split.range.observed, before: change.id, in: candidate)
                        guard capturedIDs.isSubset(of: cohort), introduced.insert(split.creation).inserted else { throw EditorError.invalidChange }
                        let capturedChanges = ordered.filter { capturedIDs.contains($0.id) }
                        for position in [split.range.start, split.range.end] {
                            if let anchor = position.anchor {
                                guard modernRelatedFields(anchor.origin, position.field, changes: capturedChanges) else { throw EditorError.invalidChange }
                            }
                        }
                        let captured = try causalWritingReplay(capturedIDs, in: candidate), authored = try causalWritingReplay(cohort, in: candidate)
                        let expected = try planModernSplit(range: split.range, creation: split.creation, label: split.value["id"]!.string!, captured: captured, authored: authored)
                        guard split == expected else { throw EditorError.invalidChange }
                        try modernReference(split.source.node, before: change.id, cohort: cohort, registry: registry)
                        try modernColumnPlacementReference(split.after, change: change.id, cohort: cohort, registry: registry)
                        try applyModernSplitBirth(split, enabled: active[change.id] ?? true, raw: &raw, collectionBirths: collectionBirths)
                        retainModernFieldBirths(in: raw.structure!, births: &births)
                        collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                    case .mergeBlocks(let join):
                        try validateTargetScope(join.selection.documentID, join.selection.epoch)
                        let capturedIDs = try closure(join.selection.observed, before: change.id, in: candidate)
                        guard capturedIDs.isSubset(of: cohort) else { throw EditorError.invalidChange }
                        let captured = try causalColumnStructure(capturedIDs, in: candidate), authored = try causalWritingReplay(cohort, in: candidate)
                        try validateSelectedNodes(join.selection.nodes, in: captured)
                        try validateModernJoin(join, structure: authored.1, projection: authored.0)
                    case .setAppearance(let field, let value):
                        try validateAppearance(field: field, value: value)
                        guard registers.insert(field).inserted else { throw EditorError.invalidChange }
                        if active[change.id] ?? true { appearance[field] = .string(value) }
                    case .text(let mutation):
                        switch mutation {
                        case .insert(let atom):
                            try modernReference(atom.key.origin.node, before: change.id, cohort: cohort, registry: registry)
                            guard registeredBirths[atom.key.origin] != nil, raw.structure!.nodes[atom.key.origin.node] != nil else { throw EditorError.invalidChange }
                            guard atom.key.element.change == change.id, atom.key.element.index >= 0, atom.key.element.index <= 2_147_483_647,
                                  introduced.insert(atom.key.element).inserted, available[atom.key] == nil else { throw EditorError.invalidChange }
                            let ownBirth: Bool
                            if case .inserted(let creation, _) = atom.key.origin.node { ownBirth = creation.change == change.id }
                            else { ownBirth = false }
                            // The current edit's validated birth already proves its
                            // original field. A later alias must not invalidate it.
                            if schemaFields.contains(atom.key.origin), !ownBirth {
                                if causalTextProjection == nil { causalTextProjection = try causalWritingReplay(cohort, in: candidate).0 }
                                guard try causalTextProjection!.destination(of: atom.key.origin) == atom.key.origin else { throw EditorError.invalidChange }
                            }
                            if let anchor = atom.edge.anchor {
                                try reference(anchor)
                                if anchor.origin != atom.key.origin {
                                    if causalTextProjection == nil { causalTextProjection = try causalWritingReplay(cohort, in: candidate).0 }
                                    guard try causalTextProjection!.field(of: anchor) == atom.key.origin else { throw EditorError.invalidChange }
                                }
                            }
                            switch atom.route {
                            case .field(let field): guard field == atom.key.origin, atom.edge == .start else { throw EditorError.invalidChange }
                            case .follow(let anchor): guard atom.edge.anchor == anchor else { throw EditorError.invalidChange }; try reference(anchor)
                            }
                            try validateAtom(atom.node, field: atom.key.origin)
                            available[atom.key] = atom.node
                        case .delete(let span): try keys(span)
                        case .format(let span, let type, let mark):
                            try keys(span); try validateModernMark(type: type, mark: mark)
                            if causalTextProjection == nil { causalTextProjection = try causalWritingReplay(cohort, in: candidate).0 }
                            for key in span { guard try !plainField(causalTextProjection!.field(of: key)) else { throw EditorError.invalidChange } }
                        default: throw EditorError.invalidChange
                        }
                    }
                }
            }
        }
        let shared = try WritingSession.projectState(raw: raw, changes: modernProjectionChanges(ordered), births: births,
            protocolVersion: 6, activeOverride: active, omitEmptyMarks: true)
        var output = shared.0
        let projection = shared.1, values = shared.2
        output = try projectModernColumnRoutes(output, routes: routes)
        var fields = try output.document(documentID: documentID, text: values).fields
        fields["appearance"] = .object(appearance)
        return (projection, try ModernDocument(fields: fields), output)
    }
    private func causalColumnStructure(_ cohort: Set<ChangeID>, in candidate: [ChangeID: ModernChange]) throws -> StructuralState {
        try causalWritingReplay(cohort, in: candidate).1
    }
    private func causalWritingReplay(_ cohort: Set<ChangeID>, in candidate: [ChangeID: ModernChange]) throws -> (WritingProjection, StructuralState) {
        let subset = candidate.filter { cohort.contains($0.key) }, active = activeStates(subset)
        var raw = Materialized(); raw.structure = seed.structure
        var births = seed.births
        var collectionBirths = modernCollectionBirths(seed.structure)
        var routes: [ModernColumnRoute] = []
        for change in subset.values.sorted(by: { $0.id < $1.id }) {
            guard case .edit(let operations) = change.body else { continue }
            let enabled = active[change.id] ?? true
            for operation in operations {
                switch operation {
                case .structure(let mutation):
                    try apply([mutation], enabled: enabled, to: &raw)
                    retainModernFieldBirths(in: raw.structure!, births: &births)
                    collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                case .createColumns(let value):
                    try applyModernColumnCreation(value, enabled: enabled, raw: &raw)
                    retainModernFieldBirths(in: raw.structure!, births: &births)
                    collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                    routes.append(modernCreationRoute(value, enabled: enabled))
                case .removeColumns(let layout, let source):
                    routes.append(try modernRemovalRoute(layout, source: source, change: change.id, enabled: enabled, structure: raw.structure!))
                case .resizeColumns(let layout, let split):
                    try apply([.setNodeField(identity: layout, path: ["splitBasisPoints"], value: .number(Double(split)))], enabled: enabled, to: &raw)
                case .convertBlock(let node, let type, let attributes):
                    if enabled, let current = raw.structure!.nodes[node] {
                        raw.structure!.nodes[node] = try writingConvertedBlock(current, type: type, attributes: attributes, modern: true)
                        raw.structure!.touched.insert(node)
                    }
                case .schemaConvert(let conversion):
                    var introduced = Set<ElementID>()
                    try applyWritingSchemaConversion(conversion, change: change.id, enabled: enabled,
                        raw: &raw, births: &births, collectionBirths: &collectionBirths, introduced: &introduced, modern: true)
                case .splitBlock(let split):
                    try applyModernSplitBirth(split, enabled: enabled, raw: &raw, collectionBirths: collectionBirths)
                    retainModernFieldBirths(in: raw.structure!, births: &births)
                    collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
                case .mergeBlocks: break
                case .text: break
                case .setAppearance: break
                }
            }
        }
        let shared = try WritingSession.projectState(raw: raw, changes: modernProjectionChanges(subset.values.sorted { $0.id < $1.id }),
            births: births, protocolVersion: 6, activeOverride: active, omitEmptyMarks: true)
        let output = shared.0
        return (shared.1, try projectModernColumnRoutes(output, routes: routes))
    }
    /// Bound recursive payloads before a Foundation encoder/decoder is asked to
    /// walk them, including typed packets that did not enter through raw JSON.
    private func validateResources(_ changes: [ModernChange]) throws {
        for change in changes {
            guard change.observed.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
            switch change.body {
            case .setActive(let targets, _): guard targets.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
            case .edit(let operations):
                guard operations.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
                for operation in operations {
                    if case .schemaConvert(let conversion) = operation {
                        try inspectModernPayload(.object(conversion.attributes))
                        try inspectModernPayload(.object(conversion.preservedItemFields))
                        try validateModernSchemaShape(conversion, change: change.id)
                    }
                    if case .splitBlock(let split) = operation {
                        try inspectModernPayload(split.value); try validateModernSplitShape(split, change: change.id)
                    }
                    if case .mergeBlocks(let join) = operation {
                        guard join.selection.nodes.count == 2 else { throw EditorError.invalidChange }
                    }
                    if case .convertBlock(let node, let type, let attributes) = operation {
                        try modernStructuralIdentityShape(node)
                        try inspectModernPayload(.object(attributes))
                        try validateWritingConversionAttributes(type: type, attributes: attributes)
                    }
                    if case .createColumns(let value) = operation {
                        try inspectModernPayload(value.layout)
                        guard value.nodes.count <= 10_000, value.sources.count <= 10_000 else { throw EditorError.recoveryCapacityExceeded }
                    }
                    if case .structure(let mutation) = operation {
                        switch mutation {
                        case .insertNode(let value, _, _, _, _): try inspectModernPayload(value)
                        case .moveNode: break
                        case .deleteNodes(let identities): guard identities.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
                        default: throw EditorError.invalidChange
                        }
                    }
                    if case .text(let mutation) = operation {
                        switch mutation {
                        case .insert(let atom): try inspectModernPayload(atom.node)
                        case .format(let keys, _, let mark):
                            guard keys.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
                            if let mark { try inspectModernPayload(mark) }
                        case .delete(let keys): guard keys.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
                        default: throw EditorError.invalidChange
                        }
                    }
                }
            }
        }
    }
    /// Check intrinsic operation shape even when a missing predecessor means
    /// causal replay must be retained for later. Undo never hides malformed input.
    private func preflight(_ changes: [ModernChange], fields: Set<WritingField>, seeds: [WritingAtomSeed]) throws {
        let baselineKeys = Set(seeds.map(\.key))
        for change in changes {
            guard validModernChangeID(change.id) else { throw EditorError.invalidChange }
            try validateObservedFrontier(change.observed, before: change.id)
            func fieldShape(_ field: WritingField) throws {
                if fields.contains(field) { return }
                // An incremental alias can arrive before its conversion birth.
                // Causal replay still requires the exact retained field proof.
                if case .baseline = field.node, ["content", "code"].contains(field.name),
                   fields.contains(WritingField(node: field.node, name: field.name == "code" ? "content" : "code")) { return }
                // An incremental packet may arrive before its field's birth.
                // Only plausible inserted origins survive to causal recovery;
                // known fields and baseline aliases still require exact proof.
                guard case .inserted(let creation, _) = field.node, creation.change < change.id,
                      ["content", "summary", "caption", "code", "expression"].contains(field.name) else { throw EditorError.invalidChange }
                try modernStructuralIdentityShape(field.node)
            }
            func referenceShape(_ key: WritingAtomKey) throws {
                try fieldShape(key.origin)
                guard key.element.index >= 0, key.element.index <= 2_147_483_647 else { throw EditorError.invalidChange }
                if key.element.change.counter == 0 {
                    guard key.element.change.actor.isEmpty, !fields.contains(key.origin) || baselineKeys.contains(key) else { throw EditorError.invalidChange }
                } else { guard validModernChangeID(key.element.change), key.element.change <= change.id else { throw EditorError.invalidChange } }
            }
            func keysShape(_ keys: [WritingAtomKey]) throws {
                guard !keys.isEmpty, Set(keys).count == keys.count else { throw EditorError.invalidChange }
                for key in keys { try referenceShape(key) }
            }
            switch change.body {
            case .setActive(let targets, _):
                guard !targets.isEmpty, Set(targets).count == targets.count, targets.allSatisfy({ validModernChangeID($0) && $0.actor == change.id.actor && $0 < change.id }) else { throw EditorError.invalidChange }
            case .edit(let operations):
                guard !operations.isEmpty else { throw EditorError.invalidChange }
                var elements = Set<ElementID>(), registers = Set<String>()
                for operation in operations {
                    switch operation {
                    case .schemaConvert(let conversion):
                        try validateModernSchemaShape(conversion, change: change.id)
                        try fieldShape(conversion.source)
                        if let creation = conversion.creation { guard elements.insert(creation).inserted else { throw EditorError.invalidChange } }
                        guard registers.insert("convert:" + conversion.node.key).inserted else { throw EditorError.invalidChange }
                    case .splitBlock(let split):
                        try validateModernSplitShape(split, change: change.id)
                        try validateTargetScope(split.range.start.documentID, split.range.start.epoch)
                        try validateTargetScope(split.range.end.documentID, split.range.end.epoch)
                        try validateObservedFrontier(split.range.observed, before: change.id)
                        try fieldShape(split.range.start.field); try fieldShape(split.source)
                        for key in split.selected + split.prefix + split.suffix { try referenceShape(key) }
                        if let key = split.edge.anchor { try referenceShape(key) }
                        for position in [split.range.start, split.range.end] { if let key = position.anchor { try referenceShape(key) } }
                        guard elements.insert(split.creation).inserted else { throw EditorError.invalidChange }
                    case .mergeBlocks(let join):
                        guard join.selection.nodes.count == 2, Set(join.selection.nodes).count == 2 else { throw EditorError.invalidChange }
                        try validateTargetScope(join.selection.documentID, join.selection.epoch)
                        try validateObservedFrontier(join.selection.observed, before: change.id)
                        for node in join.selection.nodes { try modernStructuralIdentityShape(node) }
                        if let key = join.edge.anchor { try referenceShape(key) }
                    case .convertBlock(let node, let type, let attributes):
                        try modernStructuralIdentityShape(node); try validateWritingConversionAttributes(type: type, attributes: attributes)
                        guard registers.insert("convert:" + node.key).inserted else { throw EditorError.invalidChange }
                    case .structure, .createColumns, .removeColumns, .resizeColumns: break
                    case .setAppearance(let field, let value):
                        try validateAppearance(field: field, value: value)
                        guard registers.insert(field).inserted else { throw EditorError.invalidChange }
                    case .text(let mutation):
                        switch mutation {
                        case .insert(let atom):
                            try fieldShape(atom.key.origin)
                            guard atom.key.element.change == change.id, atom.key.element.index >= 0, atom.key.element.index <= 2_147_483_647,
                                  elements.insert(atom.key.element).inserted else { throw EditorError.invalidChange }
                            if let anchor = atom.edge.anchor { try referenceShape(anchor) }
                            switch atom.route {
                            case .field(let field): guard atom.edge == .start, field == atom.key.origin else { throw EditorError.invalidChange }
                            case .follow(let key): guard atom.edge.anchor == key else { throw EditorError.invalidChange }; try referenceShape(key)
                            }
                            try validateAtom(atom.node, field: atom.key.origin)
                        case .delete(let keys): try keysShape(keys)
                        case .format(let keys, let type, let mark):
                            try keysShape(keys); try validateModernMark(type: type, mark: mark)
                            guard keys.allSatisfy({ $0.origin != titleField }) else { throw EditorError.invalidChange }
                        default: throw EditorError.invalidChange
                        }
                    }
                }
            }
        }
    }
    private func validateAtom(_ value: JSONValue, field: WritingField) throws {
        do { try Validation.inline(.array([value]), modern: true) } catch { throw EditorError.invalidChange }
        if value["type"] == .string("text") {
            guard value["text"]?.string?.unicodeScalars.count == 1 else { throw EditorError.invalidChange }
        } else { guard !plainText([value]).isEmpty else { throw EditorError.invalidChange } }
        if plainField(field) {
            guard value["type"] == .string("text"), (value["marks"]?.array ?? []).isEmpty,
                  Set(value.object!.keys).isSubset(of: ["type", "text", "marks"]) else { throw EditorError.invalidChange }
            if field == titleField, value["text"]!.string!.unicodeScalars.contains(where: { [10, 13, 0x2028, 0x2029].contains($0.value) }) { throw EditorError.invalidChange }
        }
        for mark in value["marks"]?.array ?? [] { try validateModernMark(type: mark["type"]?.string ?? "", mark: mark) }
    }
}

private func validModernChangeID(_ id: ChangeID) -> Bool { id.counter > 0 && id.counter <= 9_007_199_254_740_991 && validToken(id.actor) }
private func frontier(_ changes: [ChangeID: ModernChange]) -> [ChangeID] {
    var tips: [String: ChangeID] = [:]
    for id in changes.keys where tips[id.actor].map({ $0 < id }) ?? true { tips[id.actor] = id }
    return tips.values.sorted()
}
private func closure(_ frontier: [ChangeID], before bound: ChangeID, in changes: [ChangeID: ModernChange]) throws -> Set<ChangeID> {
    try validateObservedFrontier(frontier, before: bound)
    var found = Set<ChangeID>(), pending = frontier
    while let id = pending.popLast() {
        guard found.insert(id).inserted else { continue }
        guard let change = changes[id] else { throw WritingProjectionError.missingAtom }
        try validateObservedFrontier(change.observed, before: id); pending.append(contentsOf: change.observed)
    }
    return found
}
private func validateAppearance(field: String, value: String) throws {
    switch field {
    case "fontFamily": guard ModernAppearance.FontFamily(rawValue: value) != nil else { throw EditorError.invalidChange }
    case "fontSize": guard ModernAppearance.FontSize(rawValue: value) != nil else { throw EditorError.invalidChange }
    case "pageWidth": guard ModernAppearance.PageWidth(rawValue: value) != nil else { throw EditorError.invalidChange }
    default: throw EditorError.invalidChange
    }
}
func validateModernMark(type: String, mark: JSONValue?) throws {
    guard ["bold", "italic", "strikethrough", "code", "link", "semantic-color", "semantic-background"].contains(type), mark == nil || mark?["type"] == .string(type) else { throw EditorError.invalidChange }
    if let mark {
        do { try Validation.mark(mark, modern: true) } catch { throw EditorError.invalidChange }
        if type == "link" {
            guard let scheme = mark["href"]?.string.flatMap({ URL(string: $0)?.scheme?.lowercased() }), ["http", "https", "mailto"].contains(scheme) else { throw EditorError.invalidChange }
        }
    }
}
private func modernScalarBoundary(_ offset: Int, in text: String) -> Bool {
    if offset == 0 { return true }
    var cursor = 0
    for scalar in text.unicodeScalars { cursor += scalar.value > 0xffff ? 2 : 1; if cursor == offset { return true }; if cursor > offset { return false } }
    return false
}
private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
private func modernWireValue(_ data: Data) throws -> JSONValue {
    guard data.count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
    try inspectModernJSONKeys(data, maximumDepth: 128)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}
private func decodeModernBatch(_ value: JSONValue) throws -> ModernBatch {
    struct Wire: Decodable {
        let version: Int, documentID: String, epoch: String
        let baseline: JSONValue
        let changes: [ModernChange]
    }
    guard let fields = value.object, Set(fields.keys) == ["version", "documentID", "epoch", "baseline", "changes"] else { throw EditorError.invalidChange }
    let wire = try JSONDecoder().decode(Wire.self, from: canonicalEncoder().encode(value))
    guard wire.changes.count <= 100_000, let baseline = wire.baseline.object,
          try jsonValue(wire.changes) == fields["changes"] else { throw EditorError.invalidChange }
    return ModernBatch(documentID: wire.documentID, epoch: wire.epoch, baseline: try ModernDocument(fields: baseline), changes: wire.changes, version: wire.version)
}

private func inspectModernPayload(_ value: JSONValue) throws {
    var pending = [(value, 0)]
    while let (value, depth) = pending.popLast() {
        guard depth <= 100 else { throw EditorError.invalidChange }
        if case .number(let number) = value, !number.isFinite { throw EditorError.invalidChange }
        if let values = value.array { pending.append(contentsOf: values.map { ($0, depth + 1) }) }
        else if let fields = value.object { pending.append(contentsOf: fields.values.map { ($0, depth + 1) }) }
    }
}
