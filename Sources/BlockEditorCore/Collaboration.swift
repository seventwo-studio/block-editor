import Foundation

/// Lamport time followed by locale-independent UTF-8 actor ordering.
public struct ChangeID: Codable, Hashable, Comparable, Sendable {
    public let counter: UInt64
    public let actor: String
    public init(counter: UInt64, actor: String) { self.counter = counter; self.actor = actor }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.actor.utf8.lexicographicallyPrecedes(rhs.actor.utf8) : lhs.counter < rhs.counter
    }
}

public struct ElementID: Codable, Hashable, Comparable, Sendable {
    public let change: ChangeID
    public let index: Int
    public init(change: ChangeID, index: Int) { self.change = change; self.index = index }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.change == rhs.change ? lhs.index < rhs.index : lhs.change < rhs.change
    }
}

public struct TextAddress: Codable, Hashable, Sendable {
    public let blockID: String
    public let path: [String]
    /// Protocol v2 positions and mutations follow this identity across moves.
    public let identity: NodeID?
    public init(_ blockID: String, path: [String] = ["content"], identity: NodeID? = nil) {
        self.blockID = blockID; self.path = path; self.identity = identity
    }
}

/// Which side of an adjacent atom a position follows when text is inserted there.
public enum TextAffinity: String, Codable, Sendable { case before, after }

/// An ephemeral position, resolved against the current document after remote edits.
/// A nil anchor means the end for `before`, or the start for `after`.
public struct TextPosition: Codable, Equatable, Sendable {
    public let documentID: String
    public let address: TextAddress
    public let anchor: ElementID?
    public let affinity: TextAffinity
    /// A display selection may sit inside an atomic reference label without editing it.
    public let intraAtomOffset: Int?
    public init(documentID: String, address: TextAddress, anchor: ElementID?, affinity: TextAffinity, intraAtomOffset: Int? = nil) {
        self.documentID = documentID; self.address = address; self.anchor = anchor; self.affinity = affinity
        self.intraAtomOffset = intraAtomOffset
    }
}

public struct TextAtom: Codable, Equatable, Sendable {
    public let id: ElementID
    public let after: ElementID?
    public var node: JSONValue
    public init(id: ElementID, after: ElementID?, node: JSONValue) { self.id = id; self.after = after; self.node = node }
}

public enum Mutation: Codable, Equatable, Sendable {
    case insertBlock(block: Block, placement: ElementID, after: ElementID?)
    case moveBlock(blockID: String, placement: ElementID, after: ElementID?)
    case deleteBlock(blockID: String)
    case setField(blockID: String, path: [String], value: JSONValue)
    case insertText(address: TextAddress, atoms: [TextAtom])
    case deleteText(address: TextAddress, ids: [ElementID])
    case formatText(address: TextAddress, ids: [ElementID], markType: String, mark: JSONValue?)
    case insertNode(value: JSONValue, identity: NodeID, collection: NodeCollection, placement: ElementID, after: NodePlacementID?)
    case moveNode(identity: NodeID, collection: NodeCollection, placement: ElementID, after: NodePlacementID?)
    /// Observed removal retains concurrent descendants that the author never saw.
    case deleteNodes(identities: [NodeID])
    case setNodeField(identity: NodeID, path: [String], value: JSONValue)
}

public enum ChangeBody: Codable, Equatable, Sendable {
    case edit([Mutation])
    case setActive(target: ChangeID, active: Bool)
}

public struct Change: Codable, Equatable, Sendable {
    public let id: ChangeID
    public let body: ChangeBody
    public init(id: ChangeID, body: ChangeBody) { self.id = id; self.body = body }
}

/// Exact receipt IDs deliberately avoid falsely acknowledging gaps in reordered delivery.
public struct SyncState: Codable, Equatable, Sendable {
    public let received: Set<ChangeID>
    public let documentID: String?
    public let version: Int?
    public init(received: Set<ChangeID> = [], documentID: String? = nil, version: Int? = nil) {
        self.received = received; self.documentID = documentID; self.version = version
    }
}

