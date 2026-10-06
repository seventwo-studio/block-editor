import Foundation

/// Confine a session to one executor. Hosts choose their own storage and transport.
public final class EditorSession {
    public let documentID: String
    public let actorID: String
    public let baseline: Document
    public let collaborationVersion: Int
    public var allowedBlockTypes: Set<String>?
    public var onChange: ((Document, Change?) -> Void)?
    /// Read-only preparation after remote validation, before materialized state changes.
    public var onWillReceive: (() -> Void)?
    public var onPresence: (([String: Presence]) -> Void)?
    public private(set) var presence: [String: Presence] = [:]
    public private(set) var mergeRecovery: MergeRecovery?
    private var preparingReceive = false
    private var remoteHolds = 0
    private var deferred: [ChangeBatch] = []
    private var deferredBytes = 0
    private var log: [ChangeID: Change] = [:]
    private var counter: UInt64 = 0
    private var undoStack: [ChangeID] = []
    private var redoStack: [ChangeID] = []
    private var state: Materialized
    private var currentDocument: Document

    public init(documentID: String, actorID: String, document: Document, collaborationVersion: Int = 1) throws {
        guard [1, 2].contains(collaborationVersion) else { throw EditorError.unsupportedVersion(collaborationVersion) }
        guard !documentID.isEmpty, validActor(actorID) else { throw EditorError.invalidChange }
        let document = try Document(blocks: document.blocks)
        if collaborationVersion == 2, try document.json().count > 32_000_000 {
            throw EditorError.invalidDocument("Document exceeds 32 MB")
        }
        self.documentID = documentID; self.actorID = actorID; self.baseline = document
        self.collaborationVersion = collaborationVersion
        self.state = .seed(document, version: collaborationVersion)
        self.currentDocument = document
    }

