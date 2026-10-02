import Foundation

// Internal prototype for the proposed v3 writing contract. It is not an accepted
// session/bridge protocol and cannot change v1/v2 replay or package consumers.
public struct WritingField: Codable, Hashable, Sendable {
    public let node: NodeID
    public let name: String
    public init(node: NodeID, name: String) { self.node = node; self.name = name }
    var key: String { node.key + "/" + name }
}
public struct WritingAtomKey: Codable, Hashable, Comparable, Sendable {
    public let origin: WritingField
    public let element: ElementID
    public init(origin: WritingField, element: ElementID) { self.origin = origin; self.element = element }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.element == rhs.element ? lhs.origin.key.utf8.lexicographicallyPrecedes(rhs.origin.key.utf8) : lhs.element < rhs.element
    }
}
public enum WritingEdge: Codable, Equatable, Sendable {
    case start, before(WritingAtomKey), after(WritingAtomKey)
    var anchor: WritingAtomKey? {
        switch self { case .start: nil; case .before(let key), .after(let key): key }
    }
}
public enum WritingRoute: Codable, Equatable, Sendable {
    case field(WritingField), follow(WritingAtomKey)
}
public struct WritingAtomSeed: Codable, Equatable, Sendable {
    public let key: WritingAtomKey
    public let node: JSONValue
    public let edge: WritingEdge
    public let route: WritingRoute
    public init(key: WritingAtomKey, node: JSONValue, edge: WritingEdge, route: WritingRoute) {
        self.key = key; self.node = node; self.edge = edge; self.route = route
    }
}
public enum WritingMutation: Codable, Equatable, Sendable {
    case insert(WritingAtomSeed)
    case transfer(keys: [WritingAtomKey], destination: WritingField, edge: WritingEdge)
    case delete(keys: [WritingAtomKey])
    case format(keys: [WritingAtomKey], type: String, mark: JSONValue?)
    case join(source: WritingField, destination: WritingField, edge: WritingEdge)
    case splitBoundary(source: WritingField, destination: WritingField, edge: WritingEdge, before: NodeID?)
    /// Protocol 5 orders a complete same-edit birth chain at one retained cut.
    case spliceBoundary(source: WritingField, destination: WritingField, edge: WritingEdge, before: NodeID?, members: [NodeID])
}
public struct WritingEdit: Codable, Equatable, Sendable {
    public let id: ChangeID
    public let mutations: [WritingMutation]
    public init(id: ChangeID, mutations: [WritingMutation]) { self.id = id; self.mutations = mutations }
}
enum WritingProjectionError: Error, Equatable {
    case duplicateAtom, missingAtom, placementCycle, routeCycle
}

/// Atom payloads are globally keyed by immutable origin. Active transfers change
/// only placements; inactive author edits retain birth records as tombstones.
struct WritingProjection {
    private struct Placement {
        let edge: WritingEdge
        let route: WritingRoute
    }
    private var nodes: [WritingAtomKey: JSONValue] = [:]
    private var placements: [WritingAtomKey: Placement] = [:]
    private var hidden = Set<WritingAtomKey>()
    private var redirectSources = Set<WritingField>()
    private var joins: [WritingField: (destination: WritingField, edge: WritingEdge)] = [:]
    private var fields: [WritingAtomKey: WritingField] = [:]
    private var order: [WritingAtomKey] = []

