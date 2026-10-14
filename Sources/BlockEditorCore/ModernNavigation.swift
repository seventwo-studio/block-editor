import Foundation

public struct ModernNodeBinding: Codable, Sendable {
    public let address: NodeAddress
    public let node: NodeID
    public let kind: String
    public let fields: [String: WritingField]
}
public struct ModernRenderingBindings: Sendable {
    public let token: String
    /// Nil only when this session confirms the caller's exact current token.
    public let bindings: [ModernNodeBinding]?
}

/// Trusted output only. Retain the public Codable shape without encoding an
/// entire binding array into bytes and decoding it again before bridge output.
/// Incoming requests still use the original admission/round-trip checks.
func modernNodeBindingValue(_ binding: ModernNodeBinding) throws -> JSONValue {
    func identity(_ node: NodeID) throws -> JSONValue {
        switch node {
        case .document(let documentID): return .object(["document": .object(["documentID": .string(documentID)])])
        case .baseline(let blockID, let path): return .object(["baseline": .object(["blockID": .string(blockID), "path": .array(path.map(JSONValue.string))])])
        case .inserted(let creation, let path):
            // Every admitted modern origin uses exactly representable integer
            // identities. Fail rather than round an incompatible trusted value.
            guard creation.change.counter > 0, creation.change.counter <= 9_007_199_254_740_991,
                  creation.index >= 0, creation.index <= 2_147_483_647 else { throw EditorError.invalidChange }
            let value = JSONValue.object(["change": .object(["counter": .number(Double(creation.change.counter)), "actor": .string(creation.change.actor)]),
                "index": .number(Double(creation.index))])
            return .object(["inserted": .object(["creation": value, "path": .array(path.map(JSONValue.string))])])
        }
    }
    var fields: [String: JSONValue] = [:]
    for (name, field) in binding.fields { fields[name] = .object(["node": try identity(field.node), "name": .string(field.name)]) }
    return .object(["address": .object(["blockID": .string(binding.address.blockID), "path": .array(binding.address.path.map(JSONValue.string))]),
        "node": try identity(binding.node), "kind": .string(binding.kind), "fields": .object(fields)])
}