public struct ChangeBatch: Codable, Equatable, Sendable {
    public let version: Int
    public let documentID: String
    public let baseline: Document
    public let changes: [Change]
    public init(documentID: String, baseline: Document, changes: [Change], version: Int = 1) {
        self.version = version; self.documentID = documentID; self.baseline = baseline; self.changes = changes
    }
}

public struct Presence: Codable, Equatable, Sendable {
    public let actor: String
    public let address: TextAddress?
    public let anchor: ElementID?
    public let focus: ElementID?
    /// Host-supplied monotonic revision; expiry and authenticated actor binding belong to the host.
    public let revision: UInt64
    public init(actor: String, address: TextAddress? = nil, anchor: ElementID? = nil, focus: ElementID? = nil, revision: UInt64) {
        self.actor = actor; self.address = address; self.anchor = anchor; self.focus = focus; self.revision = revision
    }
}

struct Materialized {
    struct Placement { let id: ElementID; let after: ElementID?; let blockID: String }
    var blocks: [String: Block] = [:]
    var placements: [ElementID: Placement] = [:]
    var selectedPlacement: [String: ElementID] = [:]
    var deletedBlocks = Set<String>()
    var texts: [TextAddress: [ElementID: TextAtom]] = [:]
    var deletedAtoms: [TextAddress: Set<ElementID>] = [:]
    var hiddenAtoms: [TextAddress: Set<ElementID>] = [:]
    var dirtyText = Set<TextAddress>()
    var structure: StructuralState?

    static func seed(_ baseline: Document, version: Int = 1) -> Self {
        var result = Self()
        if version == 2 { result.structure = .seed(baseline) }
        var previous: ElementID?
        for (index, block) in baseline.blocks.enumerated() {
            let id = ElementID(change: ChangeID(counter: 0, actor: ""), index: index)
            result.blocks[block.id] = block
            result.placements[id] = Placement(id: id, after: previous, blockID: block.id)
            result.selectedPlacement[block.id] = id
            previous = id
        }
        return result
    }

    mutating func ensureText(_ address: TextAddress) {
        guard texts[address] == nil else { return }
        let value = textValue(address)
        let nodes = value?.array ?? value?.string.map { [textNode($0)] } ?? []
        var atoms: [ElementID: TextAtom] = [:]
        var previous: ElementID?
        // Each text field has its own ID namespace; IDs are always resolved with the address.
        for node in nodes {
            let parts: [JSONValue]
            if node["type"]?.string == "text" {
                parts = (node["text"]?.string ?? "").unicodeScalars.map { scalar in
                    var fields = node.object ?? [:]; fields["text"] = .string(String(scalar)); return .object(fields)
                }
            } else { parts = [node] }
            for part in parts {
                let id = ElementID(change: ChangeID(counter: 0, actor: ""), index: atoms.count)
                atoms[id] = TextAtom(id: id, after: previous, node: part); previous = id
            }
        }
        texts[address] = atoms
        if let identity = address.identity, structure?.nodes[identity]?.birthActive == false {
            hiddenAtoms[address, default: []].formUnion(atoms.keys)
        }
    }

    func textValue(_ address: TextAddress) -> JSONValue? {
        if let structure, let identity = address.identity, let field = address.path.last {
            return structure.nodes[identity]?.fields[field]
        }
        return blocks[address.blockID]?.value(at: address.path)
    }

    func canonicalAddress(_ address: TextAddress) throws -> TextAddress {
        guard let structure else {
            guard address.identity == nil else { throw EditorError.invalidPath }; return address
        }
        guard let field = address.path.last else { throw EditorError.invalidPath }
        let identity = try address.identity ?? structure.node(at: NodeAddress(address.blockID, path: Array(address.path.dropLast())))
        guard structure.visibleNodes(try structure.effectivePlacements()).contains(identity) else { throw EditorError.invalidPath }
        return identity.textAddress(field)
    }

