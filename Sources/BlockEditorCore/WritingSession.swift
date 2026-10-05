import Foundation

public struct WritingPosition: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let field: WritingField
    public let anchor: WritingAtomKey?
    public let affinity: TextAffinity
    public let intraAtomOffset: Int?
    public init(documentID: String, epoch: String, field: WritingField, anchor: WritingAtomKey? = nil, affinity: TextAffinity = .after, intraAtomOffset: Int? = nil) {
        self.documentID = documentID; self.epoch = epoch
        self.field = field; self.anchor = anchor; self.affinity = affinity; self.intraAtomOffset = intraAtomOffset
    }
}
public struct ResolvedWritingPosition: Codable, Equatable, Sendable {
    public let address: TextAddress
    public let offset: Int
}
/// An anchored partial range; endpoints follow their atoms across remote edits.
public struct WritingTextRange: Codable, Equatable, Sendable {
    public let start: WritingPosition
    public let end: WritingPosition
    public init(start: WritingPosition, end: WritingPosition) { self.start = start; self.end = end }
}
/// Ordered whole nodes and partial fields. Ancestor/descendant overlap is rejected.
public struct WritingSelection: Codable, Equatable, Sendable {
    public let nodes: [NodeID]
    public let text: [WritingTextRange]
    public init(nodes: [NodeID] = [], text: [WritingTextRange] = []) { self.nodes = nodes; self.text = text }
}
public struct WritingCopy: Codable, Equatable, Sendable {
    public let nodes: [JSONValue]
    public let text: [[JSONValue]]
}
public enum WritingOperation: Codable, Equatable, Sendable {
    case structure(Mutation)
    case text(WritingMutation)
    case convertBlock(node: NodeID, type: String, attributes: [String: JSONValue])
    case schemaConvert(WritingSchemaConversion)
    case retainParagraphRole(WritingParagraphRole)
    case exitListItem(node: NodeID, owner: NodeID, source: NodePlacementID, after: NodePlacementID?)
}
public enum WritingChangeBody: Codable, Equatable, Sendable {
    case edit([WritingOperation])
    case setActive(target: ChangeID, active: Bool)
}
public struct WritingChange: Codable, Equatable, Sendable {
    public let id: ChangeID
    public let body: WritingChangeBody
    /// Protocols 4 and 5 record the maximal observed change for each actor. Recursive
    /// predecessor closure identifies exact observed history despite clock holes.
    public let observed: [ChangeID]?
    public init(id: ChangeID, body: WritingChangeBody, observed: [ChangeID]? = nil) {
        self.id = id; self.body = body; self.observed = observed
    }
}
public struct WritingBatch: Codable, Equatable, Sendable {
    public let version: Int
    public let documentID: String
    public let epoch: String
    public let baseline: Document
    public let changes: [WritingChange]
    public init(documentID: String, epoch: String, baseline: Document, changes: [WritingChange], version: Int = 3) {
        self.version = version; self.documentID = documentID; self.epoch = epoch; self.baseline = baseline; self.changes = changes
    }
}
public struct WritingSyncState: Codable, Equatable, Sendable {
    public let version: Int
    public let documentID: String
    public let epoch: String
    public let received: [ChangeID]
    public init(documentID: String = "", epoch: String = "", received: [ChangeID] = [], version: Int = 3) {
        self.documentID = documentID; self.epoch = epoch; self.received = received; self.version = version
    }
}
public struct WritingRecovery: Codable, Equatable, Sendable {
    public let reason: MergeRecoveryReason
    public let batch: WritingBatch
}
public enum WritingSessionError: Error, Equatable, Sendable {
    case incompatibleEpoch, compositionActive, recoveryRequired(WritingRecovery)
}

/// Experimental writing facade. Protocol 3 is the default; identity-preserving
/// schema conversion requires an explicitly created protocol 4 or 5 epoch. It shares
/// document validation and structural replay with the core; v1/v2 are unchanged.
/// Confine it to one executor and keep pending recovery separate from save().
public final class WritingSession {
    public let documentID: String
    public let actorID: String
    public let epoch: String
    public let protocolVersion: Int
    public let baseline: Document
    // Only these explicitly supported epochs inherit retained-origin writing semantics.
    private var usesRetainedOrigins: Bool { protocolVersion == 4 || protocolVersion == 5 || protocolVersion == 6 }
    public var onChange: ((Document, WritingChange?) -> Void)?
    public var onWillReceive: (() -> Void)?
    public var isComposing = false
    /// Local host authoring policy; receive and preserved content are unaffected.
    public var allowedBlockTypes: Set<String>?
    public private(set) var mergeRecovery: WritingRecovery?
    private var log: [ChangeID: WritingChange] = [:]
    private var counter: UInt64 = 0
    private var undoStack: [ChangeID] = [], redoStack: [ChangeID] = []
    private var preparingReceive = false
    private var remoteHolds = 0
    private var deferred: [WritingBatch] = []
    private var deferredBytes = 0
    private var drainingCount = 0
    private var drainingBytes = 0
    private var drainingDeferred = false
    private var structure: StructuralState
    private var projection: WritingProjection
    public private(set) var document: Document

