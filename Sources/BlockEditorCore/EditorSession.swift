import Foundation

/// Confine a session to one executor. Hosts choose their own storage and transport.
public final class EditorSession {
    public let documentID: String
    public let actorID: String
    public let baseline: Document
    public var allowedBlockTypes: Set<String>?
    public var onChange: ((Document, Change?) -> Void)?
    /// Read-only preparation after remote validation, before materialized state changes.
    public var onWillReceive: (() -> Void)?
    public var onPresence: (([String: Presence]) -> Void)?
    public private(set) var presence: [String: Presence] = [:]
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

    public init(documentID: String, actorID: String, document: Document) throws {
        guard !documentID.isEmpty, validActor(actorID) else { throw EditorError.invalidChange }
        self.documentID = documentID; self.actorID = actorID; self.baseline = document
        self.state = .seed(document)
        self.currentDocument = document
    }

    public var document: Document { get throws { currentDocument } }
    public var syncState: SyncState { SyncState(received: Set(log.keys)) }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// A new replica uses a fresh actor ID. Resuming the saved actor restores its undo
    /// history; the host must guarantee that no other writer uses that actor concurrently.
    public static func restore(_ data: Data, actorID: String) throws -> EditorSession {
        guard data.count <= 64_000_000 else { throw EditorError.invalidChange }
        let batch = try JSONDecoder().decode(ChangeBatch.self, from: data)
        guard batch.version == 1 else { throw EditorError.unsupportedVersion(batch.version) }
        let session = try EditorSession(documentID: batch.documentID, actorID: actorID,
                                        document: Document(blocks: batch.baseline.blocks))
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
        ChangeBatch(documentID: documentID, baseline: baseline,
                    changes: log.values.filter { !peer.received.contains($0.id) }.sorted { $0.id < $1.id })
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
        guard batch.version == 1 else { throw EditorError.unsupportedVersion(batch.version) }
        guard batch.documentID == documentID, batch.baseline == baseline else { throw EditorError.differentDocument }
        guard batch.changes.count <= 100_000 else { throw EditorError.invalidChange }
        var candidate = log
        for change in batch.changes {
            try validate(change)
            if let existing = candidate[change.id], existing != change { throw EditorError.conflictingChange }
            candidate[change.id] = change
        }
        guard candidate != log else { return }
        let next = try materialize(baseline, Array(candidate.values))
        let document = try next.document()
        preparingReceive = true; onWillReceive?(); preparingReceive = false
        log = candidate; state = next; counter = max(counter, candidate.keys.map(\.counter).max() ?? 0)
        currentDocument = document
        onChange?(document, nil)
    }

    public func receivePresence(_ value: Presence) {
        guard value.actor != actorID, value.revision > (presence[value.actor]?.revision ?? 0) else { return }
        presence[value.actor] = value; onPresence?(presence)
    }
    public func removePresence(actor: String) { presence.removeValue(forKey: actor); onPresence?(presence) }

    public func insert(_ block: Block, after blockID: String? = nil) throws {
        guard state.blocks[block.id] == nil else { throw EditorError.invalidDocument("Block ID already exists") }
        if let allowedBlockTypes, block.type != "paragraph", !allowedBlockTypes.contains(block.type) {
            throw EditorError.restrictedBlock(block.type)
        }
        let after = try placement(for: blockID)
        let id = try nextID()
        try commit(id, [.insertBlock(block: block, placement: ElementID(change: id, index: 0), after: after)])
    }

    public func move(blockID: String, after otherID: String?) throws {
        guard blockID != otherID, state.blockOrder().contains(blockID) else { throw EditorError.invalidPath }
        let after = try placement(for: otherID); let id = try nextID()
        try commit(id, [.moveBlock(blockID: blockID, placement: ElementID(change: id, index: 0), after: after)])
    }
    public func delete(blockID: String) throws {
        guard state.blockOrder().contains(blockID) else { throw EditorError.invalidPath }
        try commit(nextID(), [.deleteBlock(blockID: blockID)])
    }

    /// Set scalar metadata, e.g. image alt text or a nested checklist's checked value.
    /// Rich text and structure must use their dedicated operations.
    public func setField(blockID: String, path: [String], value: JSONValue) throws {
        guard state.blocks[blockID] != nil else { throw EditorError.invalidPath }
        try commit(nextID(), [.setField(blockID: blockID, path: path, value: value)])
    }