    public var document: Document { get throws { currentDocument } }
    public var syncState: SyncState {
        SyncState(received: Set(log.keys), documentID: collaborationVersion == 2 ? documentID : nil,
                  version: collaborationVersion == 2 ? 2 : nil)
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// A new replica uses a fresh actor ID. Resuming the saved actor restores its undo
    /// history; the host must guarantee that no other writer uses that actor concurrently.
    public static func restore(_ data: Data, actorID: String) throws -> EditorSession {
        guard data.count <= 64_000_000 else { throw EditorError.invalidChange }
        let batch = try JSONDecoder().decode(ChangeBatch.self, from: data)
        let session = try EditorSession(documentID: batch.documentID, actorID: actorID,
                                        document: Document(blocks: batch.baseline.blocks), collaborationVersion: batch.version)
        try session.receive(batch)
        if let saved = try JSONDecoder().decode(JSONValue.self, from: data)["localHistory"],
           saved["actorID"]?.string == actorID {
            func history(_ key: String) throws -> [ChangeID] {
                let ids = try JSONDecoder().decode([ChangeID].self, from: canonicalEncoder().encode(saved[key] ?? .array([])))
                guard Set(ids).count == ids.count, ids.allSatisfy({ id in
                    guard id.actor == actorID, let change = session.log[id], case .edit = change.body else { return false }; return true
                }) else { throw EditorError.invalidChange }
                return ids
            }
            session.undoStack = try history("undo"); session.redoStack = try history("redo")
            guard Set(session.undoStack).isDisjoint(with: session.redoStack) else { throw EditorError.invalidChange }
        }
        return session
    }

    /// Presence is never saved. Local history is restored only by its original actor.
    public func save() throws -> Data {
        var fields = try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(changes())).object ?? [:]
        fields["localHistory"] = .object([
            "actorID": .string(actorID),
            "undo": try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(undoStack)),
            "redo": try JSONDecoder().decode(JSONValue.self, from: canonicalEncoder().encode(redoStack)),
        ])
        return try canonicalEncoder().encode(JSONValue.object(fields))
    }
    public func changes(since peer: SyncState = SyncState()) -> ChangeBatch {
        // Unbound/old-epoch receipts cannot suppress new operations after cutover.
        let received = collaborationVersion == 1 || (peer.documentID == documentID && peer.version == 2) ? peer.received : []
        return ChangeBatch(documentID: documentID, baseline: baseline,
                    changes: log.values.filter { !received.contains($0.id) }.sorted { $0.id < $1.id }, version: collaborationVersion)
    }

    /// An input adapter commits composition before releasing its receive hold.
    /// Pending changes are absent from receipts and saves; transports must retain them.
    public func deferRemoteChanges() -> () throws -> Void {
        remoteHolds += 1
        var released = false
        return { [weak self] in
            guard !released, let self else { return }
            released = true; self.remoteHolds -= 1
            guard self.remoteHolds == 0 else { return }
            let pending = self.deferred
            self.deferred = []; self.deferredBytes = 0
            var failure: Error?
            for batch in pending {
                do { try self.receive(batch) } catch { if failure == nil { failure = error } }
            }
            if let failure { throw failure }
        }
    }

    /// Atomic receive: malformed or conflicting batches never partially modify the session.
    public func receive(_ batch: ChangeBatch) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        if remoteHolds > 0 {
            guard deferred.count < 64 else { throw EditorError.invalidChange }
            let bytes = try canonicalEncoder().encode(batch).count
            guard bytes <= 64_000_000 - deferredBytes else { throw EditorError.invalidChange }
            deferred.append(batch); deferredBytes += bytes
            return
        }
        guard batch.version == collaborationVersion else { throw EditorError.unsupportedVersion(batch.version) }
        guard batch.documentID == documentID, batch.baseline == baseline else { throw EditorError.differentDocument }
        guard batch.changes.count <= 100_000 else { throw EditorError.invalidChange }
        var candidate = log
        for change in mergeRecovery?.batch.changes ?? [] { candidate[change.id] = change }
        for change in batch.changes {
            try validate(change, version: collaborationVersion)
            if let existing = candidate[change.id], existing != change { throw EditorError.conflictingChange }
            candidate[change.id] = change
        }
        guard candidate != log else { return }
        if collaborationVersion == 2 { try checkRecoveryCapacity(candidate) }
        let next = try materialize(baseline, Array(candidate.values), version: collaborationVersion)
        let document = try admissionDocument(next, candidate: candidate)
        preparingReceive = true; onWillReceive?(); preparingReceive = false
        reconcileRecoveredHistory(candidate)
        log = candidate; state = next; counter = max(counter, candidate.keys.map(\.counter).max() ?? 0)
        currentDocument = document; mergeRecovery = nil
        onChange?(document, nil)
    }

    /// Repair the full rejected union atomically, keeping unapplied changes outside
    /// save/receipts until every edit produces a valid document. One author undo action.
    public func repairMerge(_ repairs: [MergeRepair]) throws {
        guard !preparingReceive, remoteHolds == 0, collaborationVersion == 2,
              let recovery = mergeRecovery, !repairs.isEmpty, repairs.count <= 64 else { throw EditorError.invalidChange }
        var candidate = log
        for change in recovery.batch.changes { candidate[change.id] = change }
        let clock = max(counter, candidate.keys.map(\.counter).max() ?? 0)
        guard clock < 9_007_199_254_740_991 else { throw EditorError.invalidChange }
        let id = ChangeID(counter: clock + 1, actor: actorID)
        var raw = try materialize(baseline, Array(candidate.values), version: 2)
        var mutations: [Mutation] = []
        for (index, repair) in repairs.enumerated() {
            // Each repair has a separate atom/placement range, also on 32-bit WASM.
            let base = index * 1_000_001
            var edits: [Mutation] = []
            switch repair {
            case .move(let identity, let collection):
                guard let structure = raw.structure, let node = structure.nodes[identity],
                      try structure.kind(in: collection) == node.kind else { throw EditorError.invalidPath }
                edits = [.moveNode(identity: identity, collection: collection,
                    placement: ElementID(change: id, index: base), after: nil)]
            case .wrap(let identity, let container, let field):
                guard let structure = raw.structure, let node = structure.nodes[identity] else { throw EditorError.invalidPath }
                try validateNode(.object(container.fields), kind: .block)
                try validateAuthoredNode(.object(container.fields), kind: .block)
                guard StructuralState.collectionFields(.block, container.fields)[field] == node.kind else { throw EditorError.invalidPath }
                let creation = ElementID(change: id, index: base), wrapper = NodeID.inserted(creation: creation, path: [])
                edits = [.insertNode(value: .object(container.fields), identity: wrapper, collection: .root,
                    placement: creation, after: nil),
                    .moveNode(identity: identity, collection: NodeCollection(owner: wrapper, field: field),
                        placement: ElementID(change: id, index: base + 1), after: nil)]
            case .text(let identity, let field, let text):
                guard raw.structure?.nodes[identity] != nil,
                      ["content", "summary", "caption", "code", "expression"].contains(field),
                      text.utf16.count <= 100_000 else { throw EditorError.invalidPath }
                let address = identity.textAddress(field)
                guard let value = raw.textValue(address), value.array != nil || value.string != nil,
                      (value.string ?? plainText(value.array ?? [])).utf16.count <= 100_000 else { throw EditorError.invalidPath }
                raw.ensureText(address)
                let atoms = raw.visibleAtoms(address), before = Array(plainText(atoms.map(\.node)).unicodeScalars), after = Array(text.unicodeScalars)
                var prefix = 0, suffix = 0
                while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
                while suffix < min(before.count, after.count) - prefix,
                      before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
                // Atomic references count as one atom but can span several scalars.
                var scalarOffset = 0, selected: [ElementID] = [], anchor: ElementID?, marks: [JSONValue] = []
                for atom in atoms {
                    let end = scalarOffset + plainText([atom.node]).unicodeScalars.count
                    if end <= prefix { anchor = atom.id; marks = atom.node["marks"]?.array ?? [] }
                    else if scalarOffset < before.count - suffix {
                        guard scalarOffset >= prefix, end <= before.count - suffix else { throw EditorError.invalidRange }
                        selected.append(atom.id)
                        if scalarOffset == prefix, prefix == 0 { marks = atom.node["marks"]?.array ?? [] }
                    }
                    scalarOffset = end
                }
                if !selected.isEmpty { edits.append(.deleteText(address: address, ids: selected)) }
                var inserted: [TextAtom] = []
                for scalar in after[prefix..<(after.count - suffix)] {
                    let element = ElementID(change: id, index: base + inserted.count)
                    inserted.append(TextAtom(id: element, after: anchor, node: textNode(String(scalar), marks: marks)))
                    anchor = element
                }
                if !inserted.isEmpty { edits.append(.insertText(address: address, atoms: inserted)) }
            }
            try apply(edits, enabled: true, to: &raw)
            mutations.append(contentsOf: edits)
        }
        guard !mutations.isEmpty else { throw EditorError.invalidChange }
        let change = Change(id: id, body: .edit(mutations))
        try validate(change, version: 2, structure: raw.structure, history: candidate, seedState: raw)
        candidate[id] = change
        try checkRecoveryCapacity(candidate)
        let next = try materialize(baseline, Array(candidate.values), version: 2)
        let document = try next.document() // Failed repair leaves the original proposal intact.
        guard try document.json().count <= 32_000_000 else {
            throw EditorError.invalidDocument("Document exceeds 32 MB")
        }
        preparingReceive = true; onWillReceive?(); preparingReceive = false
        reconcileRecoveredHistory(candidate)
        log = candidate; state = next; counter = clock + 1; currentDocument = document; mergeRecovery = nil
        undoStack.append(id); redoStack.removeAll()
        onChange?(document, change)
    }

    private func checkRecoveryCapacity(_ candidate: [ChangeID: Change]) throws {
        guard candidate.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
        let batch = ChangeBatch(documentID: documentID, baseline: baseline,
            changes: candidate.values.sorted { $0.id < $1.id }, version: collaborationVersion)
        let bytes = try canonicalEncoder().encode(batch).count
        // Reserve a deterministic upper bound for any author's undo/redo IDs and
        // JSON request/envelope overhead. An admitted snapshot must remain restorable.
        let editIDs = candidate.values.filter { if case .edit = $0.body { return true }; return false }.map(\.id).sorted()
        let historyBytes = try canonicalEncoder().encode(editIDs).count
        guard bytes <= 64_000_000 - 1_024 - historyBytes else { throw EditorError.recoveryCapacityExceeded }
    }
    private func admissionDocument(_ next: Materialized, candidate: [ChangeID: Change]) throws -> Document {
        do {
            let document = try next.document()
            if collaborationVersion == 2, try document.json().count > 32_000_000 {
                throw EditorError.invalidDocument("Document exceeds 32 MB")
            }
            return document
        }
        catch {
            guard collaborationVersion == 2, let error = error as? EditorError else { throw error }
            let reason: MergeRecoveryReason
            switch error {
            case .structuralConflict: reason = .identityConflict
            case .invalidDocument: reason = .schemaConstraint
            default: throw error
            }
            try checkRecoveryCapacity(candidate)
            let recovery = MergeRecovery(reason: reason, batch: ChangeBatch(documentID: documentID, baseline: baseline,
                changes: candidate.values.sorted { $0.id < $1.id }, version: 2))
            mergeRecovery = recovery
            throw EditorError.mergeRecoveryRequired(recovery)
        }
    }
    private func reconcileRecoveredHistory(_ candidate: [ChangeID: Change]) {
        var winning: [ChangeID: (id: ChangeID, active: Bool)] = [:]
        for change in candidate.values where change.id.actor == actorID {
            if case .setActive(let target, let active) = change.body,
               winning[target].map({ $0.id < change.id }) ?? true { winning[target] = (change.id, active) }
        }
        for (target, toggle) in winning.sorted(by: { $0.value.id < $1.value.id }) {
            if !toggle.active, let index = undoStack.firstIndex(of: target) { undoStack.remove(at: index); redoStack.append(target) }
            if toggle.active, let index = redoStack.firstIndex(of: target) { redoStack.remove(at: index); undoStack.append(target) }
        }
    }
    private func validateAuthoredNode(_ value: JSONValue, kind: NodeKind) throws {
        if kind == .block, let type = value["type"]?.string, let allowedBlockTypes,
           type != "paragraph", !allowedBlockTypes.contains(type) { throw EditorError.restrictedBlock(type) }
        for (field, childKind) in StructuralState.collectionFields(kind, value.object ?? [:]) {
            for child in value[field]?.array ?? [] { try validateAuthoredNode(child, kind: childKind) }
        }
    }

    public func receivePresence(_ value: Presence) {
        guard value.actor != actorID, value.revision > (presence[value.actor]?.revision ?? 0) else { return }
        presence[value.actor] = value; onPresence?(presence)
    }
    public func removePresence(actor: String) { presence.removeValue(forKey: actor); onPresence?(presence) }

    public func insert(_ block: Block, after blockID: String? = nil) throws {
        if collaborationVersion == 2 {
            let after = try blockID.map { try node(at: NodeAddress($0)) }
            _ = try insertNode(.object(block.fields), into: .root, after: after); return
        }
        guard state.blocks[block.id] == nil else { throw EditorError.invalidDocument("Block ID already exists") }
        if let allowedBlockTypes, block.type != "paragraph", !allowedBlockTypes.contains(block.type) {
            throw EditorError.restrictedBlock(block.type)
        }
        let after = try placement(for: blockID)
        let id = try nextID()
        try commit(id, [.insertBlock(block: block, placement: ElementID(change: id, index: 0), after: after)])
    }

    public func move(blockID: String, after otherID: String?) throws {
        if collaborationVersion == 2 {
            try moveNode(node(at: NodeAddress(blockID)), into: .root, after: otherID.map { try node(at: NodeAddress($0)) }); return
        }
        guard blockID != otherID, state.blockOrder().contains(blockID) else { throw EditorError.invalidPath }
        let after = try placement(for: otherID); let id = try nextID()
        try commit(id, [.moveBlock(blockID: blockID, placement: ElementID(change: id, index: 0), after: after)])
    }
    public func delete(blockID: String) throws {
        if collaborationVersion == 2 { try deleteNode(node(at: NodeAddress(blockID))); return }
        guard state.blockOrder().contains(blockID) else { throw EditorError.invalidPath }
        try commit(nextID(), [.deleteBlock(blockID: blockID)])
    }

    /// Set scalar metadata, e.g. image alt text or a nested checklist's checked value.
    /// Rich text and structure must use their dedicated operations.
    public func setField(blockID: String, path: [String], value: JSONValue) throws {
        if let structure = state.structure {
            var identity = try node(at: NodeAddress(blockID)), remaining = path
            while remaining.count >= 2, let parent = structure.nodes[identity],
                  StructuralState.collectionFields(parent.kind, parent.fields)[remaining[0]] != nil {
                let live = try address(of: identity)
                identity = try node(at: NodeAddress(live.blockID, path: live.path + Array(remaining.prefix(2))))
                remaining.removeFirst(2)
            }
            try setNodeField(identity, path: remaining, value: value); return
        }
        guard state.blocks[blockID] != nil else { throw EditorError.invalidPath }
        try commit(nextID(), [.setField(blockID: blockID, path: path, value: value)])
    }

    public func node(at address: NodeAddress) throws -> NodeID {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        return try structure.node(at: address)
    }
    public func address(of identity: NodeID) throws -> NodeAddress {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        return try structure.address(of: identity)
    }
    func cutoverAddresses() throws -> [NodeID: NodeAddress] {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        return try structure.cutoverAddresses()
    }
    public func nodes(in collection: NodeCollection) throws -> [NodeID] {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        _ = try structure.kind(in: collection)
        return try structure.visibleOrder(in: collection)
    }
    public func textAddress(of identity: NodeID, field: String = "content") throws -> TextAddress {
        let address = try state.canonicalAddress(identity.textAddress(field))
        _ = try text(at: address)
        return address
    }

    @discardableResult
    public func insertNode(_ value: JSONValue, into collection: NodeCollection, after: NodeID? = nil) throws -> NodeID {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        let kind = try structure.kind(in: collection)
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        try validateNode(value, kind: kind)
        guard !(try nodes(in: collection)).contains(where: { structure.nodes[$0]?.label == value["id"]?.string }) else { throw EditorError.invalidDocument("Sibling ID already exists") }
        try validateAuthoredNode(value, kind: kind)
        let anchor = try nodePlacement(after, in: collection), id = try nextID()
        let placement = ElementID(change: id, index: 0), identity = NodeID.inserted(creation: placement, path: [])
        try commit(id, [.insertNode(value: value, identity: identity, collection: collection, placement: placement, after: anchor)])
        return identity
    }

    public func moveNode(_ identity: NodeID, into collection: NodeCollection, after: NodeID? = nil) throws {
        guard let structure = state.structure, let node = structure.nodes[identity] else { throw EditorError.invalidPath }
        _ = try structure.address(of: identity)
        guard try structure.kind(in: collection) == node.kind, identity != after else { throw EditorError.invalidPath }
        if let owner = collection.owner {
            _ = try structure.address(of: owner)
            guard !(try structure.descendants(of: identity)).contains(owner) else { throw EditorError.invalidPath }
        }
        guard !(try nodes(in: collection)).contains(where: { $0 != identity && structure.nodes[$0]?.label == node.label }) else { throw EditorError.invalidDocument("Sibling ID already exists") }
        let anchor = try nodePlacement(after, in: collection), id = try nextID()
        try commit(id, [.moveNode(identity: identity, collection: collection, placement: ElementID(change: id, index: 0), after: anchor)])
    }

    public func deleteNode(_ identity: NodeID) throws {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        _ = try structure.address(of: identity)
        try commit(nextID(), [.deleteNodes(identities: structure.descendants(of: identity))])
    }

    public func setNodeField(_ identity: NodeID, path: [String], value: JSONValue) throws {
        guard let structure = state.structure else { throw EditorError.unsupportedVersion(2) }
        _ = try structure.address(of: identity)
        try commit(nextID(), [.setNodeField(identity: identity, path: path, value: value)])
    }

    /// Indent a list item under its preceding sibling, preserving its identity.
    public func indent(_ identity: NodeID) throws {
        guard let structure = state.structure else { throw EditorError.invalidPath }
        let id = try nextID()
        try commit(id, planWritingListHierarchy([identity], outdent: false, change: id, structure: structure))
    }

    public func outdent(_ identity: NodeID) throws {
        guard let structure = state.structure else { throw EditorError.invalidPath }
        let id = try nextID()
        try commit(id, planWritingListHierarchy([identity], outdent: true, change: id, structure: structure))
    }

    private func nodePlacement(_ identity: NodeID?, in collection: NodeCollection) throws -> NodePlacementID? {
        guard let identity else { return nil }
        guard let structure = state.structure, try nodes(in: collection).contains(identity),
              let placement = try structure.effectivePlacements()[identity], placement.collection == collection else { throw EditorError.invalidPath }
        return placement.id
    }

    public func text(at address: TextAddress) throws -> String {
        let address = try state.canonicalAddress(address)
        let value = state.textValue(address)
        guard value?.array != nil || value?.string != nil else { throw EditorError.invalidPath }
        state.ensureText(address); return plainText(state.visibleAtoms(address).map(\.node))
    }

    /// Capture a UTF-16 scalar boundary as a stable atom anchor. Display selections
    /// can sit inside reference labels; editing still treats references atomically.
    public func position(at address: TextAddress, offset: Int, affinity: TextAffinity = .before) throws -> TextPosition {
        let address = try state.canonicalAddress(address)
        guard state.structure != nil || state.blockOrder().contains(address.blockID) else { throw EditorError.invalidPath }
        let text = try text(at: address)
        guard validUTF16Offset(offset, in: text) else { throw EditorError.invalidRange }
        var current = 0, left: ElementID?
        for atom in state.visibleAtoms(address) {
            if current == offset {
                return TextPosition(documentID: documentID, address: address, anchor: affinity == .before ? atom.id : left, affinity: affinity)
            }
            let length = plainText([atom.node]).utf16.count
            if offset > current, offset < current + length {
                return TextPosition(documentID: documentID, address: address, anchor: atom.id, affinity: affinity, intraAtomOffset: offset - current)
            }
            current += length
            left = atom.id
        }
        return TextPosition(documentID: documentID, address: address, anchor: affinity == .before ? nil : left, affinity: affinity)
    }

    /// Deleted/undone atoms remain anchors. An anchor whose causal predecessors
    /// have not arrived yet fails explicitly; the host can retry after synchronization.
    public func offset(of position: TextPosition) throws -> Int {
        guard position.documentID == documentID else { throw EditorError.differentDocument }
        let address = try state.canonicalAddress(position.address)
        guard state.structure != nil || state.blockOrder().contains(address.blockID) else { throw EditorError.invalidPath }
        _ = try text(at: address)
        let visible = state.visibleAtoms(address)
        guard let anchor = position.anchor else {
            guard position.intraAtomOffset == nil else { throw EditorError.invalidRange }
            return position.affinity == .before ? visible.reduce(0) { $0 + plainText([$1.node]).utf16.count } : 0
        }
        let visibleIDs = Set(visible.map(\.id)), atoms = state.texts[address] ?? [:]
        var offset = 0
        for id in Materialized.order(atoms, after: { $0.after }) {
            if id == anchor, let interior = position.intraAtomOffset {
                guard let atom = atoms[id], atom.node["type"]?.string != "text" else { throw EditorError.invalidRange }
                let label = plainText([atom.node])
                guard interior > 0, interior < label.utf16.count, validUTF16Offset(interior, in: label) else { throw EditorError.invalidRange }
                return offset + (visibleIDs.contains(id) ? interior : 0)
            }
            if id == anchor, position.affinity == .before { return offset }
            if visibleIDs.contains(id), let atom = atoms[id] { offset += plainText([atom.node]).utf16.count }
            if id == anchor { return offset }
        }
        throw EditorError.invalidRange
    }

    /// Range uses UTF-16 offsets. Rejects a split scalar or atomic reference.
    public func replaceText(at address: TextAddress, range: Range<Int>, with text: String,
                            marks: [JSONValue]? = nil) throws {
        let address = try state.canonicalAddress(address)
        let selection = try selected(address, range)
        let id = try nextID()
        var mutations: [Mutation] = []
        if !selection.ids.isEmpty { mutations.append(.deleteText(address: address, ids: selection.ids)) }
        let inherited = marks ?? selection.inheritedMarks
        var after = selection.after
        let atoms = text.unicodeScalars.enumerated().map { index, scalar in
            let atom = TextAtom(id: ElementID(change: id, index: index), after: after,
                                node: textNode(String(scalar), marks: inherited))
            after = atom.id; return atom
        }
        if !atoms.isEmpty { mutations.append(.insertText(address: address, atoms: atoms)) }
        guard !mutations.isEmpty else { return }
        try commit(id, mutations)
    }

    public func format(at address: TextAddress, range: Range<Int>, markType: String, mark: JSONValue?) throws {
        let address = try state.canonicalAddress(address)
        let selection = try selected(address, range)
        guard !selection.ids.isEmpty else { return }
        try commit(nextID(), [.formatText(address: address, ids: selection.ids, markType: markType, mark: mark)])
    }

    /// Reconcile a renderer's inline value as one user action. Surviving characters
    /// retain their identities; formatting emits mark operations, never text replacement.
    public func setInline(at address: TextAddress, nodes: [JSONValue]) throws {
        let address = try state.canonicalAddress(address)
        try Validation.inline(.array(nodes))
        _ = try text(at: address)
        let old = state.visibleAtoms(address)
        let proposed: [JSONValue] = nodes.flatMap { node -> [JSONValue] in
            if node["type"]?.string == "text" {
                let text: String = node["text"]?.string ?? ""
                return text.unicodeScalars.map { scalar -> JSONValue in
                    var fields = node.object ?? [:]; fields["text"] = .string(String(scalar)); return .object(fields)
                }
            }
            return [node]
        }
        func identity(_ node: JSONValue) -> JSONValue {
            guard node["type"]?.string == "text", var fields = node.object else { return node }
            fields.removeValue(forKey: "marks"); return .object(fields)
        }
        var prefix = 0, suffix = 0
        while prefix < min(old.count, proposed.count), identity(old[prefix].node) == identity(proposed[prefix]) { prefix += 1 }
        while suffix < min(old.count, proposed.count) - prefix,
              identity(old[old.count - suffix - 1].node) == identity(proposed[proposed.count - suffix - 1]) { suffix += 1 }
        let id = try nextID()
        var mutations: [Mutation] = []
        let deleted = old[prefix..<(old.count - suffix)].map(\.id)
        if !deleted.isEmpty { mutations.append(.deleteText(address: address, ids: deleted)) }
        var after = prefix > 0 ? old[prefix - 1].id : nil
        let inserted = proposed[prefix..<(proposed.count - suffix)].enumerated().map { index, node in
            let atom = TextAtom(id: ElementID(change: id, index: index), after: after, node: node)
            after = atom.id; return atom
        }
        if !inserted.isEmpty { mutations.append(.insertText(address: address, atoms: inserted)) }
        let survivors = (0..<prefix).map { ($0, $0) } + (0..<suffix).map { (old.count - suffix + $0, proposed.count - suffix + $0) }
        for (oldIndex, newIndex) in survivors {
            let atom = old[oldIndex], node = proposed[newIndex]
            guard node["type"]?.string == "text" else { continue }
            let before = atom.node["marks"]?.array ?? [], after = node["marks"]?.array ?? []
            for type in Set((before + after).compactMap { $0["type"]?.string }).sorted() {
                let oldMark = before.first { $0["type"]?.string == type }, newMark = after.first { $0["type"]?.string == type }
                if oldMark != newMark { mutations.append(.formatText(address: address, ids: [atom.id], markType: type, mark: newMark)) }
            }
        }
        if !mutations.isEmpty { try commit(id, mutations) }
    }

    /// Plain native inputs use a minimal scalar diff so remote/unchanged spans retain identity.
    public func setText(at address: TextAddress, to text: String) throws {
        let address = try state.canonicalAddress(address)
        let before = try self.text(at: address)
        if before == text { return }
        let old = Array(before.unicodeScalars), new = Array(text.unicodeScalars)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(scalars)) }
        var start = string(old[..<prefix]).utf16.count
        var end = before.utf16.count - string(old[(old.count - suffix)...]).utf16.count
        var inserted = string(new[prefix..<(new.count - suffix)])
        // Editing part of an atomic reference explicitly turns its remaining label
        // into ordinary text. Never retain a stale entity identity after a label edit.
        var offset = 0
        for atom in state.visibleAtoms(address) {
            let label = plainText([atom.node]), length = label.utf16.count
            if atom.node["type"]?.string != "text" {
                if start > offset, start < offset + length {
                    let prefix = String(decoding: Array(label.utf16.prefix(start - offset)), as: UTF16.self)
                    inserted = prefix + inserted; start = offset
                }
                if end > offset, end < offset + length {
                    let suffix = String(decoding: Array(label.utf16.dropFirst(end - offset)), as: UTF16.self)
                    inserted += suffix; end = offset + length
                }
            }
            offset += length
        }
        try replaceText(at: address, range: start..<end, with: inserted)
    }

    public func undo() throws {
        guard let target = undoStack.last else { return }
        try toggle(target, active: false); undoStack.removeLast(); redoStack.append(target)
        onChange?(try document, log[ChangeID(counter: counter, actor: actorID)])
    }
    public func redo() throws {
        guard let target = redoStack.last else { return }
        try toggle(target, active: true); redoStack.removeLast(); undoStack.append(target)
        onChange?(try document, log[ChangeID(counter: counter, actor: actorID)])
    }

    private func toggle(_ target: ChangeID, active: Bool) throws {
        let change = Change(id: try nextID(), body: .setActive(target: target, active: active))
        try append(change)
    }
    private func nextID() throws -> ChangeID {
        guard counter < 9_007_199_254_740_990 else { throw EditorError.invalidChange }
        return ChangeID(counter: counter + 1, actor: actorID)
    }
    private func placement(for blockID: String?) throws -> ElementID? {
        guard let blockID else { return nil }
        guard state.blockOrder().contains(blockID), let id = state.selectedPlacement[blockID] else { throw EditorError.invalidPath }
        return id
    }
    private func commit(_ id: ChangeID, _ mutations: [Mutation]) throws {
        let change = Change(id: id, body: .edit(mutations))
        try append(change); undoStack.append(id); redoStack.removeAll()
        onChange?(try document, change)
    }
    private func append(_ change: Change) throws {
        guard !preparingReceive else { throw EditorError.invalidChange }
        if let recovery = mergeRecovery { throw EditorError.mergeRecoveryRequired(recovery) }
        try validate(change, version: collaborationVersion, structure: state.structure, history: log, seedState: state)
        var candidate = log; candidate[change.id] = change
        if collaborationVersion == 2 { try checkRecoveryCapacity(candidate) }
        var next: Materialized
        if case .edit(let mutations) = change.body {
            // Local IDs are newer than every received change. They can be applied
            // to a copy of the current state without reinterpreting earlier history.
            next = state
            try apply(mutations, enabled: true, to: &next)
        } else {
            next = try materialize(baseline, Array(candidate.values), version: collaborationVersion)
        }
        let document: Document
        if case .setActive = change.body { document = try admissionDocument(next, candidate: candidate) }
        else {
            document = try next.document()
            if collaborationVersion == 2, try document.json().count > 32_000_000 {
                throw EditorError.invalidDocument("Document exceeds 32 MB")
            }
        }
        log = candidate; state = next; counter = change.id.counter
        currentDocument = document
    }
    private func selected(_ address: TextAddress, _ range: Range<Int>) throws
        -> (ids: [ElementID], after: ElementID?, inheritedMarks: [JSONValue]) {
        _ = try text(at: address)
        let atoms = state.visibleAtoms(address)
        var offset = 0, boundaries: Set<Int> = [0], ids: [ElementID] = []
        var after: ElementID?, inherited: [JSONValue] = []
        for atom in atoms {
            let length = plainText([atom.node]).utf16.count
            if offset < range.lowerBound { after = atom.id; inherited = atom.node["marks"]?.array ?? [] }
            else if range.lowerBound == 0, offset == 0 { inherited = atom.node["marks"]?.array ?? [] }
            if offset >= range.lowerBound, offset < range.upperBound { ids.append(atom.id) }
            offset += length; boundaries.insert(offset)
        }
        guard range.lowerBound >= 0, boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound)
        else { throw EditorError.invalidRange }
        return (ids, after, inherited)
    }
}