    public init(documentID: String, actorID: String, epoch: String, document: Document, protocolVersion: Int = 3) throws {
        guard [3, 4, 5, 6].contains(protocolVersion) else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !documentID.isEmpty, validToken(actorID), validToken(epoch) else { throw EditorError.invalidChange }
        let validated = try Document(blocks: document.blocks)
        guard try validated.json().count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        self.documentID = documentID; self.actorID = actorID; self.epoch = epoch; self.protocolVersion = protocolVersion; self.baseline = validated
        let raw = Materialized.seed(validated, version: 2)
        let result = try Self.project(raw: raw, changes: [])
        structure = result.0; projection = result.1; self.document = result.2
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var syncState: WritingSyncState { WritingSyncState(documentID: documentID, epoch: epoch, received: log.keys.sorted(), version: protocolVersion) }
    @discardableResult public func softBreak(at address: TextAddress, range: Range<Int>) throws -> WritingPosition {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        return try replaceText(at: address, range: range, with: "\n")
    }
    public func exportRecovery() throws -> Data? { try mergeRecovery.map { try canonicalEncoder().encode($0) } }
    public func restoreRecovery(_ data: Data) throws {
        guard data.count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
        let recovery = try JSONDecoder().decode(WritingRecovery.self, from: data)
        try receive(recovery.batch)
    }
    /// Resolve a rejected union by explicitly disabling an accepted transaction
    /// of this author. Every original change remains in the retained history.
    public func repairUndo(_ target: ChangeID) throws { try repairHistory(target, active: false) }
    /// Explicitly cancel a rejected v4 undo by reactivating its original author
    /// transaction. The failed undo remains in history; no proposal is discarded.
    public func repairRedo(_ target: ChangeID) throws {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        try repairHistory(target, active: true)
    }
    private func repairHistory(_ target: ChangeID, active: Bool) throws {
        var candidate = try recoveryCandidate()
        guard target.actor == actorID, undoStack.contains(target) || (usesRetainedOrigins && redoStack.contains(target)),
              let original = log[target], case .edit = original.body else { throw EditorError.invalidChange }
        let id = try recoveryID(candidate)
        let change = WritingChange(id: id, body: .setActive(target: target, active: active), observed: usesRetainedOrigins ? observedFrontier(candidate) : nil)
        candidate[id] = change
        try admitRepair(candidate, change: change)
    }
    /// Repair a supported field of the rejected v4 union using a scalar-safe
    /// minimal diff. Planning never exposes an invalid public document. Final
    /// admission validates the whole union atomically before state publication.
    public func repairText(node: NodeID, field: String, text: String) throws {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        var candidate = try recoveryCandidate()
        guard text.utf16.count <= 100_000 else { throw EditorError.invalidRange }
        let plan = try replayProjection(candidate)
        _ = try plan.0.address(of: node)
        guard let value = plan.0.nodes[node], writingFields(value).contains(field) else { throw EditorError.invalidPath }
        let destination = WritingField(node: node, name: field)
        let old = plan.1.text(in: destination)
        guard old.utf16.count <= 100_000 else { throw EditorError.invalidRange }
        let before = Array(old.unicodeScalars), after = Array(text.unicodeScalars)
        var prefix = 0, suffix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        var cursor = 0, deleted: [WritingAtomKey] = [], previous: WritingAtomKey?, next: WritingAtomKey?, marks: [JSONValue] = []
        for key in plan.1.visibleKeys(in: destination) {
            let payload = try plan.1.value(of: key), end = cursor + plainText([payload]).unicodeScalars.count
            if end <= prefix { previous = key; marks = payload["marks"]?.array ?? [] }
            else if cursor < before.count - suffix {
                guard cursor >= prefix, end <= before.count - suffix else { throw EditorError.invalidRange }
                deleted.append(key)
                if prefix == 0, cursor == 0 { marks = payload["marks"]?.array ?? [] }
            } else if next == nil { next = key }
            cursor = end
        }
        let id = try recoveryID(candidate)
        var operations: [WritingOperation] = deleted.isEmpty ? [] : [.text(.delete(keys: deleted))]
        let edge: WritingEdge = previous.map(WritingEdge.after) ?? next.map(WritingEdge.before) ?? .start
        operations += try inserted(String(String.UnicodeScalarView(after[prefix..<(after.count - suffix)])), id: id,
                                   field: destination, edge: edge, marks: marks).0
        guard !operations.isEmpty else { throw EditorError.invalidChange }
        let change = WritingChange(id: id, body: .edit(operations), observed: observedFrontier(candidate))
        candidate[id] = change
        try admitRepair(candidate, change: change, authoredEdit: true)
    }
    private func recoveryCandidate() throws -> [ChangeID: WritingChange] {
        guard !preparingReceive, remoteHolds == 0, !isComposing, let recovery = mergeRecovery else { throw EditorError.invalidChange }
        var candidate = log
        for change in recovery.batch.changes { candidate[change.id] = change }
        return candidate
    }
    private func recoveryID(_ candidate: [ChangeID: WritingChange]) throws -> ChangeID {
        let clock = candidate.keys.map(\.counter).max() ?? counter
        guard clock < 9_007_199_254_740_991 else { throw EditorError.invalidChange }
        return ChangeID(counter: clock + 1, actor: actorID)
    }
    private func admitRepair(_ candidate: [ChangeID: WritingChange], change: WritingChange, authoredEdit: Bool = false) throws {
        try capacity(candidate)
        let result = try replay(candidate)
        preparingReceive = true; onWillReceive?(); preparingReceive = false
        accept(candidate, result, change: change, authoredEdit: authoredEdit)
    }
    public func changes(since receipt: WritingSyncState = WritingSyncState()) -> WritingBatch {
        let received = receipt.documentID == documentID && receipt.epoch == epoch && receipt.version == protocolVersion ? Set(receipt.received) : []
        return batch(log.values.filter { !received.contains($0.id) })
    }
    /// Commit the local composition before releasing the hold. Queued batches
    /// remain outside accepted saves/receipts and can be exported for reconnect.
    public func deferRemoteChanges() -> () throws -> Void {
        remoteHolds += 1
        var released = false
        return { [weak self] in
            guard !released, let self else { return }
            released = true; self.remoteHolds -= 1
            if self.remoteHolds == 0 { try self.retryDeferredChanges() }
        }
    }
    public func exportDeferredChanges() throws -> Data { try canonicalEncoder().encode(deferred) }
    public func retryDeferredChanges() throws {
        guard remoteHolds == 0, !preparingReceive, !drainingDeferred else { throw EditorError.invalidChange }
        var failed: [WritingBatch] = [], failure: Error?
        let pending = deferred
        drainingDeferred = true; drainingCount = pending.count; drainingBytes = deferredBytes
        defer { drainingDeferred = false; drainingCount = 0; drainingBytes = 0 }
        deferred = []; deferredBytes = 0
        for batch in pending {
            var retained = false
            do { try receive(batch) } catch {
                // Recoverable proposals have their own durable export. Protocol
                // errors retain the original packet until the host reconciles it.
                if case WritingSessionError.recoveryRequired = error { }
                else { failed.append(batch); retained = true }
                if failure == nil { failure = error }
            }
            if !retained {
                drainingCount -= 1; drainingBytes -= try canonicalEncoder().encode(batch).count
            }
        }
        deferred.insert(contentsOf: failed, at: 0)
        deferredBytes += try failed.reduce(0) { try $0 + canonicalEncoder().encode($1).count }
        if let failure, mergeRecovery != nil || !failed.isEmpty { throw failure }
    }
    public func save() throws -> Data {
        var fields = try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(changes())).object!
        fields["localHistory"] = .object(["actorID": .string(actorID),
            "undo": try Self.json(undoStack), "redo": try Self.json(redoStack)])
        return try canonicalEncoder().encode(JSONValue.object(fields))
    }
    public static func restore(_ snapshot: Data, actorID: String) throws -> WritingSession {
        guard snapshot.count <= 64_000_000 else { throw EditorError.recoveryCapacityExceeded }
        let batch = try JSONDecoder().decode(WritingBatch.self, from: snapshot)
        guard [3, 4, 5, 6].contains(batch.version) else { throw EditorError.unsupportedVersion(batch.version) }
        let session = try WritingSession(documentID: batch.documentID, actorID: actorID, epoch: batch.epoch, document: batch.baseline, protocolVersion: batch.version)
        try session.receive(batch)
        if let local = try JSONDecoder().decode(JSONValue.self, from: snapshot)["localHistory"], local["actorID"] == .string(actorID) {
            func history(_ key: String) throws -> [ChangeID] {
                let ids = try JSONDecoder().decode([ChangeID].self, from: canonicalEncoder().encode(local[key] ?? .array([])))
                guard Set(ids).count == ids.count, ids.allSatisfy({ id in
                    if id.actor != actorID { return false }
                    if case .edit = session.log[id]?.body { return true }; return false
                }) else { throw EditorError.invalidChange }
                return ids
            }
            session.undoStack = try history("undo"); session.redoStack = try history("redo")
            guard Set(session.undoStack).isDisjoint(with: session.redoStack) else { throw EditorError.invalidChange }
            var active: [ChangeID: Bool] = [:]
            for change in session.log.values.sorted(by: { $0.id < $1.id }) {
                if case .setActive(let target, let enabled) = change.body { active[target] = enabled }
            }
            guard session.undoStack.allSatisfy({ active[$0] ?? true }), session.redoStack.allSatisfy({ !(active[$0] ?? true) }) else { throw EditorError.invalidChange }
        }
        return session
    }
    public func receive(_ incoming: WritingBatch) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        guard incoming.version == protocolVersion else { throw EditorError.unsupportedVersion(incoming.version) }
        guard incoming.documentID == documentID, incoming.baseline == baseline else { throw EditorError.differentDocument }
        guard incoming.epoch == epoch else { throw WritingSessionError.incompatibleEpoch }
        guard incoming.changes.count <= 100_000 else { throw EditorError.invalidChange }
        if remoteHolds > 0 {
            let bytes = try canonicalEncoder().encode(incoming).count
            guard deferred.count + drainingCount < 64, bytes <= 64_000_000 - deferredBytes - drainingBytes else { throw EditorError.recoveryCapacityExceeded }
            deferred.append(incoming); deferredBytes += bytes; return
        }
        var candidate = log
        for change in mergeRecovery?.batch.changes ?? [] { candidate[change.id] = change }
        for change in incoming.changes {
            if let prior = candidate[change.id], prior != change { throw EditorError.conflictingChange }
            candidate[change.id] = change
        }
        guard candidate != log else { return }
        try capacity(candidate)
        do {
            let result = try replay(candidate)
            preparingReceive = true; onWillReceive?(); preparingReceive = false
            accept(candidate, result, change: nil)
        } catch let error as WritingProjectionError {
            try retain(candidate, reason: error == .missingAtom ? .schemaConstraint : .identityConflict)
        } catch EditorError.invalidDocument {
            try retain(candidate, reason: .schemaConstraint)
        } catch EditorError.structuralConflict {
            try retain(candidate, reason: .identityConflict)
        }
    }
    public func node(at address: NodeAddress) throws -> NodeID { try structure.node(at: address) }
    public func address(of node: NodeID) throws -> NodeAddress { try structure.address(of: node) }
    public func textAddress(of node: NodeID, field: String = "content") throws -> TextAddress {
        _ = try structure.address(of: node)
        guard let value = structure.nodes[node], writingFields(value).contains(field) else { throw EditorError.invalidPath }
        return node.textAddress(field)
    }
    public func text(at address: TextAddress) throws -> String { projection.text(in: try field(address)) }
    public func position(at address: TextAddress, offset: Int, affinity: TextAffinity = .before) throws -> WritingPosition {
        let field = try field(address), keys = projection.visibleKeys(in: field)
        guard writingScalarBoundary(offset, in: projection.text(in: field)) else { throw EditorError.invalidRange }
        var cursor = 0
        for key in keys {
            let value = try atom(key), length = plainText([value]).utf16.count
            if offset == cursor, affinity == .before { return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: .before) }
            if offset > cursor, offset < cursor + length {
                guard value["type"] != .string("text") else { throw EditorError.invalidRange }
                return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: affinity, intraAtomOffset: offset - cursor)
            }
            cursor += length
            if offset == cursor, affinity == .after { return WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: key, affinity: .after) }
        }
        guard offset == 0 || offset == cursor else { throw EditorError.invalidRange }
        return WritingPosition(documentID: documentID, epoch: epoch, field: field, affinity: offset == 0 ? .after : .before)
    }
    public func resolve(_ original: WritingPosition) throws -> ResolvedWritingPosition {
        var position = original, retiredHeads = Set<WritingField>()
        var retirementStates: [ChangeID: Bool]?
        while true {
            guard position.documentID == documentID, position.epoch == epoch else { throw WritingSessionError.incompatibleEpoch }
            if let anchor = position.anchor { guard anchor.element.index >= 0 else { throw EditorError.invalidChange } }
            let field = try position.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: position.field)
            do { _ = try structure.address(of: field.node) }
            catch {
                // A protocol-4 split birth retains its exact source boundary after
                // author Undo retires the new node. Empty-field head positions have
                // no text atom to follow; resolve them through that immutable birth.
                // Deleted unrelated nodes and field-end sentinels keep failing.
                guard usesRetainedOrigins, position.anchor == nil, position.affinity == .after,
                      position.intraAtomOffset == nil, !retiredHeads.contains(position.field),
                      case .inserted(let creation, let path) = position.field.node, path.isEmpty,
                      case .edit(let operations)? = log[creation.change]?.body else { throw error }
                if retirementStates == nil {
                    var winning: [ChangeID: (id: ChangeID, enabled: Bool)] = [:]
                    for change in log.values {
                        if case .setActive(let target, let enabled) = change.body,
                           winning[target].map({ $0.id < change.id }) ?? true { winning[target] = (change.id, enabled) }
                    }
                    retirementStates = winning.mapValues(\.enabled)
                }
                guard retirementStates?[creation.change] == false else { throw error }
                let boundaries = operations.compactMap { operation -> (WritingField, WritingEdge)? in
                    switch operation {
                    case .text(.splitBoundary(let source, let destination, let edge, _)),
                         .text(.spliceBoundary(let source, let destination, let edge, _, _)):
                        return destination == position.field ? (source, edge) : nil
                    default: return nil
                    }
                }
                guard boundaries.count == 1, let (source, edge) = boundaries.first else { throw error }
                let affinity: TextAffinity
                switch edge { case .before: affinity = .before; case .after, .start: affinity = .after }
                retiredHeads.insert(position.field)
                position = WritingPosition(documentID: documentID, epoch: epoch, field: source, anchor: edge.anchor, affinity: affinity)
                continue
            }
            let keys = projection.visibleKeys(in: field)
            var offset = 0
            guard let anchor = position.anchor else {
                guard position.intraAtomOffset == nil else { throw EditorError.invalidRange }
                if position.affinity == .before { offset = projection.text(in: field).utf16.count }
                else { offset = try projection.startOffset(of: position.field) }
                return ResolvedWritingPosition(address: field.node.textAddress(field.name), offset: offset)
            }
            if let interior = position.intraAtomOffset {
                let value = try atom(anchor), label = plainText([value])
                guard value["type"] != .string("text"), interior > 0, interior < label.utf16.count, writingScalarBoundary(interior, in: label) else { throw EditorError.invalidRange }
                return ResolvedWritingPosition(address: field.node.textAddress(field.name), offset: try projection.offset(of: anchor, affinity: .before) + (keys.contains(anchor) ? interior : 0))
            }
            for key in keys {
                if key == anchor, position.affinity == .before { break }
                offset += plainText([try atom(key)]).utf16.count
                if key == anchor { break }
            }
            // Deleted anchors still own a placement; nearest visible offset is resolved
            // by the full tombstone order, not by a stale field-local atom number.
            if !keys.contains(anchor) { offset = try projection.offset(of: anchor, affinity: position.affinity) }
            return ResolvedWritingPosition(address: field.node.textAddress(field.name), offset: offset)
        }
    }
    @discardableResult public func replaceText(at address: TextAddress, range: Range<Int>, with text: String, marks: [JSONValue]? = nil) throws -> WritingPosition {
        let selected = try selection(address, range), id = try nextID()
        var operations: [WritingOperation] = []
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        let insert = try inserted(text, id: id, field: selected.field, edge: selected.edge, marks: marks ?? selected.marks)
        operations += insert.0
        if !operations.isEmpty { try perform(id, operations) }
        return insert.1 ?? selected.position
    }
    public func format(at address: TextAddress, range: Range<Int>, markType: String, mark: JSONValue?) throws {
        guard ["bold", "italic", "strikethrough", "code", "link"].contains(markType), mark == nil || mark?["type"] == .string(markType) else { throw EditorError.invalidChange }
        if let mark { try Validation.mark(mark) }
        let selected = try selection(address, range)
        if !selected.keys.isEmpty { try perform(nextID(), [.text(.format(keys: selected.keys, type: markType, mark: mark))]) }
    }
    @discardableResult public func splitParagraph(at address: TextAddress, range: Range<Int>, newBlockID: String) throws -> WritingPosition {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        try requireAuthoredType("paragraph")
        let selected = try selection(address, range), source = selected.field.node
        guard selected.field.name == "content", usesRetainedOrigins ? ["paragraph", "heading", "quote", "callout"].contains(structure.nodes[source]?.fields["type"]?.string ?? "") : structure.nodes[source]?.fields["type"] == .string("paragraph") else { throw EditorError.invalidPath }
        let placements = try structure.effectivePlacements()
        guard let parent = placements[source] else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: parent.collection)
        guard let sourceIndex = siblings.firstIndex(of: source) else { throw EditorError.invalidPath }
        let nextSibling = sourceIndex + 1 < siblings.count ? siblings[sourceIndex + 1] : nil
        let id = try nextID(), creation = ElementID(change: id, index: 0), node = NodeID.inserted(creation: creation, path: [])
        let destination = WritingField(node: node, name: "content")
        let value: JSONValue = .object(["id": .string(newBlockID), "type": .string("paragraph"), "content": .array([])])
        var operations = try retainedRoleOperations(for: [source])
        operations.append(.structure(.insertNode(value: value, identity: node, collection: parent.collection, placement: creation, after: parent.id)))
        operations.append(.text(.splitBoundary(source: selected.field, destination: destination, edge: selected.edge, before: nextSibling)))
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        // Observed prefix atoms can themselves be anchored before a suffix atom.
        // Pin those known atoms to the source before moving the suffix, so native
        // committed composition does not follow its old anchor into the new field.
        if usesRetainedOrigins {
            let prefix = try selection(address, 0..<range.lowerBound).keys
            if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: selected.field, edge: .start))) }
        }
        let suffix = try selection(address, range.upperBound..<projection.text(in: selected.field).utf16.count).keys
        if !suffix.isEmpty { operations.append(.text(.transfer(keys: suffix, destination: destination, edge: .start))) }
        try perform(id, operations)
        return WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: suffix.first, affinity: suffix.isEmpty ? .after : .before)
    }
    @discardableResult public func mergeParagraphs(left: NodeID, right: NodeID) throws -> WritingPosition {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        guard left != right, structure.nodes[left]?.fields["type"] == .string("paragraph"), structure.nodes[right]?.fields["type"] == .string("paragraph"),
              Set(structure.nodes[right]!.fields.keys).isSubset(of: ["id", "type", "content"]) else { throw EditorError.invalidPath }
        let placements = try structure.effectivePlacements()
        guard let parent = placements[left], placements[right]?.collection == parent.collection else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: parent.collection)
        guard let index = siblings.firstIndex(of: left), index + 1 < siblings.count, siblings[index + 1] == right else { throw EditorError.invalidPath }
        let destination = WritingField(node: left, name: "content"), source = WritingField(node: right, name: "content")
        let anchor = projection.visibleKeys(in: destination).last
        try perform(nextID(), retainedRoleOperations(for: [left, right]) + [.text(.join(source: source, destination: destination, edge: anchor.map(WritingEdge.after) ?? .start))])
        return WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: anchor, affinity: .after)
    }
    /// Update scalar leaf metadata without replacing shared text or collections.
    /// Conversion attributes use convertBlock; identity and document shape are immutable here.
    public func setNodeField(_ identity: NodeID, path: [String], value: JSONValue) throws {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        let protected = Set(["id", "type", "content", "summary", "caption", "code", "expression", "children", "items", "rows", "cells"])
        guard !path.isEmpty, path.count <= 100, !path.contains(where: { protected.contains($0) }),
              value.array == nil, value.object == nil,
              path.count != 1 || !["style", "level", "variant", "language"].contains(path[0]) else { throw EditorError.invalidPath }
        _ = try structure.address(of: identity)
        let previous = structure.nodes[identity].map { JSONValue.object($0.fields).value(at: path) } ?? nil
        guard previous?.array == nil, previous?.object == nil else { throw EditorError.invalidPath }
        try perform(nextID(), retainedRoleOperations(for: [identity]) + [.structure(.setNodeField(identity: identity, path: path, value: value))])
    }
    public func selectedText(at address: TextAddress, range: Range<Int>) throws -> WritingTextRange {
        // Validate atomic references as well as Unicode scalar boundaries.
        _ = try selection(address, range)
        let start = try position(at: address, offset: range.lowerBound,
                                 affinity: range.isEmpty && range.lowerBound == text(at: address).utf16.count ? .after : .before)
        // A field-end sentinel stays with that field after split. Anchor nonempty
        // ends to their last selected atom so the retained range follows its suffix.
        let end = range.isEmpty ? start : try position(at: address, offset: range.upperBound, affinity: .after)
        return WritingTextRange(start: start, end: end)
    }
    /// Capture a forward or backward range in visible document order, including
    /// across nested collections. Boundary ancestors contribute only their own
    /// text; whole intervening subtrees are selected once.
    public func selection(from anchor: WritingPosition, to focus: WritingPosition) throws -> WritingSelection {
        let first = try resolve(anchor), last = try resolve(focus)
        let firstField = try field(first.address), lastField = try field(last.address)
        if firstField == lastField {
            return try WritingSelection(text: [selectedText(at: first.address, range: min(first.offset, last.offset)..<max(first.offset, last.offset))])
        }
        var ordered: [NodeID] = [], stack = Array(try structure.visibleOrder(in: .root).reversed())
        while let node = stack.popLast() {
            ordered.append(node)
            guard let value = structure.nodes[node] else { throw EditorError.invalidPath }
            for name in StructuralState.collectionFields(value.kind, value.fields).keys.sorted().reversed() {
                stack += try structure.visibleOrder(in: NodeCollection(owner: node, field: name)).reversed()
            }
        }
        guard let firstIndex = ordered.firstIndex(of: firstField.node), let lastIndex = ordered.firstIndex(of: lastField.node), firstIndex != lastIndex else { throw EditorError.invalidRange }
        let lower = firstIndex < lastIndex ? first : last, upper = firstIndex < lastIndex ? last : first
        let endNode = firstIndex < lastIndex ? lastField.node : firstField.node
        let startIndex = min(firstIndex, lastIndex), endIndex = max(firstIndex, lastIndex)
        var ranges = [try selectedText(at: lower.address, range: lower.offset..<text(at: lower.address).utf16.count)]
        var nodes: [NodeID] = [], covered = Set<NodeID>()
        for node in ordered[(startIndex + 1)..<endIndex] where !covered.contains(node) {
            let descendants = Set(try structure.descendants(of: node))
            if descendants.contains(endNode) {
                guard let value = structure.nodes[node] else { throw EditorError.invalidPath }
                for name in writingFields(value) {
                    let address = node.textAddress(name)
                    ranges.append(try selectedText(at: address, range: 0..<text(at: address).utf16.count))
                }
            } else { nodes.append(node); covered.formUnion(descendants) }
        }
        ranges.append(try selectedText(at: upper.address, range: 0..<upper.offset))
        return WritingSelection(nodes: nodes, text: ranges)
    }
    public func copy(_ input: WritingSelection) throws -> WritingCopy {
        let selected = try normalizedSelection(input)
        let parts = try selectedParts(selected)
        let values = try selected.nodes.map { identity -> JSONValue in
            let address = try structure.address(of: identity)
            guard let value = document.blocks.first(where: { $0.id == address.blockID })?.value(at: address.path) else { throw EditorError.invalidPath }
            return value
        }
        return try WritingCopy(nodes: values, text: parts.map { try $0.map { try atom($0) } })
    }
    /// Unlike the legacy copy shape, this preserves interleaving of partial
    /// fields and whole subtrees in current visible document order.
    public func copyClipboard(_ input: WritingSelection) throws -> WritingClipboard {
        let selected = try normalizedSelection(input), keys = try selectedParts(selected)
        var ordered: [NodeID] = [], stack = Array(try structure.visibleOrder(in: .root).reversed())
        while let identity = stack.popLast() {
            ordered.append(identity)
            guard let node = structure.nodes[identity] else { throw EditorError.invalidPath }
            for name in StructuralState.collectionFields(node.kind, node.fields).keys.sorted().reversed() {
                stack += try structure.visibleOrder(in: NodeCollection(owner: identity, field: name)).reversed()
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        var parts: [(node: Int, field: Int, offset: Int, part: WritingClipboardPart)] = []
        for identity in selected.nodes {
            let address = try structure.address(of: identity)
            guard let value = document.blocks.first(where: { $0.id == address.blockID })?.value(at: address.path),
                  let node = structure.nodes[identity], let index = rank[identity] else { throw EditorError.invalidPath }
            parts.append((index, -1, 0, .node(value: value, kind: node.kind.rawValue)))
        }
        for (span, atoms) in zip(selected.text, keys) {
            let start = try resolve(span.start), owner = try field(start.address)
            guard let node = structure.nodes[owner.node], let index = rank[owner.node],
                  let fieldIndex = writingFields(node).firstIndex(of: owner.name) else { throw EditorError.invalidPath }
            parts.append((index, fieldIndex, start.offset, .inline(try atoms.map { try atom($0) })))
        }
        parts.sort { ($0.node, $0.field, $0.offset) < ($1.node, $1.field, $1.offset) }
        return WritingClipboard(parts: parts.map(\.part))
    }
    /// A rich field replacement is exactly one local-author transaction. Raw
    /// formats are normalized by adapters before entering this inert contract.
    @discardableResult public func pasteInline(_ clipboard: WritingClipboard, replacing range: WritingTextRange, policy: WritingPastePolicy = WritingPastePolicy()) throws -> WritingPosition {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        try clipboard.validate(policy: policy, hostBlockTypes: allowedBlockTypes)
        guard clipboard.parts.count == 1, case .inline(let values) = clipboard.parts[0] else { throw EditorError.invalidRange }
        let start = try resolve(range.start), end = try resolve(range.end)
        guard start.address == end.address else { throw EditorError.invalidRange }
        let selected = try selection(start.address, min(start.offset, end.offset)..<max(start.offset, end.offset))
        if selected.field.name == "code" || selected.field.name == "expression" {
            guard values.allSatisfy({ $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty &&
                Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"]) }) else { throw EditorError.invalidChange }
        }
        let id = try nextID()
        var operations: [WritingOperation] = [], edge = selected.edge, last: WritingAtomKey?, index = 0
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        for value in values {
            let atoms: [JSONValue]
            if value["type"] == .string("text") {
                atoms = (value["text"]?.string ?? "").unicodeScalars.map { scalar in
                    var fields = value.object!; fields["text"] = .string(String(scalar)); return .object(fields)
                }
            } else {
                guard !plainText([value]).isEmpty else { throw EditorError.invalidChange }
                atoms = [value]
            }
            for atom in atoms {
                let key = WritingAtomKey(origin: selected.field, element: ElementID(change: id, index: index))
                index += 1
                let route = edge.anchor.map(WritingRoute.follow) ?? .field(selected.field)
                operations.append(.text(.insert(WritingAtomSeed(key: key, node: atom, edge: edge, route: route))))
                edge = .after(key); last = key
            }
        }
        if !operations.isEmpty { try perform(id, operations) }
        return last.map { WritingPosition(documentID: documentID, epoch: epoch, field: selected.field, anchor: $0, affinity: .after) } ?? selected.position
    }
    /// Paste complete schema nodes or copied partial fields at a collection
    /// boundary. Fresh labels are generated only for schema identities; opaque
    /// consumer/reference metadata is retained. No existing array is replaced.
    @discardableResult public func pasteCollection(_ clipboard: WritingClipboard, into collection: NodeCollection, after: NodeID? = nil, policy: WritingPastePolicy = WritingPastePolicy()) throws -> WritingSelection {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        try clipboard.validate(policy: policy, hostBlockTypes: allowedBlockTypes)
        let kind = try structure.kind(in: collection)
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        var values: [JSONValue] = []
        for part in clipboard.parts {
            switch part {
            case .node(let value, let sourceKind):
                guard sourceKind == kind.rawValue else { throw EditorError.invalidPath }
                values.append(value)
            case .inline(let nodes):
                guard kind == .block else { throw EditorError.invalidPath }
                try requireAuthoredType("paragraph")
                guard policy.allowedBlockTypes?.contains("paragraph") ?? true else { throw EditorError.restrictedBlock("paragraph") }
                values.append(.object(["id": .string("clipboard"), "type": .string("paragraph"), "content": .array(nodes)]))
            }
        }
        let id = try nextID()
        var reserved = Set(structure.nodes.values.map(\.label)), serial = 0
        func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
            guard var fields = value.object else { throw EditorError.invalidPath }
            var label: String
            repeat { serial += 1; label = "paste-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (field, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[field]?.array { fields[field] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        var edge = try selectionPlacement(after, in: collection), identities: [NodeID] = []
        var operations = try retainedRoleOperations(for: [after].compactMap { $0 })
        for (index, value) in values.enumerated() {
            let value = try fresh(value, kind: kind)
            try validateNode(value, kind: kind)
            let placement = ElementID(change: id, index: index), identity = NodeID.inserted(creation: placement, path: [])
            identities.append(identity)
            operations.append(.structure(.insertNode(value: value, identity: identity, collection: collection, placement: placement, after: edge)))
            edge = .edit(placement)
        }
        try perform(id, operations)
        return WritingSelection(nodes: identities)
    }
    /// A mixed range deletion is one transaction. Only observed atoms and nodes
    /// are removed; undo retains independent remote writes in surviving origins.
    @discardableResult public func delete(_ input: WritingSelection) throws -> WritingSelection {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        let selected = try normalizedSelection(input)
        let parts = try selectedParts(selected)
        var operations: [WritingOperation] = parts.filter { !$0.isEmpty }.map { .text(.delete(keys: $0)) }
        let nodes = try selected.nodes.flatMap { try structure.descendants(of: $0) }
        if !nodes.isEmpty { operations.append(.structure(.deleteNodes(identities: nodes))) }
        if !operations.isEmpty { try perform(nextID(), operations) }
        return WritingSelection(text: input.text.map { WritingTextRange(start: $0.start, end: $0.start) })
    }
    /// Move a whole-node range without changing any origin identity.
    @discardableResult public func move(_ selected: WritingSelection, into collection: NodeCollection, after: NodeID? = nil) throws -> WritingSelection {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        _ = try selectedParts(selected)
        guard selected.text.isEmpty, !selected.nodes.isEmpty, after.map({ !selected.nodes.contains($0) }) ?? true else { throw EditorError.invalidRange }
        let kind = try structure.kind(in: collection), placements = try structure.effectivePlacements()
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        let siblings = try structure.visibleOrder(in: collection)
        var labels = Set(siblings.filter { !selected.nodes.contains($0) }.compactMap { structure.nodes[$0]?.label })
        var edge = try selectionPlacement(after, in: collection)
        let id = try nextID()
        var operations = try retainedRoleOperations(for: selected.nodes + [after].compactMap { $0 })
        for (index, identity) in selected.nodes.enumerated() {
            guard let node = structure.nodes[identity], node.kind == kind, placements[identity] != nil,
                  labels.insert(node.label).inserted else { throw EditorError.invalidPath }
            if let owner = collection.owner, try structure.descendants(of: identity).contains(owner) { throw EditorError.invalidPath }
            let placement = ElementID(change: id, index: index)
            operations.append(.structure(.moveNode(identity: identity, collection: collection, placement: placement, after: edge)))
            edge = .edit(placement)
        }
        try perform(id, operations)
        return selected
    }
    /// Fresh scoped labels are generated only for schema-defined nodes. Consumer
    /// metadata, reference identities and unknown fields are copied unchanged.
    @discardableResult public func duplicate(_ selected: WritingSelection, into collection: NodeCollection, after: NodeID? = nil) throws -> WritingSelection {
        guard !isComposing else { throw WritingSessionError.compositionActive }
        _ = try selectedParts(selected)
        guard selected.text.isEmpty, !selected.nodes.isEmpty else { throw EditorError.invalidRange }
        let kind = try structure.kind(in: collection)
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        let values = try copy(selected).nodes, id = try nextID()
        var edge = try selectionPlacement(after, in: collection), serial = 0
        var reserved = Set(structure.nodes.values.map(\.label))
        func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
            guard var fields = value.object else { throw EditorError.invalidPath }
            // Duplication authors new schema nodes, including nested descendants.
            switch kind {
            case .document, .column: throw EditorError.invalidPath
            case .block:
                guard let type = fields["type"]?.string else { throw EditorError.invalidPath }
                try requireAuthoredType(type)
            case .item: try requireAuthoredType("list")
            case .row, .cell: try requireAuthoredType("table")
            }
            var label: String
            repeat { serial += 1; label = "copy-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (field, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[field]?.array { fields[field] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        var identities: [NodeID] = []
        var operations = try retainedRoleOperations(for: [after].compactMap { $0 })
        for (index, value) in values.enumerated() {
            guard structure.nodes[selected.nodes[index]]?.kind == kind else { throw EditorError.invalidPath }
            let value = try fresh(value, kind: kind)
            try validateNode(value, kind: kind)
            let placement = ElementID(change: id, index: index), identity = NodeID.inserted(creation: placement, path: [])
            identities.append(identity)
            operations.append(.structure(.insertNode(value: value, identity: identity, collection: collection, placement: placement, after: edge)))
            edge = .edit(placement)
        }
        try perform(id, operations)
        return WritingSelection(nodes: identities)
    }
    /// Replace a paragraph range with ordered rich fragments and whole blocks.
    /// Only explicit boundary inline parts are absorbed; whole nodes retain all
    /// their metadata and receive fresh schema identities. One transaction owns
    /// the deletion, imports, text seeds and retained cut boundary.
    @discardableResult public func pasteSelection(_ clipboard: WritingClipboard, replacing range: WritingTextRange,
                                                   policy: WritingPastePolicy = WritingPastePolicy()) throws -> WritingPosition {
        guard protocolVersion == 5 || protocolVersion == 6 else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        try clipboard.validate(policy: policy, hostBlockTypes: allowedBlockTypes)
        var start = try resolve(range.start), end = try resolve(range.end)
        var source = try field(start.address), endpoint = try field(end.address)
        let placements = try structure.effectivePlacements()
        guard let initialParent = placements[source.node], let endParent = placements[endpoint.node] else { throw EditorError.invalidPath }
        if protocolVersion == 6, source != endpoint {
            let single = clipboard.parts.count == 1 && { if case .inline = clipboard.parts[0] { return true }; return false }()
            let a = structure.nodes[source.node], b = structure.nodes[endpoint.node]
            let plainEnding = b.map { Set($0.fields.keys).isSubset(of: ["id", "type", "content"]) && $0.collections.isEmpty } ?? false
            if initialParent.collection != endParent.collection ||
                (single && !plainEnding) || source.name != "content" || endpoint.name != "content" ||
                a?.kind != .block || b?.kind != .block || a?.fields["type"] != .string("paragraph") || b?.fields["type"] != .string("paragraph") {
                return try pasteHierarchical(clipboard, replacing: range, policy: policy)
            }
        }
        guard initialParent.collection == endParent.collection else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: initialParent.collection)
        guard let initialIndex = siblings.firstIndex(of: source.node), let endIndex = siblings.firstIndex(of: endpoint.node) else { throw EditorError.invalidPath }
        if initialIndex > endIndex { swap(&start, &end); swap(&source, &endpoint) }
        let crossBlock = source != endpoint
        if !crossBlock, clipboard.parts.count == 1, case .inline = clipboard.parts[0] {
            return try pasteInline(clipboard, replacing: range, policy: policy)
        }
        if !crossBlock, clipboard.parts.allSatisfy({ if case .node = $0 { return true }; return false }) {
            return try pasteBlocks(clipboard, replacing: range, policy: policy)
        }
        guard source.name == "content", endpoint.name == "content",
              let original = structure.nodes[source.node], original.kind == .block,
              original.fields["type"] == .string("paragraph"),
              let ending = structure.nodes[endpoint.node], ending.kind == .block,
              ending.fields["type"] == .string("paragraph") else { throw EditorError.invalidPath }
        // A lossless join can retire only a plain paragraph endpoint. Existing
        // metadata/child namespaces must not be discarded or merged implicitly.
        if crossBlock, protocolVersion != 6 || (clipboard.parts.count == 1 && { if case .inline = clipboard.parts[0] { return true }; return false }()) {
            guard Set(ending.fields.keys).isSubset(of: ["id", "type", "content"]), ending.collections.isEmpty else { throw EditorError.invalidPath }
        }
        let lower = crossBlock ? start.offset : min(start.offset, end.offset)
        let upper = crossBlock ? end.offset : max(start.offset, end.offset)
        let sourceLength = projection.text(in: source).utf16.count
        let selected = try selection(start.address, lower..<(crossBlock ? sourceLength : upper))
        let endpointSelection = crossBlock ? try selection(end.address, 0..<upper).keys : []
        guard let parent = placements[source.node], let sourceIndex = siblings.firstIndex(of: source.node),
              let endpointIndex = siblings.firstIndex(of: endpoint.node) else { throw EditorError.invalidPath }
        let neighborIndex = crossBlock && protocolVersion == 6 ? endpointIndex + 1 : sourceIndex + 1
        let before = neighborIndex < siblings.count ? siblings[neighborIndex] : nil
        let middleNodes = crossBlock ? Array(siblings[(sourceIndex + 1)..<endpointIndex]) : []
        let singleInline = clipboard.parts.count == 1 && { if case .inline = clipboard.parts[0] { return true }; return false }()
        var parts = clipboard.parts, leading: [JSONValue] = [], trailing: [JSONValue] = []
        let hasLeadingInline: Bool
        if case .inline(let values)? = parts.first { hasLeadingInline = true; leading = values; parts.removeFirst() }
        else { hasLeadingInline = false }
        if case .inline(let values)? = parts.last { trailing = values; parts.removeLast() }
        let values = try parts.map { part -> JSONValue in
            switch part {
            case .node(let value, let kind):
                guard kind == "block" else { throw EditorError.invalidPath }; return value
            case .inline(let values):
                return .object(["id": .string("clipboard"), "type": .string("paragraph"), "content": .array(values)])
            }
        }
        // Inline parts are distinct fields. Even two adjacent boundary parts
        // represent a break; they are never silently concatenated into one field.
        let authorsParagraph = parts.contains { if case .inline = $0 { return true }; return false }
            || (!singleInline && (!crossBlock || protocolVersion != 6) && (lower > 0 || hasLeadingInline))
        if authorsParagraph {
            try requireAuthoredType("paragraph")
            guard policy.allowedBlockTypes?.contains("paragraph") ?? true else { throw EditorError.restrictedBlock("paragraph") }
        }
        let id = try nextID()
        var index = 0, serial = 0, reserved = Set(structure.nodes.values.map(\.label))
        var operations = try retainedRoleOperations(for: crossBlock ? [source.node, endpoint.node] : [source.node])
        func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
            guard var fields = value.object else { throw EditorError.invalidPath }
            var label: String
            repeat { serial += 1; label = "paste-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (name, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[name]?.array { fields[name] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        func appendInline(_ values: [JSONValue], field: WritingField, edge initial: WritingEdge) throws -> [WritingAtomKey] {
            var edge = initial, inserted: [WritingAtomKey] = []
            for value in values {
                let atoms: [JSONValue]
                if value["type"] == .string("text") {
                    atoms = (value["text"]?.string ?? "").unicodeScalars.map { scalar in
                        var fields = value.object!; fields["text"] = .string(String(scalar)); return .object(fields)
                    }
                } else {
                    guard !plainText([value]).isEmpty else { throw EditorError.invalidChange }; atoms = [value]
                }
                for atom in atoms {
                    let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index)); index += 1
                    operations.append(.text(.insert(WritingAtomSeed(key: key, node: atom, edge: edge, route: edge.anchor.map(WritingRoute.follow) ?? .field(field)))))
                    inserted.append(key); edge = .after(key)
                }
            }
            return inserted
        }
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        if !endpointSelection.isEmpty { operations.append(.text(.delete(keys: endpointSelection))) }
        let deleted = try middleNodes.flatMap { try structure.descendants(of: $0) }
        if !deleted.isEmpty { operations.append(.structure(.deleteNodes(identities: deleted))) }
        let originalPrefix = try selection(start.address, 0..<lower).keys
        let head = try appendInline(leading, field: source, edge: originalPrefix.last.map(WritingEdge.after) ?? .start)
        let suffix = try selection(end.address, upper..<projection.text(in: endpoint).utf16.count).keys
        if singleInline {
            let edge = head.last.map(WritingEdge.after) ?? originalPrefix.last.map(WritingEdge.after) ?? .start
            operations.append(.text(.join(source: endpoint, destination: source, edge: edge)))
            let caret = head.last.map { WritingPosition(documentID: documentID, epoch: epoch, field: source, anchor: $0, affinity: .after) }
                ?? suffix.first.map { WritingPosition(documentID: documentID, epoch: epoch, field: source, anchor: $0, affinity: .before) }
                ?? WritingPosition(documentID: documentID, epoch: epoch, field: source, anchor: originalPrefix.last, affinity: .after)
            try perform(id, operations)
            return caret
        }
        let retainedEndpoint = crossBlock && protocolVersion == 6 && !singleInline
        let retainPrefix = retainedEndpoint ? (lower > 0 || (hasLeadingInline && !singleInline)) : (lower > 0 || hasLeadingInline)
        var after = retainedEndpoint || retainPrefix ? parent.id : parent.after, members: [NodeID] = []
        for value in values {
            let placement = ElementID(change: id, index: index); index += 1
            let identity = NodeID.inserted(creation: placement, path: [])
            let imported = try fresh(value, kind: .block); try validateNode(imported, kind: .block)
            operations.append(.structure(.insertNode(value: imported, identity: identity, collection: parent.collection, placement: placement, after: after)))
            members.append(identity); after = .edit(placement)
        }
        var destination = source
        var endpointMove: ElementID?
        if retainedEndpoint {
            let placement = ElementID(change: id, index: index); index += 1
            operations.append(.structure(.moveNode(identity: endpoint.node, collection: parent.collection, placement: placement, after: after)))
            endpointMove = placement; members.append(endpoint.node); destination = endpoint
            if !retainPrefix { operations.append(.structure(.deleteNodes(identities: [source.node]))) }
        } else if retainPrefix {
            let placement = ElementID(change: id, index: index); index += 1
            let identity = NodeID.inserted(creation: placement, path: [])
            var tail = original.fields; tail["content"] = .array([])
            let value = try fresh(.object(tail), kind: .block)
            operations.append(.structure(.insertNode(value: value, identity: identity, collection: parent.collection, placement: placement, after: after)))
            members.append(identity); destination = WritingField(node: identity, name: "content")
        }
        let tail = try appendInline(trailing, field: destination,
                                    edge: retainedEndpoint || retainPrefix ? .start : selected.edge)
        if retainedEndpoint {
            guard let endpointMove, let endPlacement = placements[endpoint.node] else { throw EditorError.invalidPath }
            operations.append(.text(.rangeSpliceBoundary(WritingRangeSplice(source: source, destination: destination,
                edge: selected.edge, before: before, members: members, sourcePlacement: parent.id,
                endpointPlacement: endPlacement.id, destinationPlacement: endpointMove,
                endpointKeys: endpointSelection + suffix))))
            let prefix = originalPrefix + head
            if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: source, edge: .start))) }
            if !selected.keys.isEmpty { operations.append(.text(.transfer(keys: selected.keys, destination: destination, edge: tail.last.map(WritingEdge.after) ?? .start))) }
            let endpointKeys = endpointSelection + suffix
            if !endpointKeys.isEmpty {
                operations.append(.text(.transfer(keys: endpointKeys, destination: destination,
                    edge: selected.keys.last.map(WritingEdge.after) ?? tail.last.map(WritingEdge.after) ?? .start)))
            }
        } else if retainPrefix {
            operations.append(.text(.spliceBoundary(source: source, destination: destination, edge: selected.edge, before: before, members: members)))
            let prefix = originalPrefix + head
            if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: source, edge: .start))) }
            // Cross-block source tombstones remain routed with the continuation
            // so unseen peer insertions following them are not abandoned.
            let routed = crossBlock ? selected.keys : suffix
            if !routed.isEmpty { operations.append(.text(.transfer(keys: routed, destination: destination, edge: tail.last.map(WritingEdge.after) ?? .start))) }
        }
        if crossBlock, !retainedEndpoint {
            let boundary = tail.last.map(WritingEdge.after)
                ?? (retainPrefix ? selected.keys.last.map(WritingEdge.after) : nil) ?? .start
            operations.append(.text(.join(source: endpoint, destination: destination, edge: boundary)))
        }
        let caret = tail.last.map { WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: $0, affinity: .after) }
            ?? suffix.first.map { WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: $0, affinity: .before) }
            ?? WritingPosition(documentID: documentID, epoch: epoch, field: destination, affinity: .after)
        try perform(id, operations)
        return caret
    }
    /// Protocol 6 uses the same global range traversal as copy/delete. Boundary
    /// owners remain visible when their schema or metadata cannot be joined.
    private func pasteHierarchical(_ clipboard: WritingClipboard, replacing range: WritingTextRange,
                                   policy: WritingPastePolicy) throws -> WritingPosition {
        guard protocolVersion == 6 else { throw EditorError.unsupportedVersion(protocolVersion) }
        let selected = try selection(from: range.start, to: range.end)
        guard let first = selected.text.first, let last = selected.text.last else { throw EditorError.invalidRange }
        let start = try resolve(first.start), end = try resolve(last.end)
        let source = try field(start.address), endpoint = try field(end.address)
        guard source != endpoint, let original = structure.nodes[source.node], let ending = structure.nodes[endpoint.node] else { throw EditorError.invalidPath }
        let placements = try structure.effectivePlacements()
        guard let parent = placements[source.node] else { throw EditorError.invalidPath }
        var parts = clipboard.parts, leading: [JSONValue] = [], trailing: [JSONValue] = []
        let leadingPresent: Bool
        if case .inline(let values)? = parts.first { leadingPresent = true; leading = values; parts.removeFirst() }
        else { leadingPresent = false }
        let singleInline = clipboard.parts.count == 1 && leadingPresent
        if case .inline(let values)? = parts.last { trailing = values; parts.removeLast() }
        let endpointDescendants = Set(try structure.descendants(of: endpoint.node))
        let sourceDescendants = Set(try structure.descendants(of: source.node))
        let partsKind = parts.compactMap { part -> NodeKind? in
            if case .node(_, let kind) = part { return NodeKind(rawValue: kind) }; return nil
        }.first ?? original.kind
        var collection = parent.collection, after: NodePlacementID? = parent.id
        if sourceDescendants.contains(endpoint.node) {
            let slots = StructuralState.collectionFields(original.kind, original.fields).filter { $0.value == partsKind }.keys.sorted()
            if let slot = slots.first { collection = NodeCollection(owner: source.node, field: slot); after = nil }
            else if !parts.isEmpty { throw EditorError.invalidPath }
        }
        let kind = try structure.kind(in: collection)
        let siblings = try structure.visibleOrder(in: collection)
        let before: NodeID?
        if after == nil { before = siblings.first }
        else if let index = siblings.firstIndex(of: source.node), index + 1 < siblings.count { before = siblings[index + 1] }
        else { before = nil }
        func inlineValue(_ values: [JSONValue]) throws -> JSONValue {
            switch kind {
            case .document, .column: throw EditorError.invalidPath
            case .block:
                try requireAuthoredType("paragraph")
                guard policy.allowedBlockTypes?.contains("paragraph") ?? true else { throw EditorError.restrictedBlock("paragraph") }
                return .object(["id": .string("clipboard"), "type": .string("paragraph"), "content": .array(values)])
            case .item: return .object(["id": .string("clipboard"), "content": .array(values)])
            case .cell: return .object(["id": .string("clipboard"), "content": .array(values)])
            case .row: throw EditorError.invalidPath
            }
        }
        let values = try parts.map { part -> JSONValue in
            switch part {
            case .node(let value, let name): guard name == kind.rawValue else { throw EditorError.invalidPath }; return value
            case .inline(let values): return try inlineValue(values)
            }
        }
        for value in values {
            try validateNode(value, kind: kind)
            try WritingClipboard(parts: [.node(value: value, kind: kind.rawValue)]).validate(policy: policy, hostBlockTypes: allowedBlockTypes)
        }
        func validateFieldImport(_ values: [JSONValue], field: WritingField) throws {
            if field.name == "code" || field.name == "expression" {
                guard values.allSatisfy({ $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty &&
                    Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"]) }) else { throw EditorError.invalidChange }
            }
        }
        try validateFieldImport(leading, field: source); try validateFieldImport(trailing, field: endpoint)
        let spans = try selectedParts(selected)
        let deletedNodes = try selected.nodes.flatMap { try structure.descendants(of: $0) }
        guard Set(deletedNodes).isDisjoint(with: [source.node, endpoint.node]),
              !deletedNodes.contains(where: { sourceDescendants.contains($0) && endpointDescendants.contains($0) }) else { throw EditorError.invalidPath }
        let id = try nextID()
        var operations = try retainedRoleOperations(for: [source.node, endpoint.node])
        for keys in spans where !keys.isEmpty { operations.append(.text(.delete(keys: keys))) }
        if !deletedNodes.isEmpty { operations.append(.structure(.deleteNodes(identities: deletedNodes))) }
        var index = 0, serial = 0, reserved = Set(structure.nodes.values.map(\.label))
        func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
            guard var fields = value.object else { throw EditorError.invalidPath }
            var label: String
            repeat { serial += 1; label = "paste-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (field, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[field]?.array { fields[field] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        func append(_ values: [JSONValue], field: WritingField, edge initial: WritingEdge) throws -> [WritingAtomKey] {
            var edge = initial, keys: [WritingAtomKey] = []
            for value in values {
                let atoms: [JSONValue]
                if value["type"] == .string("text") {
                    atoms = (value["text"]?.string ?? "").unicodeScalars.map { scalar in
                        var fields = value.object!; fields["text"] = .string(String(scalar)); return .object(fields)
                    }
                } else { atoms = [value] }
                for value in atoms {
                    let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index)); index += 1
                    operations.append(.text(.insert(WritingAtomSeed(key: key, node: value, edge: edge,
                        route: edge.anchor.map(WritingRoute.follow) ?? .field(field)))))
                    keys.append(key); edge = .after(key)
                }
            }
            return keys
        }
        let prefix = try selection(start.address, 0..<start.offset).keys
        let head = try append(leading, field: source, edge: prefix.last.map(WritingEdge.after) ?? .start)
        if prefix.isEmpty, !head.isEmpty, let first = projection.visibleKeys(in: source).first {
            operations.append(.text(.transfer(keys: head, destination: source, edge: .before(first))))
        }
        var members: [NodeID] = [], previous = after
        for value in values {
            let placement = ElementID(change: id, index: index); index += 1
            let identity = NodeID.inserted(creation: placement, path: [])
            operations.append(.structure(.insertNode(value: try fresh(value, kind: kind), identity: identity,
                collection: collection, placement: placement, after: previous)))
            members.append(identity); previous = .edit(placement)
        }
        // The suffix owner never moves. Fix pasted trailing atoms to its field
        // before its retained first atom, rather than following a peer's cut.
        let endpointKeys = projection.visibleKeys(in: endpoint)
        let tail = try append(trailing, field: endpoint, edge: .start)
        if !tail.isEmpty, let first = endpointKeys.first {
            operations.append(.text(.transfer(keys: tail, destination: endpoint, edge: .before(first))))
        }
        if !members.isEmpty {
            let sourceKeys = try selection(start.address, start.offset..<projection.text(in: source).utf16.count).keys
            let edge = try head.last.map(WritingEdge.after) ?? selection(start.address, start.offset..<start.offset).edge
            operations.append(.text(.importBoundary(WritingImportBoundary(source: source, edge: edge,
                sourcePlacement: parent.id, collection: collection, after: after, before: before, members: members, sourceKeys: sourceKeys))))
        }
        // A plain fully selected shell can retire; metadata-bearing owners and
        // boundary ancestors stay separately visible, even with empty text.
        if start.offset == 0, !leadingPresent, !sourceDescendants.contains(endpoint.node),
           original.kind == .block, Set(original.fields.keys).isSubset(of: ["id", "type", "content"]), original.collections.isEmpty {
            operations.append(.structure(.deleteNodes(identities: [source.node])))
        }
        let caret: WritingPosition
        if singleInline {
            caret = WritingPosition(documentID: documentID, epoch: epoch, field: source,
                anchor: head.last ?? prefix.last, affinity: .after)
        } else if let last = tail.last {
            caret = WritingPosition(documentID: documentID, epoch: epoch, field: endpoint, anchor: last, affinity: .after)
        } else {
            let suffix = try selection(end.address, end.offset..<projection.text(in: endpoint).utf16.count).keys
            caret = WritingPosition(documentID: documentID, epoch: epoch, field: endpoint, anchor: suffix.first,
                affinity: suffix.isEmpty ? .after : .before)
        }
        if !operations.isEmpty { try perform(id, operations) }
        _ = ending // The unchanged owner carries its complete metadata namespace.
        return caret
    }
    /// Replace a range in a paragraph with complete imported blocks. Imported
    /// nodes remain complete; inline absorption and cross-block ranges use a
    /// separate planner. Protocol 5 records the complete cut group explicitly.
    @discardableResult public func pasteBlocks(_ clipboard: WritingClipboard, replacing range: WritingTextRange,
                                                policy: WritingPastePolicy = WritingPastePolicy()) throws -> WritingPosition {
        guard protocolVersion == 5 || protocolVersion == 6 else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        try clipboard.validate(policy: policy, hostBlockTypes: allowedBlockTypes)
        let start = try resolve(range.start), end = try resolve(range.end)
        let source = try field(start.address)
        guard source == (try field(end.address)), source.name == "content",
              let original = structure.nodes[source.node], original.kind == .block,
              original.fields["type"] == .string("paragraph") else { throw EditorError.invalidPath }
        let lower = min(start.offset, end.offset), upper = max(start.offset, end.offset)
        let selected = try selection(start.address, lower..<upper)
        let placements = try structure.effectivePlacements()
        guard let parent = placements[source.node] else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: parent.collection)
        guard let sourceIndex = siblings.firstIndex(of: source.node) else { throw EditorError.invalidPath }
        let before = sourceIndex + 1 < siblings.count ? siblings[sourceIndex + 1] : nil
        let values = try clipboard.parts.map { part -> JSONValue in
            guard case .node(let value, let kind) = part, kind == "block" else { throw EditorError.invalidPath }
            return value
        }
        let id = try nextID()
        var serial = 0, reserved = Set(structure.nodes.values.map(\.label))
        func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
            guard var fields = value.object else { throw EditorError.invalidPath }
            var label: String
            repeat { serial += 1; label = "paste-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (name, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[name]?.array { fields[name] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        var operations = try retainedRoleOperations(for: [source.node]), members: [NodeID] = []
        // Offset zero retains the original suffix owner and its opaque metadata.
        // Positive offsets retain the original prefix and create a fresh tail.
        var after = lower == 0 ? parent.after : parent.id
        for (index, value) in values.enumerated() {
            let placement = ElementID(change: id, index: index), identity = NodeID.inserted(creation: placement, path: [])
            let imported = try fresh(value, kind: .block)
            try validateNode(imported, kind: .block)
            operations.append(.structure(.insertNode(value: imported, identity: identity, collection: parent.collection, placement: placement, after: after)))
            members.append(identity); after = .edit(placement)
        }
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        var destination = source, suffix: [WritingAtomKey] = []
        if lower > 0 {
            try requireAuthoredType("paragraph")
            guard policy.allowedBlockTypes?.contains("paragraph") ?? true else { throw EditorError.restrictedBlock("paragraph") }
            let placement = ElementID(change: id, index: values.count), identity = NodeID.inserted(creation: placement, path: [])
            var tail = original.fields
            tail["content"] = .array([])
            let tailValue = try fresh(.object(tail), kind: .block)
            operations.append(.structure(.insertNode(value: tailValue, identity: identity, collection: parent.collection, placement: placement, after: after)))
            members.append(identity); destination = WritingField(node: identity, name: "content")
            operations.append(.text(.spliceBoundary(source: source, destination: destination, edge: selected.edge, before: before, members: members)))
            let prefix = try selection(start.address, 0..<lower).keys
            if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: source, edge: .start))) }
            suffix = try selection(start.address, upper..<projection.text(in: source).utf16.count).keys
            if !suffix.isEmpty { operations.append(.text(.transfer(keys: suffix, destination: destination, edge: .start))) }
        }
        try perform(id, operations)
        return WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: suffix.first,
                               affinity: suffix.isEmpty ? .after : .before)
    }
    /// Read stable identities from a schema-defined collection. Paths are used
    /// only for lookup; consumers keep these identities across later moves.
    public func collectionNodes(in collection: NodeCollection) throws -> [NodeID] {
        _ = try structure.kind(in: collection)
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        return try structure.visibleOrder(in: collection)
    }
    /// Create rows, cells, toggle children or list items as one author transaction.
    /// Collection values are inserted individually; existing arrays are never
    /// replaced. Schema IDs remain scoped and unknown payload stays untouched.
    @discardableResult public func insertCollectionNodes(_ values: [JSONValue], into collection: NodeCollection, after: NodeID? = nil) throws -> WritingSelection {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        guard !values.isEmpty, values.count <= 100_000 else { throw EditorError.invalidRange }
        let kind = try structure.kind(in: collection)
        let siblings = try collectionNodes(in: collection)
        var labels = Set(siblings.compactMap { structure.nodes[$0]?.label })
        func authored(_ value: JSONValue, kind: NodeKind) throws {
            guard let fields = value.object else { throw EditorError.invalidPath }
            switch kind {
            case .document, .column: throw EditorError.invalidPath
            case .block:
                guard let type = fields["type"]?.string else { throw EditorError.invalidPath }
                try requireAuthoredType(type)
            case .item: try requireAuthoredType("list")
            case .row, .cell: try requireAuthoredType("table")
            }
            for (name, childKind) in StructuralState.collectionFields(kind, fields) {
                for child in fields[name]?.array ?? [] { try authored(child, kind: childKind) }
            }
        }
        for value in values {
            try validateNode(value, kind: kind)
            try authored(value, kind: kind)
            guard let label = value["id"]?.string, labels.insert(label).inserted else { throw EditorError.invalidPath }
        }
        var edge = try selectionPlacement(after, in: collection)
        let id = try nextID()
        var identities: [NodeID] = []
        var operations = try retainedRoleOperations(for: [after].compactMap { $0 })
        for (index, value) in values.enumerated() {
            let placement = ElementID(change: id, index: index)
            let identity = NodeID.inserted(creation: placement, path: [])
            identities.append(identity)
            operations.append(.structure(.insertNode(value: value, identity: identity, collection: collection, placement: placement, after: edge)))
            edge = .edit(placement)
        }
        try perform(id, operations)
        return WritingSelection(nodes: identities)
    }
    private func selectionPlacement(_ node: NodeID?, in collection: NodeCollection) throws -> NodePlacementID? {
        guard let node else { return nil }
        guard try structure.visibleOrder(in: collection).contains(node), let placement = try structure.effectivePlacements()[node], placement.collection == collection else { throw EditorError.invalidPath }
        return placement.id
    }
    private func normalizedSelection(_ selected: WritingSelection) throws -> WritingSelection {
        guard selected.nodes.count + selected.text.count <= 100_000 else { throw EditorError.invalidRange }
        var nodes = selected.nodes, text: [WritingTextRange] = []
        for span in selected.text {
            let expanded = try selection(from: span.start, to: span.end)
            nodes += expanded.nodes; text += expanded.text
            guard nodes.count + text.count <= 100_000 else { throw EditorError.invalidRange }
        }
        return WritingSelection(nodes: nodes, text: text)
    }
    private func selectedParts(_ selected: WritingSelection) throws -> [[WritingAtomKey]] {
        guard selected.nodes.count + selected.text.count <= 100_000, Set(selected.nodes).count == selected.nodes.count else { throw EditorError.invalidRange }
        var covered = Set<NodeID>()
        for node in selected.nodes {
            _ = try structure.address(of: node)
            let descendants = Set(try structure.descendants(of: node))
            guard covered.isDisjoint(with: descendants) else { throw EditorError.invalidRange }
            covered.formUnion(descendants)
        }
        var seen = Set<WritingAtomKey>()
        return try selected.text.map { span in
            let start = try resolve(span.start), end = try resolve(span.end)
            guard start.address == end.address, start.offset <= end.offset,
                  !covered.contains(try field(start.address).node) else { throw EditorError.invalidRange }
            let keys = try selection(start.address, start.offset..<end.offset).keys
            guard seen.isDisjoint(with: keys) else { throw EditorError.invalidRange }
            seen.formUnion(keys)
            return keys
        }
    }
    public func undo() throws {
        if usesRetainedOrigins {
            guard !preparingReceive else { throw EditorError.invalidChange }
            if let recovery = mergeRecovery { throw WritingSessionError.recoveryRequired(recovery) }
        }
        guard let target = undoStack.last else { return }
        try toggle(target, false)
    }
    public func redo() throws {
        if usesRetainedOrigins {
            guard !preparingReceive else { throw EditorError.invalidChange }
            if let recovery = mergeRecovery { throw WritingSessionError.recoveryRequired(recovery) }
        }
        guard let target = redoStack.last else { return }
        try toggle(target, true)
    }
    private func perform(_ id: ChangeID, _ operations: [WritingOperation]) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        guard mergeRecovery == nil else { throw WritingSessionError.recoveryRequired(mergeRecovery!) }
        let change = WritingChange(id: id, body: .edit(operations), observed: usesRetainedOrigins ? observedFrontier(log) : nil); var candidate = log; candidate[id] = change
        try capacity(candidate); let result = try replay(candidate)
        undoStack.append(id); redoStack.removeAll(); accept(candidate, result, change: change)
    }
    private func toggle(_ target: ChangeID, _ active: Bool) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        guard mergeRecovery == nil else { throw WritingSessionError.recoveryRequired(mergeRecovery!) }
        let change = WritingChange(id: try nextID(), body: .setActive(target: target, active: active), observed: usesRetainedOrigins ? observedFrontier(log) : nil); var candidate = log; candidate[change.id] = change
        try capacity(candidate)
        let result: (StructuralState, WritingProjection, Document)
        do { result = try replay(candidate) }
        catch let error as WritingProjectionError where usesRetainedOrigins {
            try retain(candidate, reason: error == .missingAtom ? .schemaConstraint : .identityConflict)
        } catch EditorError.invalidDocument where usesRetainedOrigins {
            try retain(candidate, reason: .schemaConstraint)
        } catch EditorError.structuralConflict where usesRetainedOrigins {
            try retain(candidate, reason: .identityConflict)
        }
        if active { redoStack.removeLast(); undoStack.append(target) }
        else { undoStack.removeLast(); redoStack.append(target) }
        accept(candidate, result, change: change)
    }
    private func accept(_ candidate: [ChangeID: WritingChange], _ result: (StructuralState, WritingProjection, Document), change: WritingChange?, authoredEdit: Bool = false) {
        var winning: [ChangeID: (id: ChangeID, active: Bool)] = [:]
        for incoming in candidate.values {
            if case .setActive(let target, let enabled) = incoming.body,
               winning[target].map({ $0.id < incoming.id }) ?? true { winning[target] = (incoming.id, enabled) }
        }
        for (target, toggle) in winning.sorted(by: { $0.value.id < $1.value.id }) {
            if !toggle.active, let index = undoStack.firstIndex(of: target) { undoStack.remove(at: index); redoStack.append(target) }
            if toggle.active, let index = redoStack.firstIndex(of: target) { redoStack.remove(at: index); undoStack.append(target) }
        }
        if authoredEdit, let change { undoStack.append(change.id); redoStack.removeAll() }
        log = candidate; counter = candidate.keys.map(\.counter).max() ?? counter
        structure = result.0; projection = result.1; document = result.2; mergeRecovery = nil
        onChange?(document, change)
    }
    private func retain(_ candidate: [ChangeID: WritingChange], reason: MergeRecoveryReason) throws -> Never {
        let proposal = WritingRecovery(reason: reason, batch: batch(Array(candidate.values)))
        mergeRecovery = proposal; throw WritingSessionError.recoveryRequired(proposal)
    }
    private func nextID() throws -> ChangeID {
        guard counter < 9_007_199_254_740_990 else { throw EditorError.invalidChange }
        return ChangeID(counter: counter + 1, actor: actorID)
    }
    private func batch(_ changes: [WritingChange]) -> WritingBatch { WritingBatch(documentID: documentID, epoch: epoch, baseline: baseline, changes: changes.sorted { $0.id < $1.id }, version: protocolVersion) }
    private func capacity(_ candidate: [ChangeID: WritingChange]) throws {
        guard candidate.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
        let edits = candidate.values.filter { if case .edit = $0.body { return true }; return false }.map(\.id).sorted()
        guard try canonicalEncoder().encode(batch(Array(candidate.values))).count <= 64_000_000 - 1_024 - canonicalEncoder().encode(edits).count else { throw EditorError.recoveryCapacityExceeded }
    }
    private func field(_ address: TextAddress) throws -> WritingField {
        let owner = try address.identity ?? structure.node(at: NodeAddress(address.blockID, path: Array(address.path.dropLast())))
        _ = try structure.address(of: owner)
        guard let name = address.path.last, ["content", "summary", "caption", "code", "expression"].contains(name), structure.nodes[owner].map({ writingFields($0).contains(name) }) == true else { throw EditorError.invalidPath }
        return WritingField(node: owner, name: name)
    }
    private func atom(_ key: WritingAtomKey) throws -> JSONValue { try projection.value(of: key) }
    private func selection(_ address: TextAddress, _ range: Range<Int>) throws -> (field: WritingField, keys: [WritingAtomKey], edge: WritingEdge, marks: [JSONValue], position: WritingPosition) {
        let field = try field(address), keys = projection.visibleKeys(in: field)
        var offset = 0, selected: [WritingAtomKey] = [], previous: WritingAtomKey?, next: WritingAtomKey?, marks: [JSONValue] = []
        var boundaries: Set<Int> = [0]
        for key in keys {
            let node = try atom(key), length = plainText([node]).utf16.count
            if offset < range.lowerBound { previous = key; marks = node["marks"]?.array ?? [] }
            if offset >= range.lowerBound, next == nil { next = key; if previous == nil { marks = node["marks"]?.array ?? [] } }
            if offset >= range.lowerBound, offset < range.upperBound { selected.append(key) }
            offset += length; boundaries.insert(offset)
        }
        guard range.lowerBound >= 0, boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound) else { throw EditorError.invalidRange }
        // Continue an observed inserted run after its last atom. A new sibling
        // before the same right anchor would sort ahead of the previous run.
        // Preserve baseline-boundary right affinity and exact version-3 wire.
        let edge: WritingEdge
        if usesRetainedOrigins, let previous, previous.element.change.counter > 0 { edge = .after(previous) }
        else { edge = next.map(WritingEdge.before) ?? previous.map(WritingEdge.after) ?? .start }
        return (field, selected, edge, marks, WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: next ?? previous, affinity: next == nil ? .after : .before))
    }
    private func inserted(_ text: String, id: ChangeID, field: WritingField, edge: WritingEdge, marks: [JSONValue]) throws -> ([WritingOperation], WritingPosition?) {
        var operations: [WritingOperation] = [], current = edge, last: WritingAtomKey?
        for (index, scalar) in text.unicodeScalars.enumerated() {
            let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index))
            let route = current.anchor.map(WritingRoute.follow) ?? .field(field)
            operations.append(.text(.insert(WritingAtomSeed(key: key, node: textNode(String(scalar), marks: marks), edge: current, route: route))))
            current = .after(key); last = key
        }
        return (operations, last.map { WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: $0, affinity: .after) })
    }
    private func replay(_ candidate: [ChangeID: WritingChange], trustedRoleChanges: Set<ChangeID> = []) throws -> (StructuralState, WritingProjection, Document) {
        try Self.admitted(try replayProjection(candidate, trustedRoleChanges: trustedRoleChanges))
    }
    /// Private planning result only: protocol/role/atom checks remain enforced;
    /// callers must use admitted() before publishing any accepted document.
    private func replayProjection(_ candidate: [ChangeID: WritingChange], trustedRoleChanges: Set<ChangeID> = []) throws -> (StructuralState, WritingProjection, [NodeID: [String: JSONValue]]) {
        let changes = candidate.values.sorted { $0.id < $1.id }
        var active: [ChangeID: Bool] = [:]
        var history: [ChangeID: Change] = [:]
        for change in changes {
            guard change.id.counter > 0, change.id.counter <= 9_007_199_254_740_991, validToken(change.id.actor) else { throw EditorError.invalidChange }
            if usesRetainedOrigins {
                guard let observed = change.observed else { throw EditorError.invalidChange }
                try validateObservedFrontier(observed, before: change.id)
                for dependency in observed where candidate[dependency] == nil { throw WritingProjectionError.missingAtom }
            } else { guard change.observed == nil else { throw EditorError.invalidChange } }
            switch change.body {
            case .edit(let operations):
                guard !operations.isEmpty, operations.count <= 100_000 else { throw EditorError.invalidChange }
                history[change.id] = Change(id: change.id, body: .edit(operations.compactMap {
                    if case .structure(let mutation) = $0 { return mutation }
                    if usesRetainedOrigins, case .schemaConvert(let conversion) = $0,
                       conversion.type == "list", let creation = conversion.creation, let itemID = conversion.itemID {
                        var fields: [String: JSONValue] = ["id": .string(itemID), "content": .array([])]
                        if conversion.attributes["style"] == .string("todo") { fields["checked"] = .bool(false) }
                        return .insertNode(value: .object(fields), identity: conversion.destination.node,
                            collection: NodeCollection(owner: conversion.node, field: "items"), placement: creation, after: nil)
                    }
                    return nil
                }))
            case .setActive(let target, let enabled):
                guard target.actor == change.id.actor, target.counter > 0, target < change.id else { throw EditorError.invalidChange }
                guard let prior = candidate[target] else { throw WritingProjectionError.missingAtom }
                guard case .edit = prior.body else { throw EditorError.invalidChange }
                active[target] = enabled
                history[change.id] = Change(id: change.id, body: .setActive(target: target, active: enabled))
            }
        }
        var raw = Materialized.seed(baseline, version: 2)
        var births = usesRetainedOrigins ? retainedWritingFields(raw.structure!) : [:]
        var collectionBirths: [NodeCollection: NodeKind] = [:]
        if usesRetainedOrigins {
            for (identity, value) in raw.structure!.nodes {
                for (name, kind) in StructuralState.collectionFields(value.kind, value.fields) {
                    collectionBirths[NodeCollection(owner: identity, field: name)] = kind
                }
            }
        }
        func validationShape(_ original: Materialized, mutations: [Mutation], retainedRoles: Set<NodeID> = [], inactive: Bool = false) -> Materialized {
            var copy = original
            guard usesRetainedOrigins else { return copy }
            for mutation in mutations {
                let collection: NodeCollection
                switch mutation {
                case .insertNode(_, _, let destination, _, _), .moveNode(_, let destination, _, _): collection = destination
                default: continue
                }
                if inactive, case .moveNode(let identity, _, _, _) = mutation, retainedRoles.contains(identity),
                   (try? copy.structure?.kind(in: collection)) == .block, var value = copy.structure?.nodes[identity], value.kind == .item {
                    value.kind = .block; value.fields["type"] = .string("paragraph"); copy.structure?.nodes[identity] = value
                }
                if (try? copy.structure?.kind(in: collection)) == nil,
                   collection.field == "children",
                   let owner = collection.owner, var value = copy.structure?.nodes[owner], value.birthKind == .item {
                    value.kind = .item; copy.structure?.nodes[owner] = value
                }
                if (try? copy.structure?.kind(in: collection)) == nil,
                   collectionBirths[collection] == .item, collection.field == "items",
                   let owner = collection.owner, var value = copy.structure?.nodes[owner], value.kind == .block {
                    value.fields["type"] = .string("list"); value.fields["style"] = .string("unordered")
                    value.collections.insert("items"); copy.structure?.nodes[owner] = value
                }
            }
            return copy
        }
        var validatedRoleChanges = trustedRoleChanges
        var exposures: [[ChangeID]: StructuralState] = [:]
        func roleNode(_ identity: NodeID, before change: ChangeID) throws -> StructuralState.Node {
            switch identity {
            case .document: throw EditorError.invalidChange
            case .baseline(let label, let path):
                guard !label.isEmpty, path.count <= 100, path.count % 2 == 0, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidChange }
            case .inserted(let creation, let path):
                guard creation.change.counter > 0, creation.change.counter <= 9_007_199_254_740_991,
                      validToken(creation.change.actor), creation.change < change, creation.index >= 0, creation.index <= 2_147_483_647,
                      path.count <= 100, path.count % 2 == 0, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidChange }
            }
            guard let value = raw.structure?.nodes[identity] else {
                if case .inserted(let creation, _) = identity, candidate[creation.change] == nil { throw WritingProjectionError.missingAtom }
                throw EditorError.invalidChange
            }
            return value
        }
        func roleAnchor(_ after: NodePlacementID?, before change: ChangeID) throws {
            switch after {
            case .some(.initial(let identity)): _ = try roleNode(identity, before: change)
            case .some(.role(let owner, let node)): _ = try roleNode(owner, before: change); _ = try roleNode(node, before: change)
            case .some(.edit(let element)):
                guard element.change.counter > 0, element.change.counter <= 9_007_199_254_740_991, validToken(element.change.actor),
                      element.change < change, element.index >= 0, element.index <= 2_147_483_647 else { throw EditorError.invalidChange }
            case .none: break
            }
        }
        func retainRole(_ role: WritingParagraphRole, change: WritingChange) throws {
            guard usesRetainedOrigins, role.retirement.counter > 0, role.retirement.counter <= 9_007_199_254_740_991,
                  validToken(role.retirement.actor), role.retirement < change.id,
                  !role.exposure.isEmpty, role.exposure.count <= 100_000 else { throw EditorError.invalidChange }
            let owner = try roleNode(role.owner, before: change.id)
            var value = try roleNode(role.node, before: change.id)
            try roleAnchor(role.after, before: change.id)
            let cohort = try observedClosure(role.exposure, before: change.id, in: candidate)
            guard cohort.contains(role.retirement) else { throw EditorError.invalidChange }
            if case .inserted(let creation, _) = role.node, !cohort.contains(creation.change) { throw EditorError.invalidChange }
            guard let proof = candidate[role.retirement] else { throw WritingProjectionError.missingAtom }
            guard owner.kind == .block, value.birthKind == .item, births[WritingField(node: role.node, name: "content")] != nil,
                  value.kind == .item || (value.kind == .block && raw.structure?.placements[.role(owner: role.owner, node: role.node)] != nil) else { throw EditorError.invalidChange }
            if !trustedRoleChanges.contains(change.id) {
                let exposure: StructuralState
                if let cached = exposures[role.exposure] { exposure = cached }
                else {
                    let prefix = candidate.filter { cohort.contains($0.key) }
                    exposure = try replay(prefix, trustedRoleChanges: validatedRoleChanges).0
                    exposures[role.exposure] = exposure
                }
                let selected = try exposure.effectivePlacements()
                guard exposure.visibleNodes(selected).contains(role.node), exposure.nodes[role.node]?.kind == .block,
                      exposure.nodes[role.node]?.fields["type"] == .string("paragraph"),
                      selected[role.node]?.id == .role(owner: role.owner, node: role.node) else { throw EditorError.invalidChange }
            }
            guard retirement(proof, belongsTo: role.owner, node: role.node, in: candidate) else { throw EditorError.invalidChange }
            var itemOwners: Set<NodeID> = []
            for prior in changes where prior.id < change.id {
                guard case .edit(let operations) = prior.body else { continue }
                for operation in operations {
                    if case .schemaConvert(let conversion) = operation {
                        if conversion.node == role.owner && conversion.type == "list" { itemOwners.insert(conversion.destination.node) }
                        if conversion.node == role.owner && conversion.source.node != conversion.node { itemOwners.insert(conversion.source.node) }
                    }
                }
            }
            guard raw.structure!.placements.values.contains(where: {
                $0.node == role.node && ($0.collection == NodeCollection(owner: role.owner, field: "items") ||
                    ($0.collection.field == "children" && $0.collection.owner.map { itemOwners.contains($0) } == true) ||
                    $0.id == .role(owner: role.owner, node: role.node))
            }) else { throw EditorError.invalidChange }
            guard value.kind != .item || value.fields["type"] == nil || value.fields["type"] == .string("paragraph") else {
                throw EditorError.invalidDocument("Peer item role metadata collision")
            }
            let selected = try raw.structure!.effectivePlacements()
            guard let root = selected[role.owner] else { throw EditorError.invalidDocument("Retired role owner is unavailable") }
            let id = NodePlacementID.role(owner: role.owner, node: role.node)
            let priority = raw.structure?.placements[id]?.rolePriority
            let origin = raw.structure?.placements[id]?.roleOrigin
            guard role.after != id else { throw EditorError.invalidChange }
            if let after = role.after {
                guard let anchor = raw.structure?.placements[after] else { throw WritingProjectionError.missingAtom }
                guard anchor.collection == root.collection else { throw EditorError.invalidDocument("Retained role anchor moved between collections") }
            }
            if let existing = raw.structure?.placements[id], existing.collection != root.collection {
                throw EditorError.invalidDocument("Retired role owner moved between collections")
            }
            let enabled = active[change.id] ?? true
            if value.kind == .item { value.kind = .block; value.fields["type"] = .string("paragraph") }
            raw.structure?.nodes[role.node] = value
            if enabled {
                raw.structure?.touched.insert(role.node)
                for (key, old) in raw.structure!.placements where old.node == role.node && old.active {
                    raw.structure?.placements[key] = StructuralState.Placement(id: old.id, after: old.after,
                        node: old.node, collection: old.collection, active: false, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
                }
            }
            if enabled || raw.structure?.placements[id] == nil {
                raw.structure?.placements[id] = StructuralState.Placement(id: id, after: role.after,
                    node: role.node, collection: root.collection, active: enabled, rolePriority: priority, roleOrigin: origin)
            }
        }
        var available = Set<WritingAtomKey>()
        func seededKeys(_ shape: StructuralState) -> Set<WritingAtomKey> {
            var keys = Set<WritingAtomKey>()
            for (identity, node) in shape.nodes {
                for name in writingFields(node) {
                    let value = node.fields[name]!
                    let count = value.string?.unicodeScalars.count ?? (value.array ?? []).reduce(0) {
                        $0 + ($1["type"] == .string("text") ? max(1, $1["text"]?.string?.unicodeScalars.count ?? 0) : 1)
                    }
                    let origin = WritingField(node: identity, name: name)
                    for index in 0..<count { keys.insert(WritingAtomKey(origin: origin, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))) }
                }
            }
            return keys
        }
        available.formUnion(seededKeys(raw.structure!))
        for change in changes {
            guard case .edit(let operations) = change.body else { continue }
            let beforeRoleNodes = raw.structure?.nodes ?? [:]
            var passedRolePrefix = false
            for operation in operations {
                if case .retainParagraphRole(let role) = operation {
                    guard !passedRolePrefix else { throw EditorError.invalidChange }
                    try retainRole(role, change: change)
                } else if case .exitListItem(let identity, let owner, let source, let after) = operation {
                    guard !passedRolePrefix, usesRetainedOrigins else { throw EditorError.invalidChange }
                    try roleAnchor(after, before: change.id); try roleAnchor(source, before: change.id)
                    guard let original = raw.structure?.placements[source] else { throw WritingProjectionError.missingAtom }
                    guard original.node == identity, original.collection == NodeCollection(owner: owner, field: "items") else { throw EditorError.invalidChange }
                    let wrapper = try roleNode(owner, before: change.id)
                    var item = try roleNode(identity, before: change.id)
                    guard wrapper.kind == .block, item.birthKind == .item,
                          births[WritingField(node: identity, name: "content")] != nil,
                          raw.structure!.placements.values.contains(where: { $0.node == identity && $0.collection == NodeCollection(owner: owner, field: "items") }),
                          item.kind == .item || raw.structure?.placements[.role(owner: owner, node: identity)] != nil else { throw EditorError.invalidChange }
                    guard item.kind != .item || item.fields["type"] == nil else { throw EditorError.invalidDocument("Exited item type metadata collision") }
                    let placements = try raw.structure!.effectivePlacements()
                    guard let root = placements[owner] else { throw EditorError.invalidDocument("Exited item owner unavailable") }
                    let placement = NodePlacementID.role(owner: owner, node: identity)
                    guard after != placement else { throw EditorError.invalidChange }
                    if let after {
                        guard let anchor = raw.structure?.placements[after] else { throw WritingProjectionError.missingAtom }
                        guard anchor.collection == root.collection else { throw EditorError.invalidChange }
                    }
                    if item.kind == .item { item.kind = .block; item.fields["type"] = .string("paragraph") }
                    raw.structure?.nodes[identity] = item
                    let enabled = active[change.id] ?? true
                    if enabled {
                        raw.structure?.touched.insert(identity)
                        for (key, old) in raw.structure!.placements where old.node == identity && old.active {
                            raw.structure?.placements[key] = StructuralState.Placement(id: old.id, after: old.after, node: old.node, collection: old.collection, active: false, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
                        }
                    }
                    if enabled || raw.structure?.placements[placement] == nil {
                        raw.structure?.placements[placement] = StructuralState.Placement(id: placement, after: after,
                            node: identity, collection: root.collection, active: enabled,
                            rolePriority: ElementID(change: change.id, index: 0), roleOrigin: source)
                    }
                } else { passedRolePrefix = true }
            }
            if operations.contains(where: { if case .retainParagraphRole = $0 { return true }; return false }) {
                validatedRoleChanges.insert(change.id)
            }
            let retainedRoles = Set(operations.compactMap { operation -> NodeID? in
                if case .retainParagraphRole(let role) = operation { return role.node }
                if case .exitListItem(let identity, _, _, _) = operation { return identity }; return nil
            })
            let structural = Change(id: change.id, body: .edit(operations.compactMap {
                if case .structure(let mutation) = $0 { return mutation }; return nil
            }))
            if case .edit(let mutations) = structural.body, !mutations.isEmpty {
                let validating = validationShape(raw, mutations: mutations, retainedRoles: retainedRoles, inactive: !(active[change.id] ?? true))
                do { try validate(structural, version: 2, structure: validating.structure, history: history, seedState: validating) }
                catch EditorError.invalidDocument { throw EditorError.invalidChange }
            }
            if protocolVersion == 5 || protocolVersion == 6 {
                // Descriptor ownership is a packet invariant, including retained
                // inactive edits. Undo cannot legalize a duplicate group.
                var grouped = Set<NodeID>(), destinations = Set<NodeID>()
                for operation in operations {
                    switch operation {
                    case .text(.splitBoundary(_, let destination, _, _)):
                        guard !grouped.contains(destination.node), destinations.insert(destination.node).inserted else { throw EditorError.invalidChange }
                    case .text(.spliceBoundary(_, let destination, _, _, let members)):
                        guard Set(members).count == members.count, grouped.isDisjoint(with: members),
                              destinations.isDisjoint(with: members), destinations.insert(destination.node).inserted else { throw EditorError.invalidChange }
                        grouped.formUnion(members)
                    case .text(.rangeSpliceBoundary(let splice)):
                        guard protocolVersion == 6, Set(splice.members).count == splice.members.count,
                              grouped.isDisjoint(with: splice.members), destinations.isDisjoint(with: splice.members),
                              destinations.insert(splice.destination.node).inserted else { throw EditorError.invalidChange }
                        grouped.formUnion(splice.members)
                    case .text(.importBoundary(let boundary)):
                        guard protocolVersion == 6, Set(boundary.members).count == boundary.members.count,
                              grouped.isDisjoint(with: boundary.members), destinations.isDisjoint(with: boundary.members) else { throw EditorError.invalidChange }
                        grouped.formUnion(boundary.members)
                    default: break
                    }
                }
            }
            // Index declared placements once. Node/field validation below still
            // requires that each referenced origin exists at this operation.
            var spliceCollections: [NodeID: Set<NodeCollection>] = [:]
            if protocolVersion == 5 || protocolVersion == 6 {
                for placement in raw.structure?.placements.values ?? Dictionary<NodePlacementID, StructuralState.Placement>().values {
                    spliceCollections[placement.node, default: []].insert(placement.collection)
                }
                for operation in operations {
                    switch operation {
                    case .structure(.insertNode(_, let identity, let collection, _, _)),
                         .structure(.moveNode(let identity, let collection, _, _)):
                        spliceCollections[identity, default: []].insert(collection)
                    default: break
                    }
                }
            }
            let explicitlyMoved = Set(operations.compactMap { operation -> NodeID? in
                if case .structure(.moveNode(let identity, _, _, _)) = operation { return identity }; return nil
            })
            var introduced = Set<ElementID>()
            func node(_ identity: NodeID) throws {
                switch identity {
                case .document: throw EditorError.invalidChange
                case .baseline(let label, let path):
                    guard !label.isEmpty, path.count <= 100, path.count % 2 == 0, path.allSatisfy({ !$0.isEmpty }), raw.structure?.nodes[identity] != nil else { throw EditorError.invalidChange }
                case .inserted(let creation, let path):
                    guard creation.change.counter > 0, creation.change.counter <= 9_007_199_254_740_991,
                          validToken(creation.change.actor), creation.change <= change.id,
                          creation.index >= 0, creation.index <= 2_147_483_647,
                          path.count <= 100, path.count % 2 == 0, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidChange }
                    if raw.structure?.nodes[identity] == nil {
                        if creation.change == change.id || candidate[creation.change] != nil { throw EditorError.invalidChange }
                        throw WritingProjectionError.missingAtom
                    }
                }
            }
            func field(_ field: WritingField) throws {
                try node(field.node)
                guard usesRetainedOrigins ? births[field] != nil : writingFields(raw.structure!.nodes[field.node]!).contains(field.name) else { throw EditorError.invalidPath }
            }
            func reference(_ key: WritingAtomKey) throws {
                let id = key.element
                guard id.index >= 0, id.index <= 2_147_483_647, id.change <= change.id,
                      id.change.counter <= 9_007_199_254_740_991,
                      id.change.counter == 0 ? id.change.actor.isEmpty : validToken(id.change.actor) else { throw EditorError.invalidChange }
                try field(key.origin)
                guard available.contains(key) else {
                    if id.change == change.id || id.change.counter == 0 || candidate[id.change] != nil { throw EditorError.invalidChange }
                    throw WritingProjectionError.missingAtom
                }
            }
            func edge(_ edge: WritingEdge) throws { if let key = edge.anchor { try reference(key) } }
            func keys(_ keys: [WritingAtomKey]) throws {
                guard !keys.isEmpty, keys.count <= 100_000, Set(keys).count == keys.count else { throw EditorError.invalidChange }
                for key in keys { try reference(key) }
            }
            @inline(never) func validateImportBoundary(_ boundary: WritingImportBoundary) throws {
                guard protocolVersion == 6, !boundary.members.isEmpty, boundary.members.count <= 10_000,
                      Set(boundary.members).count == boundary.members.count,
                      !boundary.members.contains(boundary.source.node) else { throw EditorError.invalidChange }
                try field(boundary.source); try edge(boundary.edge)
                if !boundary.sourceKeys.isEmpty { try keys(boundary.sourceKeys) }
                let cohort = try observedClosure(change.observed ?? [], before: change.id, in: candidate)
                func origin(_ identity: NodeID) throws {
                    try node(identity)
                    if case .inserted(let creation, _) = identity, !cohort.contains(creation.change) { throw EditorError.invalidChange }
                }
                func observed(_ key: WritingAtomKey, allowOwn: Bool = false) throws {
                    try reference(key)
                    if key.element.change == change.id {
                        guard allowOwn, key.origin == boundary.source else { throw EditorError.invalidChange }
                    } else if key.element.change.counter > 0, !cohort.contains(key.element.change) { throw EditorError.invalidChange }
                    try origin(key.origin.node)
                }
                try origin(boundary.source.node)
                if let anchor = boundary.edge.anchor { try observed(anchor, allowOwn: true) }
                for key in boundary.sourceKeys { try observed(key) }
                switch boundary.sourcePlacement {
                case .edit(let edit):
                    guard edit.change < change.id, cohort.contains(edit.change), edit.index >= 0,
                          edit.index <= 2_147_483_647 else { throw EditorError.invalidChange }
                case .initial(let identity):
                    try origin(identity)
                    if case .inserted(_, let path) = identity, path.isEmpty { throw EditorError.invalidChange }
                case .role(let owner, let identity):
                    try origin(owner); try origin(identity)
                    guard let role = operations.compactMap({ operation -> WritingParagraphRole? in
                        if case .retainParagraphRole(let role) = operation, role.owner == owner, role.node == identity { return role }; return nil
                    }).first, cohort.contains(role.retirement),
                          try observedClosure(role.exposure, before: change.id, in: candidate).isSubset(of: cohort) else { throw EditorError.invalidChange }
                }
                guard let source = raw.structure?.placements[boundary.sourcePlacement] else { throw WritingProjectionError.missingAtom }
                guard source.node == boundary.source.node else { throw EditorError.invalidChange }
                let kind = try raw.structure!.kind(in: boundary.collection)
                if boundary.collection == source.collection {
                    guard boundary.after == source.id else { throw EditorError.invalidChange }
                } else {
                    guard boundary.collection.owner == boundary.source.node, boundary.after == nil else { throw EditorError.invalidChange }
                }
                var previous = boundary.after
                for member in boundary.members {
                    try node(member)
                    guard case .inserted(let creation, let path) = member, path.isEmpty, creation.change == change.id,
                          let birth = raw.structure?.placements[.edit(creation)], birth.node == member,
                          birth.collection == boundary.collection, birth.after == previous,
                          raw.structure?.nodes[member]?.kind == kind, !explicitlyMoved.contains(member) else { throw EditorError.invalidChange }
                    previous = birth.id
                }
                if let before = boundary.before {
                    try origin(before)
                    guard !boundary.members.contains(before), before != boundary.source.node,
                          spliceCollections[before]?.contains(boundary.collection) == true else { throw EditorError.invalidChange }
                }
            }
            @inline(never) func validateRangeSplice(_ splice: WritingRangeSplice) throws {
                guard protocolVersion == 6 else { throw EditorError.invalidChange }
                try field(splice.source); try field(splice.destination); try edge(splice.edge)
                if !splice.endpointKeys.isEmpty { try keys(splice.endpointKeys) }
                guard splice.endpointKeys.allSatisfy({ $0.element.change != change.id }), splice.source != splice.destination, splice.source.name == "content", splice.destination.name == "content",
                      !splice.members.isEmpty, splice.members.count <= 10_000, splice.members.last == splice.destination.node,
                      Set(splice.members).count == splice.members.count, !splice.members.contains(splice.source.node),
                      splice.destinationPlacement.change == change.id else { throw EditorError.invalidChange }
                let cohort = try observedClosure(change.observed ?? [], before: change.id, in: candidate)
                func observedAtom(_ key: WritingAtomKey) throws {
                    if key.element.change.counter > 0, !cohort.contains(key.element.change) { throw EditorError.invalidChange }
                    if case .inserted(let creation, _) = key.origin.node, !cohort.contains(creation.change) { throw EditorError.invalidChange }
                }
                for key in splice.endpointKeys { try observedAtom(key) }
                if let anchor = splice.edge.anchor { try observedAtom(anchor) }
                for operation in operations {
                    if case .text(.transfer(let pin, let target, .start)) = operation, target == splice.source {
                        for key in pin {
                            try reference(key)
                            if key.element.change == change.id {
                                guard key.origin == splice.source else { throw EditorError.invalidChange }
                            } else { try observedAtom(key) }
                        }
                    }
                }
                func proof(_ id: NodePlacementID, node identity: NodeID) throws -> StructuralState.Placement {
                    switch id {
                    case .edit(let edit):
                        guard edit.change.counter > 0, edit.change.counter <= 9_007_199_254_740_991,
                              validToken(edit.change.actor), edit.index >= 0, edit.index <= 2_147_483_647,
                              edit.change < change.id, cohort.contains(edit.change) else { throw EditorError.invalidChange }
                    case .initial(let identity):
                        if case .inserted(let creation, let path) = identity {
                            guard !path.isEmpty, cohort.contains(creation.change) else { throw EditorError.invalidChange }
                        }
                        try selfReference(identity)
                    case .role(let owner, let node):
                        try selfReference(owner); try selfReference(node)
                        guard let role = operations.compactMap({ operation -> WritingParagraphRole? in
                            if case .retainParagraphRole(let role) = operation, role.owner == owner, role.node == node { return role }; return nil
                        }).first, cohort.contains(role.retirement) else { throw EditorError.invalidChange }
                        let exposure = try observedClosure(role.exposure, before: change.id, in: candidate)
                        guard exposure.isSubset(of: cohort) else { throw EditorError.invalidChange }
                    }
                    guard let old = raw.structure?.placements[id] else { throw WritingProjectionError.missingAtom }
                    guard old.node == identity else { throw EditorError.invalidChange }; return old
                }
                func selfReference(_ identity: NodeID) throws { try node(identity) }
                for identity in [splice.source.node, splice.destination.node] {
                    if case .inserted(let creation, _) = identity, !cohort.contains(creation.change) { throw EditorError.invalidChange }
                }
                let source = try proof(splice.sourcePlacement, node: splice.source.node)
                let ending = try proof(splice.endpointPlacement, node: splice.destination.node)
                guard source.collection == ending.collection,
                      raw.structure?.nodes[splice.source.node]?.kind == .block,
                      raw.structure?.nodes[splice.destination.node]?.kind == .block else { throw EditorError.invalidChange }
                // These are retained placement proofs, not a claim about
                // currently winning sibling order. RGA moves can be siblings
                // without an ancestor-after relation; the public range planner
                // normalizes live order before producing this explicit edit.
                var previous = source.id
                for member in splice.members.dropLast() {
                    try node(member)
                    guard case .inserted(let creation, let path) = member, path.isEmpty, creation.change == change.id,
                          let birth = raw.structure?.placements[.edit(creation)], birth.node == member,
                          birth.collection == source.collection, birth.after == previous,
                          raw.structure?.nodes[member]?.kind == .block, !explicitlyMoved.contains(member) else { throw EditorError.invalidChange }
                    previous = birth.id
                }
                let endpointMoves = operations.filter {
                    if case .structure(.moveNode(let identity, _, _, _)) = $0 { return identity == splice.destination.node }; return false
                }
                guard endpointMoves.count == 1, let moved = raw.structure?.placements[.edit(splice.destinationPlacement)],
                      moved.node == splice.destination.node, moved.collection == source.collection,
                      moved.after == previous else { throw EditorError.invalidChange }
                if let before = splice.before {
                    try node(before)
                    if case .inserted(let birth, _) = before {
                        guard birth.change < change.id, cohort.contains(birth.change) else { throw EditorError.invalidChange }
                    }
                    guard before != splice.source.node, !splice.members.contains(before),
                          spliceCollections[before]?.contains(source.collection) == true else { throw EditorError.invalidChange }
                }
            }
            @inline(never) func validateText(_ mutation: WritingMutation) throws {
                switch mutation {
                case .insert(let atom):
                    try field(atom.key.origin); try edge(atom.edge)
                    switch atom.route {
                    case .field(let origin):
                        try field(origin)
                        guard origin == atom.key.origin, atom.edge == .start else { throw EditorError.invalidChange }
                    case .follow(let anchor):
                        try reference(anchor)
                        guard atom.edge.anchor == anchor else { throw EditorError.invalidChange }
                    }
                    guard atom.key.element.change == change.id, atom.key.element.index >= 0,
                          atom.key.element.index <= 2_147_483_647,
                          introduced.insert(atom.key.element).inserted, available.insert(atom.key).inserted else { throw EditorError.invalidChange }
                    do { try Validation.inline(.array([atom.node])) } catch { throw EditorError.invalidChange }
                    for mark in atom.node["marks"]?.array ?? [] where mark["type"] == .string("link") {
                        guard let scheme = mark["href"]?.string.flatMap({ URL(string: $0)?.scheme?.lowercased() }), ["http", "https", "mailto"].contains(scheme) else { throw EditorError.invalidChange }
                    }
                    if atom.node["type"] == .string("text") {
                        guard atom.node["text"]?.string?.unicodeScalars.count == 1 else { throw EditorError.invalidChange }
                    } else { guard !plainText([atom.node]).isEmpty else { throw EditorError.invalidChange } }
                case .transfer(let span, let destination, let boundary):
                    try keys(span); try field(destination); try edge(boundary)
                    guard boundary.anchor.map({ !span.contains($0) }) ?? true else { throw EditorError.invalidChange }
                case .delete(let span): try keys(span)
                case .format(let span, let type, let mark):
                    try keys(span)
                    guard ["bold", "italic", "strikethrough", "code", "link"].contains(type), mark == nil || mark?["type"] == .string(type) else { throw EditorError.invalidChange }
                    if let mark {
                        do { try Validation.mark(mark) } catch { throw EditorError.invalidChange }
                        if type == "link" {
                            guard let scheme = mark["href"]?.string.flatMap({ URL(string: $0)?.scheme?.lowercased() }), ["http", "https", "mailto"].contains(scheme) else { throw EditorError.invalidChange }
                        }
                    }
                case .join(let source, let destination, let boundary):
                    try field(source); try field(destination); try edge(boundary)
                    let sourceNode = raw.structure?.nodes[source.node], destinationNode = raw.structure?.nodes[destination.node]
                    let inline = ["paragraph", "heading", "quote", "callout"]
                    let paragraphs = usesRetainedOrigins
                        ? (inline.contains(sourceNode?.fields["type"]?.string ?? "") || (sourceNode?.kind == .block && births[source] != nil)) &&
                          (inline.contains(destinationNode?.fields["type"]?.string ?? "") || (destinationNode?.kind == .block && births[destination] != nil))
                        : sourceNode?.fields["type"] == .string("paragraph") && destinationNode?.fields["type"] == .string("paragraph")
                    let exit = usesRetainedOrigins && sourceNode?.kind == .item && destinationNode?.fields["type"] == .string("paragraph")
                    guard source != destination, source.name == "content", destination.name == "content", paragraphs || exit else { throw EditorError.invalidChange }
                case .spliceBoundary(let source, let destination, let boundary, let before, let members):
                    // The wire capability is explicit; old epochs cannot admit
                    // a group convention they have never projected.
                    guard protocolVersion == 5 || protocolVersion == 6 else { throw EditorError.invalidChange }
                    try field(source); try field(destination); try edge(boundary)
                    guard source != destination, source.name == "content", destination.name == "content",
                          (raw.structure?.nodes[source.node]?.birthKind == .block ||
                           (retainedRoles.contains(source.node) && raw.structure?.nodes[source.node]?.kind == .block)),
                          raw.structure?.nodes[destination.node]?.birthKind == .block,
                          raw.structure?.nodes[destination.node]?.fields["type"] == .string("paragraph"),
                          !members.isEmpty, members.count <= 10_000,
                          Set(members).count == members.count, members.last == destination.node,
                          !members.contains(source.node) else { throw EditorError.invalidChange }
                    var collection: NodeCollection?, previous: NodePlacementID?
                    for member in members {
                        try node(member)
                        guard case .inserted(let creation, let path) = member, path.isEmpty,
                              creation.change == change.id,
                              let birth = raw.structure?.placements[.edit(creation)], birth.node == member,
                              raw.structure?.nodes[member]?.birthKind == .block else { throw EditorError.invalidChange }
                        if let previous {
                            guard birth.collection == collection, birth.after == previous else { throw EditorError.invalidChange }
                        } else {
                            guard let anchor = birth.after, let owner = raw.structure?.placements[anchor],
                                  owner.node == source.node, owner.collection == birth.collection else { throw EditorError.invalidChange }
                            collection = birth.collection
                        }
                        guard !explicitlyMoved.contains(member) else { throw EditorError.invalidChange }
                        previous = birth.id
                    }
                    if let before {
                        try node(before)
                        // The outer neighbor was observed before this edit.
                        // New same-edit groups cannot encode reciprocal hints
                        // that Undo would hide until a later Redo.
                        if case .inserted(let birth, _) = before {
                            guard birth.change < change.id else { throw EditorError.invalidChange }
                        }
                        guard before != source.node, !members.contains(before),
                              collection.map({ spliceCollections[before]?.contains($0) == true }) == true else { throw EditorError.invalidChange }
                    }
                case .rangeSpliceBoundary(let splice): try validateRangeSplice(splice)
                case .importBoundary(let boundary): try validateImportBoundary(boundary)
                case .splitBoundary(let source, let destination, let boundary, let before):
                    try field(source); try field(destination); try edge(boundary)
                    if let before { try node(before); guard before != destination.node else { throw EditorError.invalidChange } }
                    let sourceNode = raw.structure?.nodes[source.node], destinationNode = raw.structure?.nodes[destination.node]
                    // A concurrent lossless conversion keeps the source content
                    // origin valid; a split authored on its paragraph birth
                    // must still replay after that conversion.
                    let paragraphs = (sourceNode?.fields["type"] == .string("paragraph") ||
                        (usesRetainedOrigins && sourceNode?.kind == .block && births[source] != nil)) && destinationNode?.fields["type"] == .string("paragraph")
                    let items = usesRetainedOrigins && sourceNode?.kind == .item && destinationNode?.kind == .item
                    guard source != destination, source.name == "content", destination.name == "content", paragraphs || items || (usesRetainedOrigins && sourceNode?.kind == .item && destinationNode?.fields["type"] == .string("paragraph")),
                          case .inserted(let creation, let path) = destination.node,
                          creation.change == change.id, path.isEmpty else { throw EditorError.invalidChange }
                }
            }
            for operation in operations {
                switch operation {
                case .retainParagraphRole, .exitListItem: break // Validated/materialized before structural validation.
                case .schemaConvert(let conversion):
                    guard usesRetainedOrigins else { throw EditorError.invalidChange }
                    try node(conversion.node); try field(conversion.source)
                    guard conversion.source.node == conversion.node || conversion.type != "list",
                          let original = raw.structure?.nodes[conversion.node], original.kind == .block,
                          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(original.fields["type"]?.string ?? ""),
                          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(conversion.type) else { throw EditorError.invalidChange }
                    if conversion.source.node != conversion.node {
                        guard raw.structure?.nodes[conversion.source.node]?.kind == .item,
                              raw.structure!.placements.values.contains(where: {
                                  $0.node == conversion.source.node && $0.collection == NodeCollection(owner: conversion.node, field: "items")
                              }) else { throw EditorError.invalidChange }
                    }
                    var value = original
                    if conversion.type == "list" {
                        guard let creation = conversion.creation, creation.change == change.id, creation.index >= 0, creation.index <= 2_147_483_647,
                              original.fields["items"] == nil, introduced.insert(creation).inserted, let itemID = conversion.itemID, !itemID.isEmpty,
                              conversion.destination == WritingField(node: .inserted(creation: creation, path: []), name: "content"),
                              conversion.attributes.keys.allSatisfy({ $0 == "style" }) else { throw EditorError.invalidChange }
                        if active[change.id] ?? true, original.fields["type"] == .string("list") {
                            throw EditorError.invalidDocument("Concurrent list conversions require reconciliation")
                        }
                        var item: [String: JSONValue] = ["id": .string(itemID), "content": .array([])]
                        if conversion.attributes["style"] == .string("todo") { item["checked"] = .bool(false) }
                        let enabled = active[change.id] ?? true
                        raw.structure?.register(.object(item), identity: conversion.destination.node, kind: .item, active: enabled)
                        let placement = NodePlacementID.edit(creation)
                        raw.structure?.placements[placement] = StructuralState.Placement(id: placement, after: nil,
                            node: conversion.destination.node, collection: NodeCollection(owner: conversion.node, field: "items"), active: enabled)
                        births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: .array([]), active: enabled)
                        collectionBirths[NodeCollection(owner: conversion.node, field: "items")] = .item
                        value.collections.insert("items")
                    } else {
                        guard conversion.creation == nil, conversion.itemID == nil,
                              (conversion.source == conversion.destination || original.fields[conversion.destination.name] == nil || births[conversion.destination] != nil),
                              conversion.destination == WritingField(node: conversion.node, name: conversion.type == "code" ? "code" : "content") else { throw EditorError.invalidChange }
                        let allowed: Set<String> = conversion.type == "heading" ? ["level"] : conversion.type == "callout" ? ["variant"] : conversion.type == "code" ? ["language"] : []
                        guard Set(conversion.attributes.keys).isSubset(of: allowed) else { throw EditorError.invalidChange }
                        births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: conversion.type == "code" ? .string("") : .array([]), active: true)
                        value.collections.remove("items")
                    }
                    if conversion.source.node != conversion.node {
                        guard let item = raw.structure?.nodes[conversion.source.node], item.kind == .item else { throw EditorError.invalidChange }
                        guard item.fields.filter({ $0.key != "id" && $0.key != "content" }) == conversion.preservedItemFields.filter({ $0.key != "children" }) else {
                            throw EditorError.invalidDocument("Converted item metadata requires reconciliation")
                        }
                        if item.collections.contains("children") {
                            guard conversion.preservedItemFields["children"] == nil || conversion.preservedItemFields["children"] == .array([]) else { throw EditorError.invalidChange }
                        }
                    } else { guard conversion.preservedItemFields.isEmpty else { throw EditorError.invalidChange } }
                    guard conversion.preservedItemFields.keys.allSatisfy({ !["id", "type", "content", "code", "summary", "caption", "expression", "items", "rows"].contains($0) }) else { throw EditorError.invalidChange }
                    for (key, preserved) in conversion.preservedItemFields {
                        guard original.fields[key] == nil || original.fields[key] == preserved else { throw EditorError.invalidChange }
                        value.fields[key] = preserved
                    }
                    value.fields.removeValue(forKey: conversion.source.name)
                    value.fields["type"] = .string(conversion.type)
                    value.fields[conversion.destination.name] = conversion.type == "list" ? nil : conversion.type == "code" ? .string("") : .array([])
                    for (key, attribute) in conversion.attributes {
                        guard !(active[change.id] ?? true) || original.fields["type"]?.string == conversionAttributeOwner(key) || value.fields[key] == nil || value.fields[key] == attribute else {
                            throw EditorError.invalidDocument("Conversion attribute metadata requires reconciliation")
                        }
                        value.fields[key] = attribute
                    }
                    var shape = value.fields
                    for collection in value.collections { shape[collection] = .array([]) }
                    try validateNode(.object(shape), kind: .block)
                    if active[change.id] ?? true {
                        raw.structure?.nodes[conversion.node] = value; raw.structure?.touched.insert(conversion.node)
                        if conversion.source.node != conversion.node { raw.structure?.deleted.insert(conversion.source.node) }
                    }
                case .convertBlock(let identity, let type, let attributes):
                    guard usesRetainedOrigins else { throw EditorError.invalidChange }
                    try node(identity)
                    guard var value = raw.structure?.nodes[identity], value.kind == .block else { throw EditorError.invalidChange }
                    let original = value.fields["type"]?.string ?? ""
                    let inline = ["paragraph", "heading", "quote", "callout"]
                    let retiredList = usesRetainedOrigins && original != "list" && type == "list" &&
                        collectionBirths[NodeCollection(owner: identity, field: "items")] == .item
                    guard (inline.contains(original) && inline.contains(type)) || (original == "list" && type == "list") || retiredList else { throw EditorError.invalidChange }
                    let allowed: Set<String> = type == "heading" ? ["level"] : type == "callout" ? ["variant"] : type == "list" ? ["style"] : []
                    guard Set(attributes.keys).isSubset(of: allowed) else { throw EditorError.invalidChange }
                    if type == "list" { guard ["ordered", "unordered", "todo"].contains(attributes["style"]?.string ?? "") else { throw EditorError.invalidChange } }
                    if !retiredList { value.fields["type"] = .string(type) }
                    for (key, attribute) in attributes {
                        guard !(active[change.id] ?? true) || original == conversionAttributeOwner(key) || retiredList || value.fields[key] == nil || value.fields[key] == attribute else {
                            throw EditorError.invalidDocument("Conversion attribute metadata requires reconciliation")
                        }
                        value.fields[key] = attribute
                    }
                    var shape = value.fields
                    for collection in value.collections { shape[collection] = .array([]) }
                    try validateNode(.object(shape), kind: .block)
                    if active[change.id] ?? true { raw.structure?.nodes[identity] = value; raw.structure?.touched.insert(identity) }
                case .structure(let mutation):
                    switch mutation {
                    case .insertNode(_, _, _, let placement, _), .moveNode(_, _, let placement, _):
                        guard introduced.insert(placement).inserted else { throw EditorError.invalidChange }
                    case .setNodeField, .deleteNodes: break
                    default: throw EditorError.invalidChange
                    }
                    if usesRetainedOrigins {
                        let validating = validationShape(raw, mutations: [mutation], retainedRoles: retainedRoles, inactive: !(active[change.id] ?? true))
                        let originalNodes = raw.structure?.nodes ?? [:]
                        let adjusted = validating.structure?.nodes.filter { originalNodes[$0.key]?.fields != $0.value.fields || originalNodes[$0.key]?.kind != $0.value.kind } ?? [:]
                        raw.structure = validating.structure
                        try apply([mutation], enabled: active[change.id] ?? true, to: &raw)
                        for owner in adjusted.keys { raw.structure?.nodes[owner] = originalNodes[owner] }
                        for (field, birth) in retainedWritingFields(raw.structure!) where births[field] == nil { births[field] = birth }
                    } else { try apply([mutation], enabled: active[change.id] ?? true, to: &raw) }
                    available.formUnion(seededKeys(raw.structure!))
                case .text(let mutation): try validateText(mutation)
                }
            }
            if !(active[change.id] ?? true) {
                for identity in retainedRoles { raw.structure?.nodes[identity] = beforeRoleNodes[identity] }
            }
        }
        return try Self.projectState(raw: raw, changes: changes, births: usesRetainedOrigins ? births : nil, protocolVersion: protocolVersion)
    }

    private static func project(raw: Materialized, changes: [WritingChange], births retained: [WritingField: WritingFieldBirth]? = nil) throws -> (StructuralState, WritingProjection, Document) {
        try admitted(try projectState(raw: raw, changes: changes, births: retained))
    }
    private static func admitted(_ state: (StructuralState, WritingProjection, [NodeID: [String: JSONValue]])) throws -> (StructuralState, WritingProjection, Document) {
        let document = try state.0.document(text: state.2)
        guard try document.json().count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        return (state.0, state.1, document)
    }
    private static func projectState(raw: Materialized, changes: [WritingChange], births retained: [WritingField: WritingFieldBirth]? = nil, protocolVersion: Int = 3) throws -> (StructuralState, WritingProjection, [NodeID: [String: JSONValue]]) {
        let inputs = try prepareProjection(raw: raw, changes: changes, births: retained)
        let (structure, edits) = try orderedCuts(structure: inputs.structure, edits: inputs.edits,
            seeds: inputs.seeds, active: inputs.active, fields: inputs.fields, births: inputs.births,
            hidden: inputs.hidden, aliases: inputs.aliases, changes: changes,
            retained: retained, protocolVersion: protocolVersion)
        return try assembleProjection(structure: structure, edits: edits, inputs: inputs, retained: retained)
    }
    private struct ProjectionInputs {
        let structure: StructuralState
        let seeds: [WritingAtomSeed]
        let fields: Set<WritingField>
        let hidden: Set<WritingAtomKey>
        let births: [WritingField: WritingFieldBirth]
        let active: [ChangeID: Bool]
        let edits: [WritingEdit]
        let aliases: [WritingField: WritingField]
    }
    @inline(never) private static func prepareProjection(raw: Materialized, changes: [WritingChange],
        births retained: [WritingField: WritingFieldBirth]?) throws -> ProjectionInputs {
        guard var structure = raw.structure else { throw EditorError.invalidChange }
        var seeds: [WritingAtomSeed] = [], fields = Set<WritingField>(), hidden = Set<WritingAtomKey>()
        let births = retained ?? retainedWritingFields(structure)
        fields = Set(retainedWritingFields(structure).keys)
        let seeded = seedWritingAtoms(births)
        seeds = seeded.atoms; hidden = seeded.hidden
        var active: [ChangeID: Bool] = [:], edits: [WritingEdit] = []
        for change in changes {
            switch change.body {
            case .setActive(let target, let enabled): active[target] = enabled
            case .edit(let operations):
                edits.append(WritingEdit(id: change.id, mutations: operations.compactMap { if case .text(let mutation) = $0 { return mutation }; return nil }))
            }
        }
        var aliases: [WritingField: WritingField] = [:]
        if retained != nil {
            var groups: [NodeID: Set<WritingField>] = [:], destinations: [NodeID: WritingField] = [:]
            var firstSources: [NodeID: WritingField] = [:], activeRoots = Set<NodeID>()
            for change in changes {
                guard case .edit(let operations) = change.body else { continue }
                for operation in operations {
                    guard case .schemaConvert(let conversion) = operation else { continue }
                    groups[conversion.node, default: []].formUnion([conversion.source, conversion.destination])
                    if firstSources[conversion.node] == nil { firstSources[conversion.node] = conversion.source }
                    if active[change.id] ?? true {
                        activeRoots.insert(conversion.node); destinations[conversion.node] = conversion.destination
                    }
                }
            }
            var parents = Dictionary(uniqueKeysWithValues: groups.keys.map { ($0, $0) })
            func representative(_ root: NodeID) -> NodeID {
                var current = root
                while let next = parents[current], next != current { current = next }
                return current
            }
            var owners: [WritingField: NodeID] = [:]
            for root in groups.keys.sorted(by: { $0.key < $1.key }) {
                for field in groups[root]! {
                    if let previous = owners[field] {
                        let a = representative(root), b = representative(previous)
                        if a != b { if a.key < b.key { parents[b] = a } else { parents[a] = b } }
                    } else { owners[field] = root }
                }
            }
            var components: [NodeID: Set<NodeID>] = [:]
            for root in groups.keys { components[representative(root), default: []].insert(root) }
            for roots in components.values {
                let fields = roots.reduce(into: Set<WritingField>()) { $0.formUnion(groups[$1]!) }
                let heads = Set(roots.filter { activeRoots.contains($0) }.compactMap { destinations[$0] })
                let destination: WritingField
                if heads.count == 1 { destination = heads.first! }
                else if !heads.isEmpty { throw EditorError.invalidDocument("Overlapping active conversion heads require reconciliation") }
                else {
                    // Each inactive family rolls back toward its first source.
                    // Resolve every branch to one sink without recursive walks.
                    var edges: [WritingField: Set<WritingField>] = [:]
                    for root in roots {
                        guard let source = firstSources[root] else { throw EditorError.invalidChange }
                        for field in groups[root]! where field != source { edges[field, default: []].insert(source) }
                    }
                    var remaining = fields.reduce(into: [WritingField: Int]()) { $0[$1] = edges[$1]?.count ?? 0 }
                    var predecessors: [WritingField: Set<WritingField>] = [:]
                    for (field, targets) in edges { for target in targets { predecessors[target, default: []].insert(field) } }
                    var pending = Array(fields.filter { remaining[$0] == 0 }), resolved: [WritingField: WritingField] = [:]
                    for field in pending { resolved[field] = field }
                    while let field = pending.popLast() {
                        let sink = resolved[field]!
                        for predecessor in predecessors[field] ?? [] {
                            guard resolved[predecessor] == nil || resolved[predecessor] == sink else {
                                throw EditorError.invalidDocument("Overlapping rollback heads require reconciliation")
                            }
                            resolved[predecessor] = sink; remaining[predecessor]! -= 1
                            if remaining[predecessor] == 0 { pending.append(predecessor) }
                        }
                    }
                    let sinks = Set(resolved.values)
                    guard resolved.count == fields.count, remaining.values.allSatisfy({ $0 == 0 }), sinks.count == 1 else {
                        throw EditorError.invalidDocument("Overlapping rollback cycle requires reconciliation")
                    }
                    destination = sinks.first!
                }
                for field in fields where field != destination { aliases[field] = destination }
            }
        }
        if retained != nil {
            for change in changes where active[change.id] ?? true {
                guard case .edit(let operations) = change.body else { continue }
                for operation in operations {
                    if case .schemaConvert(let conversion) = operation, conversion.source.node != conversion.node,
                       let item = structure.nodes[conversion.source.node] {
                        guard item.fields.filter({ $0.key != "id" && $0.key != "content" }) == conversion.preservedItemFields.filter({ $0.key != "children" }) else {
                            throw EditorError.invalidDocument("Converted item metadata requires reconciliation")
                        }
                    }
                }
            }
            // A collapsed item retains its child collection as an opaque
            // paragraph extension. Reparent only the projection, preserving all
            // original child placements and origins in replay/undo history.
            for change in changes where active[change.id] ?? true {
                guard case .edit(let operations) = change.body else { continue }
                for operation in operations {
                    guard case .schemaConvert(let conversion) = operation, conversion.source.node != conversion.node,
                          let item = structure.nodes[conversion.source.node],
                          item.collections.contains("children") || structure.placements.values.contains(where: { $0.collection == NodeCollection(owner: conversion.source.node, field: "children") }),
                          var root = structure.nodes[conversion.node] else { continue }
                    guard root.fields["children"] == nil || root.fields["children"] == .array([]) || root.collections.contains("children") else {
                        throw EditorError.invalidDocument("Collapsed child collection metadata requires reconciliation")
                    }
                    root.fields.removeValue(forKey: "children"); root.collections.insert("children")
                    structure.nodes[conversion.node] = root
                    let original = NodeCollection(owner: conversion.source.node, field: "children")
                    let destination = NodeCollection(owner: conversion.node, field: "children")
                    for (id, placement) in structure.placements where placement.collection == original {
                        structure.placements[id] = StructuralState.Placement(id: id, after: placement.after,
                            node: placement.node, collection: destination, active: placement.active,
                            rolePriority: placement.rolePriority, roleOrigin: placement.roleOrigin)
                    }
                }
            }
            // An inactive conversion must not hide peer-created items. Project
            // their retained origins into paragraphs beside the original root;
            // item properties/child arrays remain opaque paragraph extensions.
            var listRoots: [NodeID: NodeID] = [:]
            for change in changes {
                guard case .edit(let operations) = change.body else { continue }
                for operation in operations {
                    if case .schemaConvert(let conversion) = operation {
                        if conversion.type == "list" { listRoots[conversion.destination.node] = conversion.node }
                        if conversion.source.node != conversion.node { listRoots[conversion.source.node] = conversion.node }
                    }
                }
            }
            let selected = try structure.effectivePlacements()
            var afterByRoot: [NodeID: NodePlacementID] = [:]
            let entries = structure.placements.values.filter { $0.active }.sorted { $0.id < $1.id }
            for placement in entries {
                guard let owner = placement.collection.owner,
                      selected[placement.node]?.id == placement.id || (selected[placement.node] == nil && listRoots[owner] != nil) else { continue }
                let root: NodeID?
                if placement.collection.field == "items", structure.nodes[owner]?.kind == .block { root = owner }
                else if placement.collection.field == "children" { root = listRoots[owner] }
                else { root = nil }
                guard let root, structure.nodes[root]?.fields["type"] != .string("list"),
                      let rootPlacement = selected[root], var value = structure.nodes[placement.node],
                      value.birthActive, value.kind == .item, !structure.deleted.contains(placement.node) else { continue }
                let fallback = NodePlacementID.role(owner: root, node: placement.node)
                if let existing = structure.placements[fallback], existing.collection != rootPlacement.collection {
                    throw EditorError.invalidDocument("Peer item role owner moved between collections")
                }
                guard value.fields["type"] == nil || value.fields["type"] == .string("paragraph") else {
                    throw EditorError.invalidDocument("Peer item role metadata collision")
                }
                value.kind = .block; value.fields["type"] = .string("paragraph")
                structure.nodes[placement.node] = value
                for (key, old) in structure.placements where old.node == placement.node && old.active {
                    structure.placements[key] = StructuralState.Placement(id: old.id, after: old.after,
                        node: old.node, collection: old.collection, active: false, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
                }
                let after = afterByRoot[root] ?? rootPlacement.id
                structure.placements[fallback] = StructuralState.Placement(id: fallback, after: after,
                    node: placement.node, collection: rootPlacement.collection, active: true)
                afterByRoot[root] = fallback
            }
        }
        // Concurrent partitions may exhaust a retained owner or a new tail.
        // Preserve both accepted views rather than discard that owner's metadata
        // or choose a new public identity implicitly; either author can repair.
        var exits: [NodeID: (count: Int, tails: Set<NodeID>)] = [:]
        for change in changes where active[change.id] ?? true {
            guard case .edit(let operations) = change.body else { continue }
            for operation in operations {
                if case .exitListItem(_, let owner, _, _) = operation {
                    var entry = exits[owner] ?? (0, [])
                    entry.count += 1
                    for operation in operations {
                        if case .structure(.insertNode(let value, let identity, _, _, _)) = operation, value["type"] == .string("list") {
                            entry.tails.insert(identity)
                        }
                    }
                    exits[owner] = entry
                }
            }
        }
        for (owner, entry) in exits where entry.count > 1 {
            for node in entry.tails.union([owner]) where structure.nodes[node]?.fields["type"] == .string("list") {
                guard !(try structure.visibleOrder(in: NodeCollection(owner: node, field: "items"))).isEmpty else {
                    throw EditorError.invalidDocument("Concurrent exits require retained-owner reconciliation")
                }
            }
        }
        // Reconcile converted join sources from the final active shape,
        // independent of actor ordering. Inactive joins must remain valid
        // history so either author can repair the conflicting union.
        for edit in edits where active[edit.id] ?? true {
            for mutation in edit.mutations {
                if case .join(let source, _, _) = mutation,
                   let node = structure.nodes[source.node], node.kind == .block,
                   node.fields["type"] != .string("paragraph") {
                    throw EditorError.invalidDocument("Concurrent joined-source conversion")
                }
            }
        }
        return ProjectionInputs(structure: structure, seeds: seeds, fields: fields, hidden: hidden,
            births: births, active: active, edits: edits, aliases: aliases)
    }
    @inline(never) private static func assembleProjection(structure input: StructuralState,
        edits: [WritingEdit], inputs: ProjectionInputs,
        retained: [WritingField: WritingFieldBirth]?) throws -> (StructuralState, WritingProjection, [NodeID: [String: JSONValue]]) {
        var structure = input
        let seeds = inputs.seeds, active = inputs.active, fields = inputs.fields, births = inputs.births
        let hidden = inputs.hidden, aliases = inputs.aliases
        let projection = try WritingProjection(seeds: seeds, edits: edits, active: active, emptyFields: fields.union(births.keys), hiddenSeeds: hidden, redirects: aliases)
        let values = try projectedWritingValues(structure: &structure, projection: projection, seeds: seeds, fields: fields, births: births, retainedOrigins: retained != nil)
        for field in projection.joinedSources {
            if let node = structure.nodes[field.node], node.kind == .block,
               Set(node.fields.keys).isSubset(of: ["id", "type", "content"]), node.collections.isEmpty {
                structure.deleted.insert(field.node)
            }
        }
        return (structure, projection, values)
    }
    @inline(never) private static func orderedCuts(structure input: StructuralState, edits inputEdits: [WritingEdit],
        seeds: [WritingAtomSeed], active: [ChangeID: Bool], fields: Set<WritingField>, births: [WritingField: WritingFieldBirth],
        hidden: Set<WritingAtomKey>, aliases: [WritingField: WritingField], changes: [WritingChange],
        retained: [WritingField: WritingFieldBirth]?, protocolVersion: Int) throws -> (StructuralState, [WritingEdit]) {
        var structure = input, edits = inputEdits
        // Concurrent cuts partition the observed suffix at each original boundary.
        // An ordinary last-writer transfer would erase a different author's cut,
        // and sibling creation timestamps could reverse paragraph text order.
        struct Cut { let id: ChangeID; let source: WritingField; let destination: WritingField; let before: NodeID?; let rank: Int; let keys: Set<WritingAtomKey>; let members: [NodeID]?; let range: WritingRangeSplice?; let imported: WritingImportBoundary? }
        let ancestryEdits = edits.map { edit in
            WritingEdit(id: edit.id, mutations: edit.mutations.filter {
                switch $0 { case .transfer, .join, .splitBoundary, .spliceBoundary, .rangeSpliceBoundary, .importBoundary: return false; default: return true }
            })
        }
        var ancestry: WritingProjection?
        var cuts: [WritingField: [Cut]] = [:]
        for edit in edits where active[edit.id] ?? true {
            for mutation in edit.mutations {
                let descriptor: (WritingField, WritingField, WritingEdge, NodeID?, [NodeID]?, WritingRangeSplice?, WritingImportBoundary?)
                switch mutation {
                case .splitBoundary(let source, let destination, let edge, let before): descriptor = (source, destination, edge, before, nil, nil, nil)
                case .spliceBoundary(let source, let destination, let edge, let before, let members): descriptor = (source, destination, edge, before, members, nil, nil)
                case .rangeSpliceBoundary(let splice): descriptor = (splice.source, splice.destination, splice.edge, splice.before, splice.members, splice, nil)
                case .importBoundary(let boundary): descriptor = (boundary.source, boundary.source, boundary.edge, boundary.before, boundary.members, nil, boundary)
                default: continue
                }
                let (source, destination, edge, before, members, range, imported) = descriptor
                do {
                    let rank: Int
                    let pin = retained == nil ? nil : edit.mutations.compactMap { mutation -> WritingAtomKey? in
                        if case .transfer(let keys, let target, .start) = mutation, target == source { return keys.last }; return nil
                    }.last
                    if let anchor = pin ?? edge.anchor {
                        if ancestry == nil {
                            ancestry = try WritingProjection(seeds: seeds, edits: ancestryEdits, active: active, emptyFields: fields.union(births.keys), hiddenSeeds: hidden, redirects: aliases)
                        }
                        rank = try ancestry!.retainedOffset(of: anchor, affinity: {
                            if pin != nil { return .after }
                            if case .before = edge { return .before }; return .after
                        }())
                    } else { rank = 0 }
                    let keys = imported.map { Set($0.sourceKeys) } ?? edit.mutations.reduce(into: Set<WritingAtomKey>()) { span, mutation in
                        if case .transfer(let keys, let target, _) = mutation, target == destination { span.formUnion(keys) }
                    }
                    let origin = aliases[source] ?? source
                    cuts[origin, default: []].append(Cut(id: edit.id, source: origin, destination: destination, before: before, rank: rank, keys: keys, members: members, range: range, imported: imported))
                }
            }
        }
        if protocolVersion == 6 {
            // A later observed range can reuse an existing endpoint. Retire only
            // the older claim to that endpoint; its earlier imported members and
            // text routing remain retained history and reappear on author Undo.
            let rangeHistory = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
            let claims = Dictionary(grouping: cuts.values.flatMap { $0 }, by: \.destination)
            var retired: [WritingField: Set<ChangeID>] = [:]
            for (destination, group) in claims where group.count > 1 {
                let ranges = group.filter { $0.range != nil }.sorted { $1.id < $0.id }
                for later in ranges where retired[destination]?.contains(later.id) != true {
                    // Only competing claims need a cohort. A causal chain is
                    // covered by its newest surviving range's transitive cohort.
                    guard group.contains(where: { $0.id < later.id && retired[destination]?.contains($0.id) != true }) else { continue }
                    let observed = try observedClosure(rangeHistory[later.id]?.observed ?? [], before: later.id, in: rangeHistory)
                    for prior in group where observed.contains(prior.id) {
                        retired[destination, default: []].insert(prior.id)
                    }
                }
            }
            for origin in Array(cuts.keys) {
                cuts[origin] = cuts[origin]!.map { cut in
                    guard retired[cut.destination]?.contains(cut.id) == true else { return cut }
                    return Cut(id: cut.id, source: cut.source, destination: cut.destination, before: cut.before,
                        rank: cut.rank, keys: cut.keys, members: (cut.members ?? []).filter { $0 != cut.destination.node }, range: cut.range, imported: cut.imported)
                }
            }
        }
        let endpointClaims = cuts.values.flatMap { $0 }.filter { $0.members == nil || $0.members?.last == $0.destination.node }
        if retained != nil {
            let destinations = endpointClaims.map(\.destination)
            guard Set(destinations).count == destinations.count else {
                if protocolVersion == 6 { throw EditorError.invalidDocument("Overlapping retained splice endpoints") }
                throw EditorError.invalidChange
            }
        }
        let groupMembers = cuts.values.flatMap { $0 }.flatMap { $0.members ?? [] }
        guard Set(groupMembers).count == groupMembers.count else {
            if protocolVersion == 6 { throw EditorError.invalidDocument("Overlapping retained splice groups") }
            throw EditorError.invalidChange
        }
        let cutByDestination = endpointClaims.reduce(into: [WritingField: Cut]()) { $0[$1.destination] = $1 }
        if retained == nil {
            edits = edits.map { edit in
                WritingEdit(id: edit.id, mutations: edit.mutations.compactMap { mutation in
                    guard case .transfer(let keys, let destination, let edge) = mutation,
                          let cut = cutByDestination[destination] else { return mutation }
                    let retained = keys.filter { key in
                        let competitors = (cuts[cut.source] ?? []).filter { $0.keys.contains(key) }
                        let winner = competitors.max { lhs, rhs in lhs.rank == rhs.rank ? lhs.id < rhs.id : lhs.rank < rhs.rank }
                        return winner?.destination == destination
                    }
                    return retained.isEmpty ? nil : .transfer(keys: retained, destination: destination, edge: edge)
                })
            }
        } else {
            let history = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
            var observedBy: [ChangeID: Set<ChangeID>] = [:]
            let endpointPins = endpointClaims.reduce(into: [WritingField: Set<WritingAtomKey>]()) {
                if let range = $1.range { $0[range.destination, default: []].formUnion(range.endpointKeys) }
            }
            func observed(_ id: ChangeID) -> Set<ChangeID> {
                if let known = observedBy[id] { return known }
                var pending = history[id]?.observed ?? [], known = Set<ChangeID>()
                while let predecessor = pending.popLast() {
                    if known.insert(predecessor).inserted { pending.append(contentsOf: history[predecessor]?.observed ?? []) }
                }
                observedBy[id] = known; return known
            }
            edits = try edits.map { edit in
                WritingEdit(id: edit.id, mutations: try edit.mutations.flatMap { mutation -> [WritingMutation] in
                    guard case .transfer(let keys, let destination, let edge) = mutation else { return [mutation] }
                    let origin = aliases[destination] ?? destination
                    if protocolVersion == 6, let own = cutByDestination[destination], own.id == edit.id,
                       own.range != nil, endpointPins[destination]?.isEmpty == false,
                       keys.allSatisfy({ endpointPins[destination]?.contains($0) == true }) {
                        let competitors = (cuts[origin] ?? []).filter { $0.id != edit.id && !observed(edit.id).contains($0.id) && !observed($0.id).contains(edit.id) }
                        if !competitors.isEmpty, ancestry == nil {
                            ancestry = try WritingProjection(seeds: seeds, edits: ancestryEdits, active: active, emptyFields: fields.union(births.keys), hiddenSeeds: hidden, redirects: aliases)
                        }
                        var partitions: [WritingField: [WritingAtomKey]] = [:]
                        for key in keys {
                            let claiming = try competitors.filter { try ancestry!.follows(key, anyOf: $0.keys) }
                            let winner = claiming.max { lhs, rhs in lhs.rank == rhs.rank ? lhs.id < rhs.id : lhs.rank < rhs.rank }
                            partitions[winner?.destination ?? destination, default: []].append(key)
                        }
                        return partitions.keys.sorted { $0.key < $1.key }.map {
                            .transfer(keys: partitions[$0]!, destination: $0, edge: $0 == destination ? edge : .start)
                        }
                    }
                    if case .start = edge, let own = cuts[origin]?.first(where: { $0.id == edit.id }) {
                        // Pins express the source atoms this author observed. Reserve
                        // truly concurrent suffix ownership, including birth-route
                        // descendants, without blocking causal later pins after joins.
                        let competitors = (cuts[own.source] ?? []).filter { $0.id != edit.id && !observed(edit.id).contains($0.id) && !observed($0.id).contains(edit.id) }
                        if !competitors.isEmpty, ancestry == nil {
                            ancestry = try WritingProjection(seeds: seeds, edits: ancestryEdits, active: active, emptyFields: fields.union(births.keys), hiddenSeeds: hidden, redirects: aliases)
                        }
                        var partitions: [WritingField: [WritingAtomKey]] = [:]
                        for key in keys {
                            let claiming = try competitors.filter { try ancestry!.follows(key, anyOf: $0.keys) }
                            let winner = claiming.max { lhs, rhs in lhs.rank == rhs.rank ? lhs.id < rhs.id : lhs.rank < rhs.rank }
                            partitions[winner?.destination ?? destination, default: []].append(key)
                        }
                        return partitions.keys.sorted { $0.key < $1.key }.map { .transfer(keys: partitions[$0]!, destination: $0, edge: edge) }
                    }
                    guard let cut = cutByDestination[destination], retained == nil || cut.id == edit.id else { return [mutation] }
                    let retainedKeys = keys.filter { key in
                        let competitors = (cuts[cut.source] ?? []).filter { $0.keys.contains(key) }
                        let winner = competitors.max { lhs, rhs in lhs.rank == rhs.rank ? lhs.id < rhs.id : lhs.rank < rhs.rank }
                        return winner?.destination == destination
                    }
                    return retainedKeys.isEmpty ? [] : [.transfer(keys: retainedKeys, destination: destination, edge: edge)]
                })
            }
        }
        let selected = try structure.effectivePlacements()
        for (source, siblings) in cuts {
            let physicalGroups = siblings.filter { $0.members?.isEmpty != true }
            guard !physicalGroups.isEmpty else { continue }
            if retained != nil, siblings.count > 1 {
                let containers: Set<NodeCollection>
                if protocolVersion == 6 {
                    // A hierarchical import declares its own compatible target
                    // collection. It does not claim the ordinary source tail's
                    // physical container or require that tail to move with it.
                    containers = Set(physicalGroups.filter { $0.imported == nil }.flatMap { cut in
                        (cut.members ?? [cut.destination.node]).compactMap { member -> NodeCollection? in
                            guard let placement = selected[member] else { return nil }
                            if cut.members == nil, case .role(_, let node) = placement.id, node == member {
                                // Ordinary item cuts can retain their proven
                                // paragraph role after wrapper retirement.
                                return placement.collection
                            }
                            let expected: NodePlacementID
                            if let range = cut.range, member == range.destination.node { expected = .edit(range.destinationPlacement) }
                            else if case .inserted(let creation, _) = member { expected = .edit(creation) }
                            else { return nil }
                            // A superseded endpoint or independent later move
                            // does not belong to this physical birth group.
                            return placement.id == expected ? placement.collection : nil
                        }
                    })
                } else { containers = Set(siblings.compactMap { selected[$0.destination.node]?.collection }) }
                guard containers.count <= 1 else { throw EditorError.invalidDocument("Concurrent conversion cuts require reconciliation") }
            }
            guard let parent = selected[source.node] ?? aliases[source].flatMap({ selected[$0.node] }) ?? siblings.first(where: { $0.range != nil }).flatMap({ structure.placements[$0.range!.sourcePlacement] }) ?? siblings.first(where: { $0.imported != nil }).flatMap({ structure.placements[$0.imported!.sourcePlacement] }) else { throw EditorError.invalidPath }
            let physicalGroupsByCollection: [[Cut]]
            if protocolVersion == 6, physicalGroups.contains(where: { $0.imported != nil }) {
                let grouped = Dictionary(grouping: physicalGroups) { $0.imported?.collection ?? parent.collection }
                // Only physical birth chains are partitioned. All descriptors
                // still share the source's retained rank/atom arbitration above.
                physicalGroupsByCollection = grouped.keys.sorted {
                    let lhs = ($0.owner?.key ?? "", $0.field), rhs = ($1.owner?.key ?? "", $1.field)
                    return lhs < rhs
                }.map { grouped[$0]! }
            } else { physicalGroupsByCollection = [physicalGroups] }
            for physicalGroup in physicalGroupsByCollection {
                var previous: NodePlacementID? = parent.id
                var currentCollection = parent.collection
                var ordered: [Cut] = []
                let ranks = Dictionary(grouping: physicalGroup, by: \.rank)
                for rank in ranks.keys.sorted() {
                    let cuts = ranks[rank]!, byNode = Dictionary(uniqueKeysWithValues: cuts.flatMap { cut in
                        (cut.members ?? [(cut.members?.last ?? cut.destination.node)]).map { ($0, cut) }
                    })
                    var predecessors: [NodeID: Int] = [:], followers: [NodeID: [NodeID]] = [:]
                    for cut in cuts {
                        if let next = cut.before, let group = byNode[next] {
                            predecessors[(group.members?.last ?? group.destination.node), default: 0] += 1
                            followers[(cut.members?.last ?? cut.destination.node), default: []].append((group.members?.last ?? group.destination.node))
                        }
                    }
                    var ready = cuts.filter { predecessors[($0.members?.last ?? $0.destination.node), default: 0] == 0 }.sorted { $1.id < $0.id }
                    var count = 0
                    while let cut = ready.popLast() {
                        ordered.append(cut); count += 1
                        for next in followers[(cut.members?.last ?? cut.destination.node)] ?? [] {
                            predecessors[next, default: 0] -= 1
                            if predecessors[next] == 0 { ready.append(byNode[next]!); ready.sort { $1.id < $0.id } }
                        }
                    }
                    guard count == cuts.count else { throw WritingProjectionError.placementCycle }
                }
                for cut in ordered {
                    let targetCollection = cut.imported?.collection ?? parent.collection
                    if targetCollection != currentCollection {
                        currentCollection = targetCollection
                        previous = cut.imported?.after ?? parent.id
                        if cut.imported != nil { previous = cut.imported!.after }
                    }
                    if let members = cut.members {
                        for member in members {
                            let birth: StructuralState.Placement
                            if let range = cut.range, member == range.destination.node {
                                guard let exact = structure.placements[.edit(range.destinationPlacement)] else { throw EditorError.invalidChange }; birth = exact
                            } else {
                                guard case .inserted(let creation, _) = member,
                                      let exact = structure.placements[.edit(creation)] else { throw EditorError.invalidChange }; birth = exact
                            }
                            // A later independent placement stays authoritative. Only
                            // the original birth participates in this cut ordering.
                            guard let placement = selected[member], placement.id == birth.id else { continue }
                            guard placement.collection == targetCollection else {
                                throw EditorError.invalidDocument("Splice boundary ownership requires reconciliation")
                            }
                            structure.placements[placement.id] = StructuralState.Placement(id: placement.id, after: previous,
                                node: placement.node, collection: placement.collection, active: placement.active)
                            previous = placement.id
                        }
                        continue
                    }
                    guard case .inserted(let creation, _) = cut.destination.node,
                          let placement = selected[cut.destination.node],
                          placement.id == .edit(creation) || (retained != nil && {
                              if case .role(_, let node) = placement.id { return node == cut.destination.node }; return false
                          }()),
                          placement.collection == parent.collection else { continue }
                    structure.placements[placement.id] = StructuralState.Placement(id: placement.id, after: previous,
                        node: placement.node, collection: placement.collection, active: placement.active)
                    previous = placement.id
                }
            }
        }
        return (structure, edits)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
}

func validToken(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (33...126).contains($0) } }