    init(seeds: [WritingAtomSeed], edits: [WritingEdit], active: [ChangeID: Bool] = [:], emptyFields: Set<WritingField> = [], hiddenSeeds: Set<WritingAtomKey> = [], redirects: [WritingField: WritingField] = [:]) throws {
        hidden = hiddenSeeds
        let sorted = edits.sorted { $0.id < $1.id }
        var births: [WritingAtomKey: WritingAtomSeed] = [:]
        func retain(_ atom: WritingAtomSeed) throws {
            guard births[atom.key] == nil else { throw WritingProjectionError.duplicateAtom }
            births[atom.key] = atom
        }
        for atom in seeds { try retain(atom) }
        // Collect causal births before applying operations. This deliberately
        // rejects incomplete proposals rather than acknowledging missing atoms.
        for edit in sorted {
            for mutation in edit.mutations {
                if case .insert(let atom) = mutation { try retain(atom) }
            }
        }
        var knownFields = emptyFields.union(births.keys.map(\.origin))
        for edit in sorted {
            for mutation in edit.mutations {
                switch mutation {
                case .transfer(_, let destination, _): knownFields.insert(destination)
                case .join(let source, let destination, _): knownFields.insert(source); knownFields.insert(destination)
                case .splitBoundary(let source, let destination, _, _), .spliceBoundary(let source, let destination, _, _, _): knownFields.insert(source); knownFields.insert(destination)
                case .insert(let atom): if case .field(let field) = atom.route { knownFields.insert(field) }
                default: break
                }
            }
        }
        for field in knownFields {
            let head = Self.head(field)
            nodes[head] = .null
            placements[head] = Placement(edge: .start, route: .field(field))
        }
        for atom in births.values {
            nodes[atom.key] = atom.node
            placements[atom.key] = Placement(edge: atom.edge, route: atom.route)
        }
        for edit in sorted {
            let enabled = active[edit.id] ?? true
            for mutation in edit.mutations {
                switch mutation {
                case .insert(let atom):
                    if !enabled { hidden.insert(atom.key) }
                case .transfer(let keys, let destination, let firstEdge):
                    guard !keys.isEmpty, Set(keys).count == keys.count else { throw WritingProjectionError.duplicateAtom }
                    for key in keys { guard births[key] != nil else { throw WritingProjectionError.missingAtom } }
                    if enabled {
                        var edge = firstEdge
                        for key in keys {
                            placements[key] = Placement(edge: edge, route: .field(destination))
                            edge = .after(key)
                        }
                    }
                case .delete(let keys):
                    for key in keys { guard births[key] != nil else { throw WritingProjectionError.missingAtom } }
                    if enabled { hidden.formUnion(keys) }
                case .format(let keys, let type, let mark):
                    for key in keys { guard births[key] != nil else { throw WritingProjectionError.missingAtom } }
                    if enabled {
                        for key in keys {
                            guard var node = nodes[key]?.object, node["type"] == .string("text") else { continue }
                            var marks = (node["marks"]?.array ?? []).filter { $0["type"]?.string != type }
                            if let mark { marks.append(mark) }
                            marks.sort { ($0["type"]?.string ?? "").utf8.lexicographicallyPrecedes(($1["type"]?.string ?? "").utf8) }
                            node["marks"] = .array(marks); nodes[key] = .object(node)
                        }
                    }
                case .join(let source, let destination, let edge):
                    if enabled { joins[source] = (destination, edge) }
                case .splitBoundary, .spliceBoundary: break
                }
            }
        }
        for (source, destination) in redirects where source != destination && joins[source] == nil {
            joins[source] = (destination, .start); redirectSources.insert(source)
        }
        try resolveFields()
        try resolveOrder()
    }