    /// Iterative RGA traversal. Tombstones remain anchors, including undone insertions.
    static func order<T>(_ elements: [ElementID: T], after: (T) -> ElementID?) -> [ElementID] {
        var children: [ElementID: [ElementID]] = [:]
        var roots: [ElementID] = []
        for (id, element) in elements {
            if let parent = after(element) { children[parent, default: []].append(id) }
            else { roots.append(id) }
        }
        var stack = roots.sorted()
        var result: [ElementID] = []
        var seen = Set<ElementID>()
        while let id = stack.popLast() {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
            stack.append(contentsOf: (children[id] ?? []).sorted())
        }
        return result
    }

    func visibleAtoms(_ address: TextAddress) -> [TextAtom] {
        let atoms = texts[address] ?? [:]
        let deleted = (deletedAtoms[address] ?? []).union(hiddenAtoms[address] ?? [])
        return Self.order(atoms, after: { $0.after }).compactMap { deleted.contains($0) ? nil : atoms[$0] }
    }

    func blockOrder() -> [String] {
        if let structure {
            return ((try? structure.visibleOrder(in: .root)) ?? []).compactMap { structure.nodes[$0]?.label }
        }
        return Self.order(placements, after: { $0.after }).compactMap { id in
            guard let p = placements[id], selectedPlacement[p.blockID] == id,
                  !deletedBlocks.contains(p.blockID), blocks[p.blockID] != nil else { return nil }
            return p.blockID
        }
    }

    func document() throws -> Document {
        if let structure {
            var values: [NodeID: [String: JSONValue]] = [:]
            for address in dirtyText {
                guard let identity = address.identity, let field = address.path.last else { throw EditorError.invalidPath }
                values[identity, default: [:]][field] = inlineValue(address)
            }
            return try structure.document(text: values)
        }
        var values = blocks
        for address in dirtyText {
            guard var block = values[address.blockID] else { continue }
            block.fields = try JSONValue.object(block.fields).setting(address.path, to: inlineValue(address)).object ?? block.fields
            values[address.blockID] = block
        }
        return try Document(blocks: blockOrder().compactMap { values[$0] })
    }

    private func inlineValue(_ address: TextAddress) -> JSONValue {
        var nodes: [JSONValue] = []
        for atom in visibleAtoms(address) {
            let node = atom.node
            if node["type"]?.string == "text", var last = nodes.last?.object, last["type"]?.string == "text" {
                var lhs = last, rhs = node.object ?? [:]
                lhs.removeValue(forKey: "text"); rhs.removeValue(forKey: "text")
                if lhs == rhs {
                    last["text"] = .string((last["text"]?.string ?? "") + (node["text"]?.string ?? ""))
                    nodes[nodes.count - 1] = .object(last); continue
                }
            }
            nodes.append(node)
        }
        return textValue(address)?.string != nil ? .string(plainText(nodes)) : .array(nodes)
    }
}

func materialize(_ baseline: Document, _ changes: [Change], version: Int = 1) throws -> Materialized {
    let sorted = changes.sorted { $0.id < $1.id }
    var active: [ChangeID: Bool] = [:]
    var history: [ChangeID: Change] = [:]
    for change in sorted {
        history[change.id] = change
        if case .setActive(let target, let value) = change.body { active[target] = value }
    }
    var state = Materialized.seed(baseline, version: version)
    for change in sorted {
        // Validate creation paths against their containing collection, including
        // histories whose causal parents arrived after an earlier receive.
        try validate(change, version: version, structure: state.structure, history: history)
        guard case .edit(let mutations) = change.body else { continue }
        let enabled = active[change.id] ?? true
        try apply(mutations, enabled: enabled, to: &state)
    }
    return state
}