private func writingScalarBoundary(_ offset: Int, in text: String) -> Bool {
    if offset == 0 { return true }
    var cursor = 0
    for scalar in text.unicodeScalars {
        cursor += scalar.value > 0xffff ? 2 : 1
        if cursor == offset { return true }
        if cursor > offset { return false }
    }
    return false
}

private func writingFields(_ node: StructuralState.Node) -> [String] {
    let names: [String]
    switch node.kind {
    case .item, .cell: names = ["content"]
    case .row, .column: names = []
    case .document: names = ["title"]
    case .block:
        switch node.fields["type"]?.string {
        case "paragraph", "quote", "heading", "callout": names = ["content"]
        case "toggle": names = ["summary"]
        case "image": names = ["caption"]
        case "code": names = ["code"]
        case "math": names = ["expression"]
        default: names = []
        }
    }
    return names.filter { node.fields[$0] != nil }
}

/// Lossless conversion targets. Protocol 3 supports the same-content family
/// and list styles; list/code schema changes require an explicit protocol 4 epoch.
public struct WritingBlockTarget: Codable, Equatable, Sendable {
    public let type: String
    public let level: Int?
    public let style: String?
    public let variant: String?
    public init(type: String, level: Int? = nil, style: String? = nil, variant: String? = nil) {
        self.type = type; self.level = level; self.style = style; self.variant = variant
    }
}

