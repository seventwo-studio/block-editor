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
}
public enum WritingChangeBody: Codable, Equatable, Sendable {
    case edit([WritingOperation])
    case setActive(target: ChangeID, active: Bool)
}
public struct WritingChange: Codable, Equatable, Sendable {
    public let id: ChangeID
    public let body: WritingChangeBody
    public init(id: ChangeID, body: WritingChangeBody) { self.id = id; self.body = body }
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

/// Experimental v3 writing facade. It shares document validation and structural
/// replay with the core. Callers explicitly select an epoch; v1/v2 are unchanged.
/// Confine it to one executor and keep pending recovery separate from save().
public final class WritingSession {
    public let documentID: String
    public let actorID: String
    public let epoch: String
    public let baseline: Document
    public var onChange: ((Document, WritingChange?) -> Void)?
    public var onWillReceive: (() -> Void)?
    public var isComposing = false
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

    public init(documentID: String, actorID: String, epoch: String, document: Document) throws {
        guard !documentID.isEmpty, validToken(actorID), validToken(epoch) else { throw EditorError.invalidChange }
        let validated = try Document(blocks: document.blocks)
        guard try validated.json().count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        self.documentID = documentID; self.actorID = actorID; self.epoch = epoch; self.baseline = validated
        let raw = Materialized.seed(validated, version: 2)
        let result = try Self.project(raw: raw, changes: [])
        structure = result.0; projection = result.1; self.document = result.2
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var syncState: WritingSyncState { WritingSyncState(documentID: documentID, epoch: epoch, received: log.keys.sorted()) }
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
    /// Resolve a rejected union by explicitly disabling one accepted transaction
    /// of this author. Remote atoms and every original change remain in the log.
    public func repairUndo(_ target: ChangeID) throws {
        guard !preparingReceive, remoteHolds == 0, !isComposing, let recovery = mergeRecovery,
              target.actor == actorID, undoStack.contains(target) else { throw EditorError.invalidChange }
        var candidate = log
        for change in recovery.batch.changes { candidate[change.id] = change }
        let clock = candidate.keys.map(\.counter).max() ?? counter
        guard clock < 9_007_199_254_740_991 else { throw EditorError.invalidChange }
        let change = WritingChange(id: ChangeID(counter: clock + 1, actor: actorID), body: .setActive(target: target, active: false))
        candidate[change.id] = change
        try capacity(candidate)
        let result = try replay(candidate)
        preparingReceive = true; onWillReceive?(); preparingReceive = false
        accept(candidate, result, change: change)
    }
    public func changes(since receipt: WritingSyncState = WritingSyncState()) -> WritingBatch {
        let received = receipt.documentID == documentID && receipt.epoch == epoch && receipt.version == 3 ? Set(receipt.received) : []
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
        guard batch.version == 3 else { throw EditorError.unsupportedVersion(batch.version) }
        let session = try WritingSession(documentID: batch.documentID, actorID: actorID, epoch: batch.epoch, document: batch.baseline)
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
        guard incoming.version == 3 else { throw EditorError.unsupportedVersion(incoming.version) }
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
    public func resolve(_ position: WritingPosition) throws -> ResolvedWritingPosition {
        guard position.documentID == documentID, position.epoch == epoch else { throw WritingSessionError.incompatibleEpoch }
        if let anchor = position.anchor { guard anchor.element.index >= 0 else { throw EditorError.invalidChange } }
        let field = try position.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: position.field)
        _ = try structure.address(of: field.node)
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
        let selected = try selection(address, range), source = selected.field.node
        guard selected.field.name == "content", structure.nodes[source]?.fields["type"] == .string("paragraph") else { throw EditorError.invalidPath }
        let placements = try structure.effectivePlacements()
        guard let parent = placements[source] else { throw EditorError.invalidPath }
        let siblings = try structure.visibleOrder(in: parent.collection)
        guard let sourceIndex = siblings.firstIndex(of: source) else { throw EditorError.invalidPath }
        let nextSibling = sourceIndex + 1 < siblings.count ? siblings[sourceIndex + 1] : nil
        let id = try nextID(), creation = ElementID(change: id, index: 0), node = NodeID.inserted(creation: creation, path: [])
        let destination = WritingField(node: node, name: "content")
        let value: JSONValue = .object(["id": .string(newBlockID), "type": .string("paragraph"), "content": .array([])])
        var operations: [WritingOperation] = [.structure(.insertNode(value: value, identity: node, collection: parent.collection, placement: creation, after: parent.id))]
        operations.append(.text(.splitBoundary(source: selected.field, destination: destination, edge: selected.edge, before: nextSibling)))
        if !selected.keys.isEmpty { operations.append(.text(.delete(keys: selected.keys))) }
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
        try perform(nextID(), [.text(.join(source: source, destination: destination, edge: anchor.map(WritingEdge.after) ?? .start))])
        return WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: anchor, affinity: .after)
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
        var operations: [WritingOperation] = []
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
            var label: String
            repeat { serial += 1; label = "copy-\(actorID)-\(id.counter)-\(serial)" } while reserved.contains(label)
            reserved.insert(label); fields["id"] = .string(label)
            for (field, childKind) in StructuralState.collectionFields(kind, fields) {
                if let children = fields[field]?.array { fields[field] = .array(try children.map { try fresh($0, kind: childKind) }) }
            }
            return .object(fields)
        }
        var identities: [NodeID] = [], operations: [WritingOperation] = []
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
        guard let target = undoStack.last else { return }
        try toggle(target, false)
    }
    public func redo() throws {
        guard let target = redoStack.last else { return }
        try toggle(target, true)
    }
    private func perform(_ id: ChangeID, _ operations: [WritingOperation]) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        guard mergeRecovery == nil else { throw WritingSessionError.recoveryRequired(mergeRecovery!) }
        let change = WritingChange(id: id, body: .edit(operations)); var candidate = log; candidate[id] = change
        try capacity(candidate); let result = try replay(candidate)
        undoStack.append(id); redoStack.removeAll(); accept(candidate, result, change: change)
    }
    private func toggle(_ target: ChangeID, _ active: Bool) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        guard mergeRecovery == nil else { throw WritingSessionError.recoveryRequired(mergeRecovery!) }
        let change = WritingChange(id: try nextID(), body: .setActive(target: target, active: active)); var candidate = log; candidate[change.id] = change
        try capacity(candidate); let result = try replay(candidate)
        if active { redoStack.removeLast(); undoStack.append(target) }
        else { undoStack.removeLast(); redoStack.append(target) }
        accept(candidate, result, change: change)
    }
    private func accept(_ candidate: [ChangeID: WritingChange], _ result: (StructuralState, WritingProjection, Document), change: WritingChange?) {
        var winning: [ChangeID: (id: ChangeID, active: Bool)] = [:]
        for incoming in candidate.values {
            if case .setActive(let target, let enabled) = incoming.body,
               winning[target].map({ $0.id < incoming.id }) ?? true { winning[target] = (incoming.id, enabled) }
        }
        for (target, toggle) in winning.sorted(by: { $0.value.id < $1.value.id }) {
            if !toggle.active, let index = undoStack.firstIndex(of: target) { undoStack.remove(at: index); redoStack.append(target) }
            if toggle.active, let index = redoStack.firstIndex(of: target) { redoStack.remove(at: index); undoStack.append(target) }
        }
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
    private func batch(_ changes: [WritingChange]) -> WritingBatch { WritingBatch(documentID: documentID, epoch: epoch, baseline: baseline, changes: changes.sorted { $0.id < $1.id }) }
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
        let edge = next.map(WritingEdge.before) ?? previous.map(WritingEdge.after) ?? .start
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
    private func replay(_ candidate: [ChangeID: WritingChange]) throws -> (StructuralState, WritingProjection, Document) {
        let changes = candidate.values.sorted { $0.id < $1.id }
        var active: [ChangeID: Bool] = [:]
        var history: [ChangeID: Change] = [:]
        for change in changes {
            guard change.id.counter > 0, change.id.counter <= 9_007_199_254_740_991, validToken(change.id.actor) else { throw EditorError.invalidChange }
            switch change.body {
            case .edit(let operations):
                guard !operations.isEmpty, operations.count <= 100_000 else { throw EditorError.invalidChange }
                history[change.id] = Change(id: change.id, body: .edit(operations.compactMap {
                    if case .structure(let mutation) = $0 { return mutation }; return nil
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
            let structural = history[change.id]!
            if case .edit(let mutations) = structural.body, !mutations.isEmpty {
                do { try validate(structural, version: 2, structure: raw.structure, history: history, seedState: raw) }
                catch EditorError.invalidDocument { throw EditorError.invalidChange }
            }
            var introduced = Set<ElementID>()
            func node(_ identity: NodeID) throws {
                switch identity {
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
                guard writingFields(raw.structure!.nodes[field.node]!).contains(field.name) else { throw EditorError.invalidPath }
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
            for operation in operations {
                switch operation {
                case .structure(let mutation):
                    switch mutation {
                    case .insertNode(_, _, _, let placement, _), .moveNode(_, _, let placement, _):
                        guard introduced.insert(placement).inserted else { throw EditorError.invalidChange }
                    case .setNodeField, .deleteNodes: break
                    default: throw EditorError.invalidChange
                    }
                    try apply([mutation], enabled: active[change.id] ?? true, to: &raw)
                    available.formUnion(seededKeys(raw.structure!))
                case .text(let mutation):
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
                        guard source != destination, source.name == "content", destination.name == "content",
                              raw.structure?.nodes[source.node]?.fields["type"] == .string("paragraph"),
                              raw.structure?.nodes[destination.node]?.fields["type"] == .string("paragraph") else { throw EditorError.invalidChange }
                    case .splitBoundary(let source, let destination, let boundary, let before):
                        try field(source); try field(destination); try edge(boundary)
                        if let before { try node(before); guard before != destination.node else { throw EditorError.invalidChange } }
                        guard source != destination, source.name == "content", destination.name == "content",
                              raw.structure?.nodes[source.node]?.fields["type"] == .string("paragraph"),
                              raw.structure?.nodes[destination.node]?.fields["type"] == .string("paragraph"),
                              case .inserted(let creation, let path) = destination.node,
                              creation.change == change.id, path.isEmpty else { throw EditorError.invalidChange }
                    }
                }
            }
        }
        return try Self.project(raw: raw, changes: changes)
    }

    private static func project(raw: Materialized, changes: [WritingChange]) throws -> (StructuralState, WritingProjection, Document) {
        guard var structure = raw.structure else { throw EditorError.invalidChange }
        var seeds: [WritingAtomSeed] = [], fields = Set<WritingField>(), hidden = Set<WritingAtomKey>()
        for (identity, node) in structure.nodes {
            for name in writingFields(node) {
                let field = WritingField(node: identity, name: name)
                fields.insert(field)
                var previous: WritingAtomKey?, index = 0
                let value = node.fields[name]!
                for payload in value.array ?? value.string.map({ [textNode($0)] }) ?? [] {
                    let parts: [JSONValue]
                    if payload["type"] == .string("text") {
                        parts = (payload["text"]?.string ?? "").unicodeScalars.map {
                            var object = payload.object!; object["text"] = .string(String($0)); return .object(object)
                        }
                        if parts.isEmpty, value.array != nil {
                            let key = WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))
                            seeds.append(WritingAtomSeed(key: key, node: payload, edge: previous.map(WritingEdge.after) ?? .start, route: .field(field)))
                            if !node.birthActive { hidden.insert(key) }
                            previous = key; index += 1
                        }
                    } else { parts = [payload] }
                    for part in parts {
                        let key = WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))
                        seeds.append(WritingAtomSeed(key: key, node: part, edge: previous.map(WritingEdge.after) ?? .start, route: .field(field)))
                        if !node.birthActive { hidden.insert(key) }
                        previous = key; index += 1
                    }
                }
            }
        }
        var active: [ChangeID: Bool] = [:], edits: [WritingEdit] = []
        for change in changes {
            switch change.body {
            case .setActive(let target, let enabled): active[target] = enabled
            case .edit(let operations):
                edits.append(WritingEdit(id: change.id, mutations: operations.compactMap { if case .text(let mutation) = $0 { return mutation }; return nil }))
            }
        }
        // Concurrent cuts partition the observed suffix at each original boundary.
        // An ordinary last-writer transfer would erase a different author's cut,
        // and sibling creation timestamps could reverse paragraph text order.
        struct Cut { let id: ChangeID; let source: WritingField; let destination: WritingField; let before: NodeID?; let rank: Int; let keys: Set<WritingAtomKey> }
        let ancestryEdits = edits.map { edit in
            WritingEdit(id: edit.id, mutations: edit.mutations.filter {
                switch $0 { case .transfer, .join, .splitBoundary: return false; default: return true }
            })
        }
        let ancestry = try WritingProjection(seeds: seeds, edits: ancestryEdits, active: active, emptyFields: fields, hiddenSeeds: hidden)
        var cuts: [WritingField: [Cut]] = [:]
        for edit in edits where active[edit.id] ?? true {
            for mutation in edit.mutations {
                if case .splitBoundary(let source, let destination, let edge, let before) = mutation {
                    let rank = try edge.anchor.map { try ancestry.retainedOffset(of: $0, affinity: {
                        if case .before = edge { return .before }; return .after
                    }()) } ?? 0
                    let keys = edit.mutations.reduce(into: Set<WritingAtomKey>()) { span, mutation in
                        if case .transfer(let keys, let target, _) = mutation, target == destination { span.formUnion(keys) }
                    }
                    cuts[source, default: []].append(Cut(id: edit.id, source: source, destination: destination, before: before, rank: rank, keys: keys))
                }
            }
        }
        let cutByDestination = cuts.values.flatMap { $0 }.reduce(into: [WritingField: Cut]()) { $0[$1.destination] = $1 }
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
        let selected = try structure.effectivePlacements()
        for (source, siblings) in cuts {
            guard let parent = selected[source.node] else { throw EditorError.invalidPath }
            var previous = parent.id
            var ordered: [Cut] = []
            let ranks = Dictionary(grouping: siblings, by: \.rank)
            for rank in ranks.keys.sorted() {
                let cuts = ranks[rank]!, byNode = Dictionary(uniqueKeysWithValues: cuts.map { ($0.destination.node, $0) })
                var predecessors: [NodeID: Int] = [:], followers: [NodeID: [NodeID]] = [:]
                for cut in cuts {
                    if let next = cut.before, byNode[next] != nil {
                        predecessors[next, default: 0] += 1
                        followers[cut.destination.node, default: []].append(next)
                    }
                }
                var ready = cuts.filter { predecessors[$0.destination.node, default: 0] == 0 }.sorted { $1.id < $0.id }
                var count = 0
                while let cut = ready.popLast() {
                    ordered.append(cut); count += 1
                    for next in followers[cut.destination.node] ?? [] {
                        predecessors[next, default: 0] -= 1
                        if predecessors[next] == 0 { ready.append(byNode[next]!); ready.sort { $1.id < $0.id } }
                    }
                }
                guard count == cuts.count else { throw WritingProjectionError.placementCycle }
            }
            for cut in ordered {
                guard case .inserted(let creation, _) = cut.destination.node,
                      let placement = selected[cut.destination.node], placement.id == .edit(creation),
                      placement.collection == parent.collection else { continue }
                structure.placements[placement.id] = StructuralState.Placement(id: placement.id, after: previous,
                    node: placement.node, collection: placement.collection, active: placement.active)
                previous = placement.id
            }
        }
        let projection = try WritingProjection(seeds: seeds, edits: edits, active: active, emptyFields: fields, hiddenSeeds: hidden)
        var values: [NodeID: [String: JSONValue]] = [:]
        for field in fields {
            let nodes = projection.nodes(in: field)
            if !nodes.isEmpty { structure.touched.insert(field.node) }
            // Preserve exact baseline JSON for untouched fields, including empty
            // text runs and host extensions that have no visible scalar atoms.
            let original = structure.nodes[field.node]!.fields[field.name]!
            let baselineNodes = seeds.filter { $0.key.origin == field }.map(\.node)
            if nodes == baselineNodes, structure.nodes[field.node]!.birthActive { continue }
            var runs: [JSONValue] = []
            for node in nodes {
                if node["type"] == .string("text"), var last = runs.last?.object, last["type"] == .string("text") {
                    var lhs = last, rhs = node.object!
                    lhs.removeValue(forKey: "text"); rhs.removeValue(forKey: "text")
                    if lhs == rhs {
                        last["text"] = .string((last["text"]?.string ?? "") + (node["text"]?.string ?? ""))
                        runs[runs.count - 1] = .object(last); continue
                    }
                }
                runs.append(node)
            }
            values[field.node, default: [:]][field.name] = original.string == nil ? .array(runs) : .string(plainText(runs))
        }
        for field in projection.joinedSources {
            if let node = structure.nodes[field.node], node.kind == .block,
               Set(node.fields.keys).isSubset(of: ["id", "type", "content"]), node.collections.isEmpty {
                structure.deleted.insert(field.node)
            }
        }
        let document = try structure.document(text: values)
        guard try document.json().count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        return (structure, projection, document)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(value)) }
}

private func validToken(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (33...126).contains($0) } }

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
    case .row: names = []
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