// Shared by deterministic replay and the strictly-newest local edit path.
func apply(_ mutations: [Mutation], enabled: Bool, to state: inout Materialized) throws {
    for mutation in mutations {
        switch mutation {
        case .insertBlock(let block, let id, let after):
            // Placements survive undo so remote insertions after them retain their position.
            state.placements[id] = .init(id: id, after: after, blockID: block.id)
            if enabled {
                state.blocks[block.id] = block; state.selectedPlacement[block.id] = id
            }
        case .moveBlock(let blockID, let id, let after):
            state.placements[id] = .init(id: id, after: after, blockID: blockID)
            if enabled { state.selectedPlacement[blockID] = id }
        case .deleteBlock(let blockID):
            if enabled { state.deletedBlocks.insert(blockID) }
        case .setField(let blockID, let path, let value):
            if enabled, var block = state.blocks[blockID] {
                block.fields = try JSONValue.object(block.fields).setting(path, to: value).object ?? block.fields
                state.blocks[blockID] = block
            }
        case .insertText(let address, let atoms):
            state.ensureText(address)
            for atom in atoms {
                state.texts[address, default: [:]][atom.id] = atom
                if !enabled { state.hiddenAtoms[address, default: []].insert(atom.id) }
            }
            state.dirtyText.insert(address)
            if enabled, let identity = address.identity, !atoms.isEmpty { state.structure?.touched.insert(identity) }
        case .deleteText(let address, let ids):
            state.ensureText(address)
            if enabled { state.deletedAtoms[address, default: []].formUnion(ids) }
            state.dirtyText.insert(address)
            if enabled, let identity = address.identity, !ids.isEmpty { state.structure?.touched.insert(identity) }
        case .formatText(let address, let ids, let markType, let mark):
            state.ensureText(address)
            if enabled {
                for id in ids {
                    guard var atom = state.texts[address]?[id], var fields = atom.node.object,
                          fields["type"]?.string == "text" else { continue }
                    var marks = (fields["marks"]?.array ?? []).filter { $0["type"]?.string != markType }
                    if let mark { marks.append(mark) }
                    marks.sort { ($0["type"]?.string ?? "").utf8.lexicographicallyPrecedes(($1["type"]?.string ?? "").utf8) }
                    fields["marks"] = .array(marks); atom.node = .object(fields)
                    state.texts[address]?[id] = atom
                }
            }
            state.dirtyText.insert(address)
            if enabled, let identity = address.identity, !ids.isEmpty { state.structure?.touched.insert(identity) }
        case .insertNode(let value, let identity, let collection, let id, let after):
            guard var structure = state.structure else { throw EditorError.unsupportedVersion(2) }
            // Missing causal owners remain unapplied until their insertion arrives.
            let kind: NodeKind
            if collection.owner != nil, structure.nodes[collection.owner!] == nil { continue }
            kind = try structure.kind(in: collection)
            try validateNode(value, kind: kind)
            structure.register(value, identity: identity, kind: kind, active: enabled)
            let placement = NodePlacementID.edit(id)
            structure.placements[placement] = .init(id: placement, after: after, node: identity, collection: collection, active: true)
            state.structure = structure
        case .moveNode(let identity, let collection, let id, let after):
            guard var structure = state.structure else { throw EditorError.unsupportedVersion(2) }
            if let node = structure.nodes[identity], collection.owner == nil || structure.nodes[collection.owner!] != nil {
                guard try structure.kind(in: collection) == node.kind else { throw EditorError.invalidPath }
            }
            let placement = NodePlacementID.edit(id)
            structure.placements[placement] = .init(id: placement, after: after, node: identity, collection: collection, active: enabled)
            if enabled { structure.touched.insert(identity) }
            state.structure = structure
        case .deleteNodes(let identities):
            guard state.structure != nil else { throw EditorError.unsupportedVersion(2) }
            if enabled { state.structure?.deleted.formUnion(identities) }
        case .setNodeField(let identity, let path, let value):
            guard var structure = state.structure else { throw EditorError.unsupportedVersion(2) }
            if enabled, var node = structure.nodes[identity] {
                node.fields = try JSONValue.object(node.fields).setting(path, to: value).object ?? node.fields
                structure.nodes[identity] = node; structure.touched.insert(identity)
            }
            state.structure = structure
        }
    }
}