extension WritingSession {
    private func requireAuthoredType(_ type: String) throws {
        if let allowedBlockTypes, !allowedBlockTypes.contains(type) { throw EditorError.restrictedBlock(type) }
    }
    private func listOwner(of item: NodeID) throws -> NodeID {
        let placements = try structure.effectivePlacements()
        var current = item, visited = Set<NodeID>()
        while let owner = placements[current]?.collection.owner {
            guard visited.insert(owner).inserted else { throw EditorError.invalidPath }
            if structure.nodes[owner]?.fields["type"] == .string("list"), structure.nodes[owner]?.kind == .block { return owner }
            guard structure.nodes[owner]?.kind == .item else { throw EditorError.invalidPath }
            current = owner
        }
        throw EditorError.invalidPath
    }
    private func conversion(at address: TextAddress, target: WritingBlockTarget) throws -> WritingOperation {
        let source = try field(address).node
        let owner = structure.nodes[source]?.kind == .item && target.type == "list" ? try listOwner(of: source) : source
        guard let value = structure.nodes[owner], value.kind == .block else { throw EditorError.invalidChange }
        let inline = ["paragraph", "heading", "quote", "callout"]
        guard (inline.contains(value.fields["type"]?.string ?? "") && inline.contains(target.type)) || (value.fields["type"] == .string("list") && target.type == "list") else { throw EditorError.invalidChange }
        try requireAuthoredType(target.type)
        var attributes: [String: JSONValue] = [:]
        if target.type == "heading" { attributes["level"] = .number(Double(target.level ?? 1)) }
        if target.type == "callout" { attributes["variant"] = .string(target.variant ?? "info") }
        if target.type == "list" { attributes["style"] = .string(target.style ?? "unordered") }
        for (key, attribute) in attributes {
            guard value.fields["type"]?.string == conversionAttributeOwner(key) || value.fields[key] == nil || value.fields[key] == attribute else { throw EditorError.invalidChange }
        }
        return .convertBlock(node: owner, type: target.type, attributes: attributes)
    }
    @discardableResult public func convertBlock(at address: TextAddress, offset: Int, to target: WritingBlockTarget) throws -> WritingPosition {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        let caret = try position(at: address, offset: offset)
        let source = try field(address)
        if usesRetainedOrigins,
           target.type == "code" || (target.type == "list" && structure.nodes[source.node]?.kind == .block) ||
           (structure.nodes[source.node]?.fields["type"] == .string("code")) ||
           (structure.nodes[source.node]?.kind == .item && target.type != "list") {
            let id = try nextID(), operation = try schemaConversion(at: address, target: target, id: id)
            try perform(id, retainedRoleOperations(for: [source.node]) + [.schemaConvert(operation)])
            return caret
        }
        let operation = try conversion(at: address, target: target)
        try perform(nextID(), retainedRoleOperations(for: [source.node]) + [operation])
        return caret
    }
    /// Apply a recognized prefix in one author transaction. Unsupported list and
    /// code prefixes leave the paragraph, history and caret untouched.
    @discardableResult public func markdownShortcut(at address: TextAddress, offset: Int) throws -> WritingPosition {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        let prefix = try selection(address, 0..<offset)
        guard structure.nodes[prefix.field.node]?.fields["type"] == .string("paragraph"),
              try prefix.keys.allSatisfy({ try atom($0)["type"] == .string("text") }) else { throw EditorError.invalidChange }
        let literal = try prefix.keys.map { try atom($0)["text"]?.string ?? "" }.joined()
        let target: WritingBlockTarget
        switch literal {
        case "# ": target = WritingBlockTarget(type: "heading", level: 1)
        case "## ": target = WritingBlockTarget(type: "heading", level: 2)
        case "### ": target = WritingBlockTarget(type: "heading", level: 3)
        case "> ": target = WritingBlockTarget(type: "quote")
        case "- " where usesRetainedOrigins: target = WritingBlockTarget(type: "list", style: "unordered")
        case "1. " where usesRetainedOrigins: target = WritingBlockTarget(type: "list", style: "ordered")
        case "[ ] " where usesRetainedOrigins: target = WritingBlockTarget(type: "list", style: "todo")
        case "- [ ] " where usesRetainedOrigins: target = WritingBlockTarget(type: "list", style: "todo")
        case "```" where usesRetainedOrigins: target = WritingBlockTarget(type: "code")
        default: throw EditorError.invalidChange
        }
        let id = try nextID(), caret = try position(at: address, offset: offset)
        let operation: WritingOperation = usesRetainedOrigins && ["list", "code"].contains(target.type)
            ? .schemaConvert(try schemaConversion(at: address, target: target, id: id))
            : try conversion(at: address, target: target)
        try perform(id, retainedRoleOperations(for: [prefix.field.node]) + [operation, .text(.delete(keys: prefix.keys))])
        return caret
    }
    /// Return moves an empty nested item outward; otherwise it splits the item.
    /// An empty final root item can exit after prior items without replacing the
    /// list owner's identity or discarding its extension metadata.
    @discardableResult public func enterListItem(at address: TextAddress, range: Range<Int>, newItemID: String) throws -> WritingPosition {
        guard usesRetainedOrigins else { throw EditorError.unsupportedVersion(protocolVersion) }
        guard !isComposing else { throw WritingSessionError.compositionActive }
        let selected = try selection(address, range), source = selected.field.node
        guard selected.field.name == "content", let value = structure.nodes[source], value.kind == .item else { throw EditorError.invalidPath }
        if protocolVersion == 3 { try requireAuthoredType("list") }
        let owner = try listOwner(of: source), placements = try structure.effectivePlacements()
        guard let parent = placements[source] else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: parent.collection)
        guard let index = siblings.firstIndex(of: source) else { throw EditorError.invalidPath }
        let empty = projection.nodes(in: selected.field).allSatisfy { $0["type"] == .string("text") && ($0["text"]?.string ?? "").isEmpty }
        if empty, range.isEmpty {
            if let immediate = parent.collection.owner, structure.nodes[immediate]?.kind == .item {
                guard let outer = placements[immediate] else { throw EditorError.invalidPath }
                guard !(try structure.visibleOrder(in: outer.collection)).contains(where: { $0 != source && structure.nodes[$0]?.label == value.label }) else { throw EditorError.invalidChange }
                let id = try nextID(), placement = ElementID(change: id, index: 0)
                try perform(id, [.structure(.moveNode(identity: source, collection: outer.collection, placement: placement, after: outer.id))])
                return selected.position
            }
            if usesRetainedOrigins, siblings.count == 1 {
                let id = try nextID(), operation = try schemaConversion(at: address, target: WritingBlockTarget(type: "paragraph"), id: id)
                try perform(id, [.schemaConvert(operation)])
                return selected.position
            }
            guard siblings.count > 1, let listPlacement = placements[owner] else { throw EditorError.invalidChange }
            try requireAuthoredType("paragraph")
            guard !value.fields.keys.contains("type"),
                  !structure.placements.values.contains(where: { $0.collection == listPlacement.collection && $0.node != owner && $0.node != source && structure.nodes[$0.node]?.label == value.label }) else { throw EditorError.invalidChange }
            let id = try nextID(), role = NodePlacementID.role(owner: owner, node: source)
            var operations: [WritingOperation] = [.exitListItem(node: source, owner: owner, source: parent.id,
                after: listPlacement.id)]
            if index == 0 {
                // Keep the original list owner as the tail, and move its root
                // placement after the exiting first item's retained role.
                operations.append(.structure(.moveNode(identity: owner, collection: listPlacement.collection,
                    placement: ElementID(change: id, index: 0), after: role)))
            } else if index + 1 < siblings.count {
                try requireAuthoredType("list")
                guard !newItemID.isEmpty, newItemID != value.label,
                      !structure.placements.values.contains(where: { $0.collection == listPlacement.collection && structure.nodes[$0.node]?.label == newItemID }) else { throw EditorError.invalidChange }
                let creation = ElementID(change: id, index: 0), tail = NodeID.inserted(creation: creation, path: [])
                var fields = structure.nodes[owner]!.fields
                fields["id"] = .string(newItemID); fields["items"] = .array([])
                operations.append(.structure(.insertNode(value: .object(fields), identity: tail,
                    collection: listPlacement.collection, placement: creation, after: role)))
                var after: NodePlacementID?
                for (offset, item) in siblings[(index + 1)...].enumerated() {
                    let placement = ElementID(change: id, index: offset + 1)
                    operations.append(.structure(.moveNode(identity: item, collection: NodeCollection(owner: tail, field: "items"),
                        placement: placement, after: after)))
                    after = .edit(placement)
                }
            }
            try perform(id, operations)
            return selected.position
        }
        if usesRetainedOrigins { try requireAuthoredType("list") }
        guard !newItemID.isEmpty, !siblings.contains(where: { structure.nodes[$0]?.label == newItemID }) else { throw EditorError.invalidChange }
        let id = try nextID(), creation = ElementID(change: id, index: 0), destinationNode = NodeID.inserted(creation: creation, path: [])
        let destination = WritingField(node: destinationNode, name: "content")
        var fields = value.fields; fields["id"] = .string(newItemID); fields["content"] = .array([])
        if structure.nodes[owner]?.fields["style"] == .string("todo") { fields["checked"] = .bool(false) }
        if value.collections.contains("children") { fields["children"] = .array([]) }
        let next = index + 1 < siblings.count ? siblings[index + 1] : nil
        var operations: [WritingOperation] = [.structure(.insertNode(value: .object(fields), identity: destinationNode, collection: parent.collection, placement: creation, after: parent.id)),
            .text(.splitBoundary(source: selected.field, destination: destination, edge: selected.edge, before: next))]
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
        // Observed prefix atoms can themselves be anchored before a suffix atom.
        // Pin those known atoms to the source before moving the suffix, so native
        // committed composition does not follow its old anchor into the new field.
        if usesRetainedOrigins {
            let prefix = try selection(address, 0..<range.lowerBound).keys
            if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: selected.field, edge: .start))) }
        }
        let suffix = try selection(address, range.upperBound..<projection.text(in: selected.field).utf16.count).keys
        if !suffix.isEmpty { operations.append(.text(.transfer(keys: suffix, destination: destination, edge: .start))) }
        try perform(id, operations)
        return WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: suffix.first, affinity: suffix.isEmpty ? .after : .before)
    }
}