func validActor(_ actor: String) -> Bool {
    !actor.isEmpty && actor.utf8.count <= 256 && actor.utf8.allSatisfy { (33...126).contains($0) }
}

private func validUTF16Offset(_ offset: Int, in text: String) -> Bool {
    if offset == 0 { return true }
    var current = 0
    for scalar in text.unicodeScalars {
        current += scalar.value > 0xffff ? 2 : 1
        if current == offset { return true }
        if current > offset { return false }
    }
    return false
}

private enum ValidationElement {
    case node(JSONValue, NodeCollection)
    case placement
    case text(TextAddress)
}

func validate(_ change: Change, version: Int, structure: StructuralState? = nil, history: [ChangeID: Change] = [:], seedState: Materialized? = nil) throws {
    guard change.id.counter > 0, change.id.counter <= 9_007_199_254_740_991,
          validActor(change.id.actor) else { throw EditorError.invalidChange }
    var introduced = Set<ElementID>()
    var introducedPlacements = Set<ElementID>()
    var introducedNodes = Set<ElementID>()
    var introducedText: [ElementID: TextAddress] = [:]
    var introducedStructure = structure ?? StructuralState()
    var uncertainCreations = Set<ElementID>()
    var possibleNodes = Set<NodeID>()
    var possiblePlacements = Set<NodePlacementID>()
    var knownElements: [ChangeID: [ElementID: ValidationElement]] = [:]
    var knownNodes: [ElementID: Set<NodeID>] = [:]
    var introducedPayloads: [ElementID: JSONValue] = [:]
    var introducedBlocks: [String: Block] = [:]
    var seedCounts: [TextAddress: Int] = [:]
    func atomCount(_ value: JSONValue?) -> Int {
        if let text = value?.string { return text.unicodeScalars.count }
        return (value?.array ?? []).reduce(0) { count, node in
            count + (node["type"]?.string == "text" ? (node["text"]?.string ?? "").unicodeScalars.count : 1)
        }
    }
    func seedCount(at address: TextAddress) throws -> Int? {
        if let count = seedCounts[address] { return count }
        let count: Int
        if let identity = address.identity, let field = address.path.last {
            switch identity {
            case .document: throw EditorError.invalidChange
            case .baseline:
                guard let node = introducedStructure.nodes[identity] else { return nil }
                count = atomCount(node.fields[field])
            case .inserted(let creation, let path):
                if let value = introducedPayloads[creation] { count = atomCount(value.value(at: path + [field])) }
                else if let element = try knownElement(creation), case .node(let value, _) = element {
                    count = atomCount(value.value(at: path + [field]))
                } else { return nil } // An earlier creation can still arrive later.
            }
        } else {
            if let atoms = seedState?.texts[address] {
                let count = atoms.keys.filter { $0.change.counter == 0 }.count
                seedCounts[address] = count
                return count
            }
            if let block = introducedBlocks[address.blockID] ?? seedState?.blocks[address.blockID] {
                count = atomCount(block.value(at: address.path))
            } else {
                // V1 labels cannot identify an insertion. While a block is absent,
                // retain known creation seeds for delayed/undone causal owners.
                var values: [Block] = []
                for prior in history.values where prior.id < change.id {
                    if case .edit(let edits) = prior.body {
                        for edit in edits {
                            if case .insertBlock(let block, _, _) = edit, block.id == address.blockID { values.append(block) }
                        }
                    }
                }
                guard !values.isEmpty else { return nil }
                count = values.map { atomCount($0.value(at: address.path)) }.max() ?? 0
            }
        }
        seedCounts[address] = count
        return count
    }
    func knownElement(_ id: ElementID) throws -> ValidationElement? {
        guard let prior = history[id.change] else { return nil }
        if knownElements[id.change] == nil {
            var elements: [ElementID: ValidationElement] = [:]
            if case .edit(let mutations) = prior.body {
                for mutation in mutations {
                    switch mutation {
                    case .insertNode(let value, _, let collection, let placement, _): elements[placement] = .node(value, collection)
                    case .moveNode(_, _, let placement, _), .insertBlock(_, let placement, _), .moveBlock(_, let placement, _): elements[placement] = .placement
                    case .insertText(let address, let atoms): for atom in atoms { elements[atom.id] = .text(address) }
                    default: break
                    }
                }
            }
            knownElements[id.change] = elements
        }
        // A known complete transaction cannot introduce this element later.
        guard let element = knownElements[id.change]?[id] else { throw EditorError.invalidChange }
        return element
    }
    func creationNodes(_ creation: ElementID, value: JSONValue, collection: NodeCollection) throws -> Set<NodeID> {
        if let nodes = knownNodes[creation] { return nodes }
        let root = NodeID.inserted(creation: creation, path: [])
        let kinds: [NodeKind]
        if let node = introducedStructure.nodes[root] { kinds = [node.birthKind] }
        else {
            switch collection.field {
            case "blocks": kinds = [.block]
            case "items": kinds = [.item]
            case "rows": kinds = [.row]
            case "cells": kinds = [.cell]
            case "children": kinds = [.item, .block]
            default: throw EditorError.invalidChange
            }
        }
        var nodes = Set<NodeID>()
        for kind in kinds {
            do { try validateNode(value, kind: kind) } catch { continue }
            var shape = StructuralState()
            shape.register(value, identity: root, kind: kind, active: true)
            nodes.formUnion(shape.nodes.keys)
        }
        guard !nodes.isEmpty else { throw EditorError.invalidChange }
        knownNodes[creation] = nodes
        return nodes
    }
    func uncertain(_ identity: NodeID) -> Bool {
        if case .inserted(let creation, _) = identity { return uncertainCreations.contains(creation) }
        return false
    }
    func reference(_ id: ElementID?) throws {
        guard let id else { return }
        guard id.index >= 0, id.change < change.id || id.change == change.id else { throw EditorError.invalidChange }
        guard id.change.counter == 0 ? id.change.actor.isEmpty : validActor(id.change.actor) else { throw EditorError.invalidChange }
        // A complete change cannot gain missing predecessors later. Its references
        // must resolve to an element already introduced earlier in this transaction.
        if id.change == change.id, !introduced.contains(id) { throw EditorError.invalidChange }
    }
    func placementElement(_ id: ElementID?) throws {
        try reference(id)
        if let id, id.change.counter == 0 {
            guard version == 1 else { throw EditorError.invalidChange }
            if let seedState, seedState.placements[id] == nil { throw EditorError.invalidChange }
        }
        if let id, id.change == change.id, !introducedPlacements.contains(id) { throw EditorError.invalidChange }
        if let id, id.change != change.id, let element = try knownElement(id) {
            if case .text = element { throw EditorError.invalidChange }
        }
    }
    func textElement(_ id: ElementID?, at target: TextAddress) throws {
        try reference(id)
        if let id, id.change.counter == 0, let count = try seedCount(at: target), id.index >= count { throw EditorError.invalidChange }
        if let id, id.change == change.id, introducedText[id] != target { throw EditorError.invalidChange }
        if let id, id.change != change.id, let element = try knownElement(id) {
            guard case .text(let address) = element, address == target else { throw EditorError.invalidChange }
        }
    }
    func address(_ address: TextAddress) throws {
        guard !address.blockID.isEmpty, let field = address.path.last,
              ["content", "summary", "caption", "code", "expression"].contains(field), address.path.count <= 100 else { throw EditorError.invalidPath }
        guard (version == 2) == (address.identity != nil) else { throw EditorError.invalidChange }
        if let identity = address.identity {
            try nodeReference(identity)
            guard address == identity.textAddress(field) else { throw EditorError.invalidPath }
        }
    }
    func nodeReference(_ identity: NodeID) throws {
        switch identity {
        case .document: throw EditorError.invalidChange
        case .baseline(let blockID, let path):
            guard !blockID.isEmpty, path.count % 2 == 0, path.count <= 100, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidPath }
            if structure != nil, introducedStructure.nodes[identity] == nil { throw EditorError.invalidChange }
        case .inserted(let creation, let path):
            try reference(creation)
            if creation.change == change.id {
                guard introducedNodes.contains(creation), possibleNodes.contains(identity) || introducedStructure.nodes[identity] != nil else { throw EditorError.invalidChange }
            } else if let element = try knownElement(creation) {
                guard case .node(let value, let collection) = element,
                      try creationNodes(creation, value: value, collection: collection).contains(identity) else { throw EditorError.invalidChange }
            }
            guard creation.change.counter > 0, path.count % 2 == 0, path.count <= 100, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidPath }
        }
    }
    func nodeCollection(_ collection: NodeCollection) throws {
        guard version == 2 else { throw EditorError.unsupportedVersion(2) }
        if let owner = collection.owner {
            try nodeReference(owner)
            guard ["children", "items", "rows", "cells"].contains(collection.field) else { throw EditorError.invalidPath }
            if !uncertain(owner), introducedStructure.nodes[owner] != nil {
                _ = try introducedStructure.kind(in: collection)
            }
        } else { guard collection == .root else { throw EditorError.invalidPath } }
    }
    func nodePlacement(_ id: NodePlacementID?) throws {
        guard let id else { return }
        switch id {
        case .initial(let node):
            try nodeReference(node)
            if case .inserted(let creation, let path) = node {
                // Only embedded descendants have initial placements. The root
                // of every creation uses its edit placement, even when nested.
                guard !path.isEmpty else { throw EditorError.invalidChange }
                if creation.change == change.id, !possiblePlacements.contains(id), introducedStructure.placements[id] == nil { throw EditorError.invalidChange }
            }
        case .role(let owner, let node):
            // Such placements can only be supplied by an explicitly validated
            // protocol-4 writing projection, never inferred from birth labels.
            guard version == 2, introducedStructure.placements[id] != nil else { throw EditorError.invalidChange }
            try nodeReference(owner); try nodeReference(node)
        case .columnRoute: throw EditorError.invalidChange
        case .edit(let element): try placementElement(element)
        }
    }
    func scalarPath(_ path: [String], _ value: JSONValue) throws {
        guard let last = path.last, !["id", "type", "content", "summary", "caption", "code", "expression", "children", "items", "rows", "cells"].contains(last),
              value.array == nil, value.object == nil, path.count <= 100 else { throw EditorError.invalidPath }
    }
    switch change.body {
    case .setActive(let target, _):
        guard target.actor == change.id.actor, target < change.id, target.counter > 0 else { throw EditorError.invalidChange }
        if let prior = history[target], case .setActive = prior.body { throw EditorError.invalidChange }
    case .edit(let mutations):
        guard !mutations.isEmpty, mutations.count <= 10_000 else { throw EditorError.invalidChange }
        for mutation in mutations {
            switch mutation {
            case .insertBlock(let block, let id, let after):
                guard version == 1 else { throw EditorError.invalidChange }
                _ = try Document(blocks: [block]); try placementElement(after)
                guard id.change == change.id, id.index >= 0, introduced.insert(id).inserted, after != id else { throw EditorError.invalidChange }
                introducedPlacements.insert(id)
                introducedBlocks[block.id] = block
            case .moveBlock(let blockID, let id, let after):
                guard version == 1 else { throw EditorError.invalidChange }
                try placementElement(after)
                guard !blockID.isEmpty, id.change == change.id, id.index >= 0, introduced.insert(id).inserted, after != id else { throw EditorError.invalidChange }
                introducedPlacements.insert(id)
            case .deleteBlock(let blockID):
                guard version == 1 else { throw EditorError.invalidChange }
                guard !blockID.isEmpty else { throw EditorError.invalidChange }
            case .setField(_, let path, let value):
                guard version == 1 else { throw EditorError.invalidChange }
                try scalarPath(path, value)
            case .insertNode(let value, let identity, let collection, let id, let after):
                try nodeCollection(collection); try nodePlacement(after)
                guard value.object != nil, identity == .inserted(creation: id, path: []), id.change == change.id,
                      id.index >= 0, introduced.insert(id).inserted, after != .edit(id) else { throw EditorError.invalidChange }
                var kind: NodeKind
                if let owner = collection.owner, !uncertain(owner), introducedStructure.nodes[owner] != nil {
                    kind = try introducedStructure.kind(in: collection)
                } else {
                    // Earlier causal owners can arrive later. The collection and
                    // payload determine the creation's intrinsic descendant shape.
                    switch collection.field {
                    case "blocks": kind = .block
                    case "items": kind = .item
                    case "rows": kind = .row
                    case "cells": kind = .cell
                    case "children":
                        // Children can be blocks or list items. An item's opaque
                        // type metadata cannot identify its structural kind. Keep
                        // this shape tentative until the causal owner is available.
                        kind = value["type"]?.string == nil ? .item : .block
                        uncertainCreations.insert(id)
                    default: throw EditorError.invalidPath
                    }
                }
                if uncertainCreations.contains(id) {
                    var shapes: [NodeKind] = [], failure: Error = EditorError.invalidChange
                    for possible in [NodeKind.item, .block] {
                        do { try validateNode(value, kind: possible); shapes.append(possible) }
                        catch { failure = error }
                    }
                    guard !shapes.isEmpty else { throw failure }
                    if !shapes.contains(kind) { kind = shapes[0] }
                    for possible in shapes {
                        var shape = StructuralState()
                        shape.register(value, identity: identity, kind: possible, active: true)
                        possibleNodes.formUnion(shape.nodes.keys)
                        possiblePlacements.formUnion(shape.placements.keys)
                    }
                } else { try validateNode(value, kind: kind) }
                introducedStructure.register(value, identity: identity, kind: kind, active: true)
                introducedPlacements.insert(id); introducedNodes.insert(id)
                introducedPayloads[id] = value
            case .moveNode(let identity, let collection, let id, let after):
                try nodeReference(identity); try nodeCollection(collection); try nodePlacement(after)
                guard id.change == change.id, id.index >= 0, introduced.insert(id).inserted, after != .edit(id) else { throw EditorError.invalidChange }
                introducedPlacements.insert(id)
            case .deleteNodes(let identities):
                guard version == 2, !identities.isEmpty, identities.count <= 100_000, Set(identities).count == identities.count else { throw EditorError.invalidChange }
                for identity in identities { try nodeReference(identity) }
            case .setNodeField(let identity, let path, let value):
                guard version == 2 else { throw EditorError.unsupportedVersion(2) }
                try nodeReference(identity); try scalarPath(path, value)
            case .insertText(let target, let atoms):
                try address(target)
                for atom in atoms {
                    try Validation.inline(.array([atom.node]))
                    try textElement(atom.after, at: target)
                    guard atom.id.change == change.id, atom.id.index >= 0, introduced.insert(atom.id).inserted,
                          atom.after != atom.id else { throw EditorError.invalidChange }
                    if atom.node["type"]?.string == "text" {
                        guard atom.node["text"]?.string?.unicodeScalars.count == 1 else { throw EditorError.invalidChange }
                    } else {
                        guard ["mention", "entity-ref", "date", "emoji", "inline-math"].contains(atom.node["type"]?.string ?? ""),
                              !plainText([atom.node]).isEmpty else { throw EditorError.invalidChange }
                    }
                    if let after = atom.after, after.change == change.id, after.index >= atom.id.index { throw EditorError.invalidChange }
                    introducedText[atom.id] = target
                }
            case .deleteText(let target, let ids):
                try address(target); for id in ids { try textElement(id, at: target) }
            case .formatText(let target, let ids, let type, let mark):
                try address(target); for id in ids { try textElement(id, at: target) }
                guard ["bold", "italic", "strikethrough", "code", "link"].contains(type),
                      mark == nil || mark?["type"]?.string == type else { throw EditorError.invalidChange }
                if type == "link", let mark {
                    guard let url = mark["href"]?.string, let scheme = URL(string: url)?.scheme?.lowercased(),
                          ["http", "https", "mailto"].contains(scheme) else { throw EditorError.invalidChange }
                }
            }
        }
    }
}