    private static func head(_ field: WritingField) -> WritingAtomKey {
        WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: -1))
    }
    var joinedSources: Set<WritingField> { Set(joins.keys).subtracting(redirectSources) }
    var retainedKeys: Set<WritingAtomKey> { Set(nodes.keys.filter { $0.element.index >= 0 }) }
    func visibleKeys(in field: WritingField) -> [WritingAtomKey] {
        order.filter { fields[$0] == field && !hidden.contains($0) && $0.element.index >= 0 }
    }
    func nodes(in field: WritingField) -> [JSONValue] {
        visibleKeys(in: field).compactMap { nodes[$0] }
    }
    func text(in field: WritingField) -> String { plainText(nodes(in: field)) }
    /// Birth-route ancestry for concurrent cut ownership. Projection callers can
    /// distinguish unobserved descendants from atoms explicitly pinned later.
    func follows(_ key: WritingAtomKey, anyOf anchors: Set<WritingAtomKey>) throws -> Bool {
        var current = key, seen = Set<WritingAtomKey>()
        while true {
            if anchors.contains(current) { return true }
            guard seen.insert(current).inserted else { throw WritingProjectionError.routeCycle }
            guard let placement = placements[current] else { throw WritingProjectionError.missingAtom }
            switch placement.route {
            case .field: return false
            case .follow(let next): current = next
            }
        }
    }
    func field(of key: WritingAtomKey) throws -> WritingField {
        guard let field = fields[key] else { throw WritingProjectionError.missingAtom }
        return field
    }
    func destination(of field: WritingField) throws -> WritingField { try self.field(of: Self.head(field)) }
    func startOffset(of field: WritingField) throws -> Int { try offset(of: Self.head(field), affinity: .after) }
    func value(of key: WritingAtomKey) throws -> JSONValue {
        guard key.element.index >= 0, let value = nodes[key] else { throw WritingProjectionError.missingAtom }
        return value
    }
    func offset(of key: WritingAtomKey, affinity: TextAffinity) throws -> Int {
        let field = try field(of: key)
        var offset = 0
        for member in order where fields[member] == field {
            if member == key, affinity == .before { return offset }
            if member.element.index >= 0, !hidden.contains(member) {
                offset += plainText([try value(of: member)]).utf16.count
            }
            if member == key { return offset }
        }
        throw WritingProjectionError.missingAtom
    }
    /// Split ordering uses retained ancestry, so deleting text between two cuts
    /// cannot collapse their ranks and retarget a surviving remote suffix.
    func retainedOffset(of key: WritingAtomKey, affinity: TextAffinity) throws -> Int {
        let field = try field(of: key)
        var offset = 0
        for member in order where fields[member] == field {
            if member == key, affinity == .before { return offset }
            if member.element.index >= 0 { offset += plainText([try value(of: member)]).utf16.count }
            if member == key { return offset }
        }
        throw WritingProjectionError.missingAtom
    }

    private mutating func resolveFields() throws {
        for key in writingAtomsSorted(Array(nodes.keys)) where fields[key] == nil {
            var cursor = key, chain: [WritingAtomKey] = [], seen = Set<WritingAtomKey>()
            var result: WritingField?
            while result == nil {
                if let known = fields[cursor] { result = known; break }
                guard seen.insert(cursor).inserted else { throw WritingProjectionError.routeCycle }
                guard let placement = placements[cursor] else { throw WritingProjectionError.missingAtom }
                chain.append(cursor)
                switch placement.route {
                case .field(let field):
                    let head = Self.head(field)
                    if cursor == head {
                        if let join = joins[field] { cursor = join.edge.anchor ?? Self.head(join.destination) }
                        else { result = field }
                    } else { cursor = head }
                case .follow(let anchor): cursor = anchor
                }
            }
            for member in chain { fields[member] = result! }
        }
    }

    private mutating func resolveOrder() throws {
        var before: [WritingAtomKey: [WritingAtomKey]] = [:]
        var after: [WritingAtomKey: [WritingAtomKey]] = [:]
        var roots: [WritingAtomKey] = []
        for (key, placement) in placements {
            var edge = placement.edge
            if key.element.index == -1, let join = joins[key.origin] {
                edge = join.edge == .start ? .after(Self.head(join.destination)) : join.edge
            } else if edge == .start, key.element.index >= 0 {
                guard case .field(let field) = placement.route else { throw WritingProjectionError.missingAtom }
                edge = .after(Self.head(field))
            }
            if let anchor = edge.anchor, nodes[anchor] == nil { throw WritingProjectionError.missingAtom }
            switch edge {
            case .start: roots.append(key)
            case .before(let anchor): before[anchor, default: []].append(key)
            case .after(let anchor): after[anchor, default: []].append(key)
            }
        }
        // Before-anchor children stay before their content even when that anchor
        // moves after another field's final atom. Sorted sibling order is immutable
        // creation order, never the timestamp of the move that carried a suffix.
        enum Frame { case enter(WritingAtomKey), emit(WritingAtomKey), exit(WritingAtomKey) }
        var stack = writingAtomsSorted(roots).map(Frame.enter)
        var entering = Set<WritingAtomKey>(), seen = Set<WritingAtomKey>()
        while let frame = stack.popLast() {
            switch frame {
            case .enter(let key):
                guard !entering.contains(key), !seen.contains(key) else { throw WritingProjectionError.placementCycle }
                entering.insert(key)
                stack.append(.exit(key))
                stack.append(contentsOf: writingAtomsSorted(after[key] ?? []).map(Frame.enter))
                stack.append(.emit(key))
                stack.append(contentsOf: writingAtomsSorted(before[key] ?? []).map(Frame.enter))
            case .emit(let key): order.append(key); seen.insert(key)
            case .exit(let key): entering.remove(key)
            }
        }
        guard seen.count == nodes.count else { throw WritingProjectionError.placementCycle }
    }
}

/// String equality normalizes Unicode; canonical wire ordering compares bytes.
/// Use raw components for memoization so equivalent spellings retain their order.
private struct RawWritingField: Hashable {
    let components: [Data]
    init(_ field: WritingField) {
        var values: [String]
        switch field.node {
        case .baseline(let blockID, let path): values = ["baseline", blockID] + path
        case .inserted(let creation, let path):
            values = ["inserted", String(creation.change.counter), creation.change.actor, String(creation.index)] + path
        }
        components = (values + [field.name]).map { Data($0.utf8) }
    }
}

/// Encode each exact origin once per sort pass; retain the existing public
/// Comparable contract, including canonically equivalent Unicode spellings.
func writingAtomsSorted(_ keys: [WritingAtomKey]) -> [WritingAtomKey] {
    guard keys.count > 1 else { return keys }
    var encoded: [RawWritingField: String] = [:]
    let decorated = keys.map { key -> (key: WritingAtomKey, origin: String) in
        let raw = RawWritingField(key.origin)
        let value: String
        if let existing = encoded[raw] { value = existing }
        else { value = key.origin.key; encoded[raw] = value }
        return (key, value)
    }
    return decorated.sorted { lhs, rhs in
        if lhs.key.element != rhs.key.element { return lhs.key.element < rhs.key.element }
        return lhs.origin.utf8.lexicographicallyPrecedes(rhs.origin.utf8)
    }.map(\.key)
}