/// Schema-changing authoring is isolated to an explicit v4 epoch. Birth fields
/// remain immutable even when the live block uses a different text encoding.
public struct WritingSchemaConversion: Codable, Equatable, Sendable {
    public let node: NodeID
    public let type: String
    public let attributes: [String: JSONValue]
    public let source: WritingField
    public let destination: WritingField
    public let itemID: String?
    public let creation: ElementID?
    public let preservedItemFields: [String: JSONValue]
}
private func conversionAttributeOwner(_ name: String) -> String? {
    switch name {
    case "level": return "heading"
    case "variant": return "callout"
    case "style": return "list"
    case "language": return "code"
    default: return nil
    }
}
struct WritingFieldBirth {
    let value: JSONValue
    let active: Bool
}
func retainedWritingFields(_ structure: StructuralState) -> [WritingField: WritingFieldBirth] {
    var result: [WritingField: WritingFieldBirth] = [:]
    for (identity, node) in structure.nodes {
        for name in writingFields(node) {
            result[WritingField(node: identity, name: name)] = WritingFieldBirth(value: node.fields[name]!, active: node.birthActive)
        }
    }
    return result
}
extension WritingSession {
    private func schemaConversion(at address: TextAddress, target: WritingBlockTarget, id: ChangeID) throws -> WritingSchemaConversion {
        guard usesRetainedOrigins else { throw EditorError.invalidChange }
        try requireAuthoredType(target.type)
        let source = try field(address)
        let root = structure.nodes[source.node]?.kind == .item ? try listOwner(of: source.node) : source.node
        guard let node = structure.nodes[root], node.kind == .block,
              ["paragraph", "heading", "quote", "callout", "list", "code"].contains(node.fields["type"]?.string ?? ""),
              ["paragraph", "heading", "quote", "callout", "list", "code"].contains(target.type) else { throw EditorError.invalidChange }
        var preserved: [String: JSONValue] = [:]
        if node.fields["type"] == .string("list") {
            let items = try structure.visibleOrder(in: NodeCollection(owner: root, field: "items"))
            guard items == [source.node], let item = structure.nodes[source.node] else { throw EditorError.invalidChange }
            // Unknown item properties are retained only where the root has no
            // conflicting value. No overwrite can make a conversion lossless.
            for (key, value) in item.fields where key != "id" && key != "content" {
                guard !["type", "code", "summary", "caption", "expression", "items", "rows"].contains(key),
                      node.fields[key] == nil || node.fields[key] == value else { throw EditorError.invalidChange }
                preserved[key] = value
            }
            if item.collections.contains("children") {
                guard node.fields["children"] == nil || node.fields["children"] == .array([]) else { throw EditorError.invalidChange }
                preserved["children"] = .array([])
            }
        }
        if target.type == "code" {
            guard projection.nodes(in: source).allSatisfy({
                $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty &&
                Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"])
            }) else { throw EditorError.invalidChange }
        }
        var attributes: [String: JSONValue] = [:]
        if target.type == "heading" { attributes["level"] = .number(Double(target.level ?? 1)) }
        if target.type == "callout" { attributes["variant"] = .string(target.variant ?? "info") }
        if target.type == "list" {
            guard node.fields["items"] == nil, node.fields["type"] != .string("list") else { throw EditorError.invalidChange }
            attributes["style"] = .string(target.style ?? "unordered")
            guard node.fields["style"] == nil || node.fields["style"] == attributes["style"] else { throw EditorError.invalidChange }
            let creation = ElementID(change: id, index: 0)
            return WritingSchemaConversion(node: root, type: target.type, attributes: attributes, source: source,
                destination: WritingField(node: .inserted(creation: creation, path: []), name: "content"),
                itemID: node.label + "-item", creation: creation, preservedItemFields: [:])
        }
        for (key, attribute) in attributes {
            let previous = preserved[key] ?? node.fields[key]
            guard node.fields["type"]?.string == conversionAttributeOwner(key) || previous == nil || previous == attribute else { throw EditorError.invalidChange }
        }
        let name = target.type == "code" ? "code" : "content"
        guard name == source.name && root == source.node || node.fields[name] == nil else { throw EditorError.invalidChange }
        return WritingSchemaConversion(node: root, type: target.type, attributes: attributes, source: source,
            destination: WritingField(node: root, name: name), itemID: nil, creation: nil, preservedItemFields: preserved)
    }
}