extension ModernSession {
    /// A bounded, session-local presentation cache. It never authorizes a
    /// command or enters history. Aliases/cross-field graphs take a full read.
    public func renderingBindings(knownToken: String? = nil) throws -> ModernRenderingBindings {
        let current = modernCurrentReplay
        let lease = current.2.renderingReadLease
        if current.0.usesIndependentFields {
            if let cached = renderingBindingCache, cached.lease === lease {
                return ModernRenderingBindings(token: cached.token, bindings: knownToken == cached.token ? nil : cached.bindings)
            }
            let bindings = try nodeBindings(), token = UUID().uuidString
            renderingBindingCache = (lease, token, bindings)
            return ModernRenderingBindings(token: token, bindings: bindings)
        }
        renderingBindingCache = nil
        return ModernRenderingBindings(token: UUID().uuidString, bindings: try nodeBindings())
    }
    /// Renderers receive checked origins in one read, without deriving an
    /// identity from a display label or changing document/history state.
    public func nodeBindings() throws -> [ModernNodeBinding] {
        let shape = modernCurrentReplay.2
        let addresses = try shape.cutoverAddresses()
        let availableFields = Dictionary(grouping: retainedWritingFields(shape).keys, by: \.node)
        return try logicalNodes(shape).map { node in
            guard let address = addresses[node], let value = shape.nodes[node], value.kind != .document else { throw EditorError.invalidPath }
            var fields: [String: WritingField] = [:]
            for available in availableFields[node] ?? [] { fields[available.name] = try field(node: node, name: available.name) }
            return ModernNodeBinding(address: address, node: node, kind: value.kind.rawValue, fields: fields)
        }
    }
    /// Catalog blocks are siblings of the containing block, never cells or list
    /// items. Capture this once before a picker takes the native input focus.
    public func captureInsertionBoundary(after field: WritingField) throws -> ModernBlockBoundary {
        _ = try text(in: field)
        if field == titleField { return try captureBoundary(after: nodes().last) }
        var node = field.node, visited = Set<NodeID>()
        while visited.insert(node).inserted {
            let collection = try parentCollection(of: node)
            if try structure.kind(in: collection) == .block { return try captureBoundary(in: collection, after: node) }
            guard let owner = collection.owner else { throw EditorError.invalidPath }
            node = owner
        }
        throw EditorError.invalidPath
    }
    /// Logical reading order, independent of the visual column presentation.
    /// A disclosed container retains its own field while hidden descendants are
    /// omitted only from this local navigation projection.
    public func logicalFields(collapsed: Set<NodeID> = [], includingTitle: Bool = true) throws -> [WritingField] {
        let view = try logicalFieldView(collapsed: collapsed)
        return includingTitle ? view.fields : Array(view.fields.dropFirst())
    }
    private func logicalFieldView(collapsed: Set<NodeID>) throws -> (fields: [WritingField], indices: [WritingField: Int]) {
        let current = modernCurrentReplay
        let lease = current.2.renderingReadLease
        // Set equality normalizes Swift strings; exact encoded origins distinguish
        // local collapse requests without changing their existing resolution rules.
        let collapseKey = try collapsed.map { try canonicalEncoder().encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        if current.0.usesIndependentFields, let cached = logicalFieldCache,
           cached.lease === lease, cached.collapsed == collapseKey {
            return (cached.fields, cached.indices)
        }
        let hidden = try Set(collapsed.flatMap { container in try structure.descendants(of: container).filter { $0 != container } })
        let births = retainedWritingFields(structure)
        let fields = [titleField] + (try logicalNodes(structure)).filter { !hidden.contains($0) }.flatMap { node in
            ["content", "summary", "caption", "code", "expression"].map { WritingField(node: node, name: $0) }.filter { births[$0] != nil }
        }
        // Preserve the firstIndex semantics even for canonically equal origins.
        var indices: [WritingField: Int] = [:]
        for (index, field) in fields.enumerated() where indices[field] == nil { indices[field] = index }
        if current.0.usesIndependentFields { logicalFieldCache = (lease, collapseKey, fields, indices) }
        else { logicalFieldCache = nil }
        return (fields, indices)
    }
    public func parentCollection(of node: NodeID) throws -> NodeCollection {
        _ = try structure.address(of: node)
        guard let placement = try structure.effectivePlacements()[node] else { throw EditorError.invalidPath }
        return placement.collection
    }
    /// One capture cohort for all fields in a directed text selection. Each
    /// range selects its captured atoms; subsequent peer insertions stay intact.
    public func captureTextSpan(from start: WritingPosition, to end: WritingPosition, collapsed: Set<NodeID> = []) throws -> [ModernTextRange] {
        let view = try logicalFieldView(collapsed: collapsed), fields = view.fields
        let first = try resolve(start), last = try resolve(end)
        let firstField = try start.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: start.field)
        let lastField = try end.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: end.field)
        guard let a = view.indices[firstField], let b = view.indices[lastField] else { throw EditorError.invalidRange }
        if a == b { return [try captureTextRange(in: firstField, start: first.offset, end: last.offset)] }
        guard firstField != titleField, lastField != titleField else { throw EditorError.invalidRange }
        let backward = a > b
        return try Array(fields[min(a, b)...max(a, b)]).map { field in
            let lower = field == (backward ? lastField : firstField) ? (backward ? last.offset : first.offset) : 0
            let upper = field == (backward ? firstField : lastField) ? (backward ? first.offset : last.offset) : try text(in: field).utf16.count
            return try captureTextRange(in: field, start: backward ? upper : lower, end: backward ? lower : upper)
        }
    }
}

/// Multi-field formatting is captured once and committed as one author action.
/// Existing single-field format requests remain source and wire compatible.
public struct ModernTextSpanTarget: Codable, Equatable, Sendable {
    public let ranges: [ModernTextRange]
    public init(ranges: [ModernTextRange]) { self.ranges = ranges }
}
extension ModernSession {
    @discardableResult public func format(in ranges: [ModernTextRange], markType: String, mark: JSONValue?) throws -> ModernStructuralResult {
        try authoringAllowed(command: "format")
        guard !ranges.isEmpty, ranges.count <= 10_000, Set(ranges.map { $0.start.field }).count == ranges.count,
              ranges.allSatisfy({ $0.observed == ranges[0].observed }) else { throw EditorError.invalidRange }
        if ranges.count == 1 { return try format(in: ranges[0], markType: markType, mark: mark) }
        let operations = try ranges.flatMap { try modernMarkOperations(in: $0, type: markType, mark: mark) }
        let target = ModernDeleteTarget(ranges: ranges)
        let backward = try resolve(ranges[0].start).offset > resolve(ranges[0].end).offset
        let result = ModernStructuralResult(focus: .text(backward ? ranges[0].end : ranges.last!.end), selection: .mixed(target))
        endTypingGroup()
        if operations.isEmpty { return result }
        return try performReturning(nextID(), operations, historyBefore: historySelection(target)) { _, _ in result }
    }
    public func markState(in ranges: [ModernTextRange], type: String) throws -> ModernMarkState {
        guard !ranges.isEmpty, ranges.count <= 10_000 else { throw EditorError.invalidRange }
        let states = try ranges.map { try markState(in: $0, type: type) }
        return states.allSatisfy({ $0 == .on }) ? .on : states.allSatisfy({ $0 == .off }) ? .off : .mixed
    }
}