    public func text(at address: TextAddress) throws -> String {
        let value = state.blocks[address.blockID]?.value(at: address.path)
        guard value?.array != nil || value?.string != nil else { throw EditorError.invalidPath }
        state.ensureText(address); return plainText(state.visibleAtoms(address).map(\.node))
    }

    /// Capture a UTF-16 scalar boundary as a stable atom anchor. Display selections
    /// can sit inside reference labels; editing still treats references atomically.
    public func position(at address: TextAddress, offset: Int, affinity: TextAffinity = .before) throws -> TextPosition {
        guard state.blockOrder().contains(address.blockID) else { throw EditorError.invalidPath }
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
        let address = position.address
        guard state.blockOrder().contains(address.blockID) else { throw EditorError.invalidPath }
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
        let selection = try selected(address, range)
        guard !selection.ids.isEmpty else { return }
        try commit(nextID(), [.formatText(address: address, ids: selection.ids, markType: markType, mark: mark)])
    }

    /// Reconcile a renderer's inline value as one user action. Surviving characters
    /// retain their identities; formatting emits mark operations, never text replacement.
    public func setInline(at address: TextAddress, nodes: [JSONValue]) throws {
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
        try validate(change)
        var candidate = log; candidate[change.id] = change
        var next: Materialized
        if case .edit(let mutations) = change.body {
            // Local IDs are newer than every received change. They can be applied
            // to a copy of the current state without reinterpreting earlier history.
            next = state
            try apply(mutations, enabled: true, to: &next)
        } else {
            next = try materialize(baseline, Array(candidate.values))
        }
        let document = try next.document()
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

private func validActor(_ actor: String) -> Bool {
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

private func validate(_ change: Change) throws {
    guard change.id.counter > 0, change.id.counter <= 9_007_199_254_740_991,
          validActor(change.id.actor) else { throw EditorError.invalidChange }
    func reference(_ id: ElementID?) throws {
        guard let id else { return }
        guard id.index >= 0, id.change < change.id || id.change == change.id else { throw EditorError.invalidChange }
    }
    func address(_ address: TextAddress) throws {
        guard !address.blockID.isEmpty, let field = address.path.last,
              ["content", "summary", "caption", "code", "expression"].contains(field), address.path.count <= 100 else { throw EditorError.invalidPath }
    }
    switch change.body {
    case .setActive(let target, _):
        guard target.actor == change.id.actor, target < change.id, target.counter > 0 else { throw EditorError.invalidChange }
    case .edit(let mutations):
        guard !mutations.isEmpty, mutations.count <= 10_000 else { throw EditorError.invalidChange }
        var introduced = Set<ElementID>()
        for mutation in mutations {
            switch mutation {
            case .insertBlock(let block, let id, let after):
                _ = try Document(blocks: [block]); try reference(after)
                guard id.change == change.id, id.index >= 0, introduced.insert(id).inserted, after != id else { throw EditorError.invalidChange }
            case .moveBlock(let blockID, let id, let after):
                try reference(after)
                guard !blockID.isEmpty, id.change == change.id, id.index >= 0, introduced.insert(id).inserted, after != id else { throw EditorError.invalidChange }
            case .deleteBlock(let blockID):
                guard !blockID.isEmpty else { throw EditorError.invalidChange }
            case .setField(_, let path, let value):
                guard let last = path.last, !["id", "type", "content", "summary", "caption", "code", "expression", "children", "items", "rows", "cells"].contains(last),
                      value.array == nil, value.object == nil, path.count <= 100 else { throw EditorError.invalidPath }
            case .insertText(let target, let atoms):
                try address(target)
                for atom in atoms {
                    try Validation.inline(.array([atom.node]))
                    try reference(atom.after)
                    guard atom.id.change == change.id, atom.id.index >= 0, introduced.insert(atom.id).inserted,
                          atom.after != atom.id else { throw EditorError.invalidChange }
                    if atom.node["type"]?.string == "text" {
                        guard atom.node["text"]?.string?.unicodeScalars.count == 1 else { throw EditorError.invalidChange }
                    } else {
                        guard ["mention", "entity-ref", "date", "emoji", "inline-math"].contains(atom.node["type"]?.string ?? ""),
                              !plainText([atom.node]).isEmpty else { throw EditorError.invalidChange }
                    }
                    if let after = atom.after, after.change == change.id, after.index >= atom.id.index { throw EditorError.invalidChange }
                }
            case .deleteText(let target, let ids):
                try address(target); for id in ids { try reference(id) }
            case .formatText(let target, let ids, let type, let mark):
                try address(target); for id in ids { try reference(id) }
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