/// A later structural command explicitly retains a paragraph role exposed by a
/// known schema retirement. Its anchor is distinct from the node birth anchor.
public struct WritingParagraphRole: Codable, Equatable, Sendable {
    public let node: NodeID
    public let owner: NodeID
    public let retirement: ChangeID
    public let exposure: [ChangeID]
    public let after: NodePlacementID?
    public init(node: NodeID, owner: NodeID, retirement: ChangeID, exposure: [ChangeID], after: NodePlacementID?) {
        self.node = node; self.owner = owner; self.retirement = retirement; self.exposure = exposure; self.after = after
    }
}
private func retirement(_ change: WritingChange, belongsTo owner: NodeID, node: NodeID? = nil, in changes: [ChangeID: WritingChange]) -> Bool {
    switch change.body {
    case .edit(let operations):
        return operations.contains { operation in
            if case .schemaConvert(let conversion) = operation { return conversion.node == owner && conversion.type != "list" && conversion.source.node != owner }
            if case .exitListItem(let exited, let wrapper, _, _) = operation { return wrapper == owner && exited == node }
            return false
        }
    case .setActive(let target, let enabled):
        guard !enabled, let original = changes[target], case .edit(let operations) = original.body else { return false }
        return operations.contains { operation in
            if case .schemaConvert(let conversion) = operation { return conversion.node == owner && conversion.type == "list" }
            return false
        }
    }
}
extension WritingSession {
    private func retainedRoleOperations(for identities: [NodeID]) throws -> [WritingOperation] {
        guard usesRetainedOrigins else { return [] }
        let selected = try structure.effectivePlacements()
        var visiting = Set<NodeID>(), done = Set<NodeID>(), result: [WritingOperation] = []
        func visit(_ identity: NodeID) throws {
            guard !done.contains(identity), let placement = selected[identity], case .role(let owner, let node) = placement.id else { return }
            guard visiting.insert(identity).inserted else { throw EditorError.invalidChange }
            guard node == identity, let proof = log.values.sorted(by: { $1.id < $0.id }).first(where: {
                      retirement($0, belongsTo: owner, node: identity, in: log)
                  }) else { throw EditorError.invalidChange }
            let after = placement.after
            if let after, case .role(_, let predecessor) = after, selected[predecessor]?.id == after { try visit(predecessor) }
            let prior = log.values.sorted(by: { $1.id < $0.id }).compactMap { change -> WritingParagraphRole? in
                guard case .edit(let operations) = change.body else { return nil }
                return operations.compactMap { operation -> WritingParagraphRole? in
                    if case .retainParagraphRole(let role) = operation, role.node == identity, role.owner == owner { return role }
                    return nil
                }.first
            }.first
            result.append(.retainParagraphRole(WritingParagraphRole(node: identity, owner: owner,
                retirement: prior?.retirement ?? proof.id, exposure: prior?.exposure ?? observedFrontier(log), after: after)))
            visiting.remove(identity); done.insert(identity)
        }
        for identity in Set(identities).sorted(by: { $0.key < $1.key }) { try visit(identity) }
        return result
    }
}

private func observedFrontier(_ changes: [ChangeID: WritingChange]) -> [ChangeID] {
    var tips: [String: ChangeID] = [:]
    for id in changes.keys where tips[id.actor].map({ $0 < id }) ?? true { tips[id.actor] = id }
    return tips.values.sorted()
}
private func observedClosure(_ frontier: [ChangeID], before current: ChangeID, in changes: [ChangeID: WritingChange]) throws -> Set<ChangeID> {
    var found = Set<ChangeID>(), pending = frontier
    try validateObservedFrontier(frontier, before: current)
    while let id = pending.popLast() {
        guard found.insert(id).inserted else { continue }
        guard let predecessor = changes[id] else { throw WritingProjectionError.missingAtom }
        guard let observed = predecessor.observed else { throw EditorError.invalidChange }
        try validateObservedFrontier(observed, before: id)
        pending.append(contentsOf: observed)
    }
    return found
}

func validateObservedFrontier(_ ids: [ChangeID], before bound: ChangeID) throws {
    guard ids.count <= 100_000, ids == ids.sorted(), Set(ids.map(\.actor)).count == ids.count,
          ids.allSatisfy({ $0.counter > 0 && $0.counter <= 9_007_199_254_740_991 && validToken($0.actor) && $0 < bound }) else { throw EditorError.invalidChange }
}
