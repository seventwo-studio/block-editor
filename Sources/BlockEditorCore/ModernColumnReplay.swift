import Foundation

/// One layout birth and retained moves, with an origin-aware restoration boundary.
public struct ModernColumnCreation: Codable, Equatable, Sendable {
    public let layout: JSONValue
    public let identity: NodeID
    public let collection: NodeCollection
    public let placement: ElementID
    public let after: NodePlacementID?
    public let nodes: [NodeID]
    public let sources: [NodePlacementID]
    public init(layout: JSONValue, identity: NodeID, collection: NodeCollection, placement: ElementID,
                after: NodePlacementID?, nodes: [NodeID], sources: [NodePlacementID]) {
        self.layout = layout; self.identity = identity; self.collection = collection; self.placement = placement
        self.after = after; self.nodes = nodes; self.sources = sources
    }
}
struct ModernColumnRoute {
    let layout: NodeID
    let slot: ElementID
    let after: NodePlacementID
    let collection: NodeCollection
    let active: Bool
}

func modernColumnIDs(_ layout: NodeID, in structure: StructuralState) throws -> [NodeID] {
    guard structure.nodes[layout]?.kind == .block, structure.nodes[layout]?.fields["type"] == .string("columns") else { throw EditorError.invalidChange }
    let initial = structure.placements.filter { $0.value.collection == NodeCollection(owner: layout, field: "columns") }
    let selected = Dictionary(uniqueKeysWithValues: initial.values.map { ($0.node, $0) })
    let columns = structure.order(in: NodeCollection(owner: layout, field: "columns"), selected: selected)
    guard columns.count == 2, columns.allSatisfy({ structure.nodes[$0]?.kind == .column }) else { throw EditorError.invalidChange }
    return columns
}
func validateModernColumnCreationShape(_ value: ModernColumnCreation, change: ChangeID) throws {
    guard value.placement.change == change, value.placement.index == 0,
          value.identity == .inserted(creation: value.placement, path: []),
          value.nodes.count <= 10_000, value.nodes.count == value.sources.count,
          Set(value.nodes).count == value.nodes.count, Set(value.sources).count == value.sources.count,
          value.layout["type"] == .string("columns"), value.layout["splitBasisPoints"] == .number(5000),
          let columns = value.layout["columns"]?.array, columns.count == 2,
          columns.allSatisfy({ $0["children"] == .array([]) }) else { throw EditorError.invalidChange }
    try validateNode(value.layout, kind: .block, modern: true)
    try modernColumnCollectionShape(value.collection)
    if let after = value.after { try modernColumnPlacementShape(after) }
    for node in value.nodes { try modernStructuralIdentityShape(node) }
    for source in value.sources { try modernColumnPlacementShape(source) }
}
func modernColumnCollectionShape(_ collection: NodeCollection) throws {
    if collection == .root { return }
    guard let owner = collection.owner, collection.field == "children" else { throw EditorError.invalidChange }
    try modernStructuralIdentityShape(owner)
}
func modernColumnPlacementShape(_ placement: NodePlacementID) throws {
    switch placement {
    case .initial(let node): try modernStructuralIdentityShape(node)
    case .edit(let element): try modernStructuralIdentityShape(.inserted(creation: element, path: []))
    case .columnRoute(let layout, let slot, let node):
        try modernStructuralIdentityShape(layout); try modernStructuralIdentityShape(node)
        try modernStructuralIdentityShape(.inserted(creation: slot, path: []))
        guard slot.index == 0 else { throw EditorError.invalidChange }
    case .role(let owner, let node):
        try modernStructuralIdentityShape(owner); try modernStructuralIdentityShape(node)
        guard owner != node else { throw EditorError.invalidChange }
    }
}
func modernColumnPlacementReference(_ placement: NodePlacementID, change: ChangeID, cohort: Set<ChangeID>, registry: StructuralState) throws {
    try modernColumnPlacementShape(placement)
    switch placement {
    case .initial(let node): try modernReference(node, before: change, cohort: cohort, registry: registry)
    case .edit(let element): guard element.change == change || cohort.contains(element.change) else { throw EditorError.invalidChange }
    case .columnRoute(let layout, let slot, let node):
        try modernReference(layout, before: change, cohort: cohort, registry: registry)
        try modernReference(node, before: change, cohort: cohort, registry: registry)
        guard cohort.contains(slot.change) else { throw EditorError.invalidChange }
    case .role(let owner, let node):
        try modernReference(owner, before: change, cohort: cohort, registry: registry)
        try modernReference(node, before: change, cohort: cohort, registry: registry)
    }
}

func applyModernColumnCreation(_ value: ModernColumnCreation, enabled: Bool, raw: inout Materialized) throws {
    try apply([.insertNode(value: value.layout, identity: value.identity, collection: value.collection,
        placement: value.placement, after: value.after)], enabled: enabled, to: &raw)
    let first = try modernColumnIDs(value.identity, in: raw.structure!)[0]
    var after: NodePlacementID?
    for (index, node) in value.nodes.enumerated() {
        let placement = ElementID(change: value.placement.change, index: index + 1)
        try apply([.moveNode(identity: node, collection: NodeCollection(owner: first, field: "children"), placement: placement, after: after)], enabled: enabled, to: &raw)
        after = .edit(placement)
    }
}

/// Derive a view from retained raw placements. Slot IDs keep historical root
/// anchors distinct even when a later removal captures another layout boundary.
/// Original column owners stay available for offline packet admission.
func projectModernColumnRoutes(_ original: StructuralState, routes: [ModernColumnRoute]) throws -> StructuralState {
    guard !routes.isEmpty else { return original }
    var output = original
    var active: [NodeID: ModernColumnRoute] = [:]
    for route in routes where route.active && (active[route.layout].map({ $0.slot < route.slot }) ?? true) { active[route.layout] = route }
    struct Candidate { let node: NodeID; let source: StructuralState.Placement; let bucket: Int; let rank: Int }
    var candidates: [NodeID: [Candidate]] = [:], columnsByLayout: [NodeID: [NodeID]] = [:]
    for layout in Set(routes.map(\.layout)) {
        let columns = try modernColumnIDs(layout, in: original); columnsByLayout[layout] = columns
        var items: [Candidate] = []
        for (bucket, column) in columns.enumerated() {
            let collection = NodeCollection(owner: column, field: "children")
            let placements = original.placements.values.filter { $0.collection == collection }
            var selected: [NodeID: StructuralState.Placement] = [:]
            for placement in placements where selected[placement.node].map({ $0.id < placement.id }) ?? true { selected[placement.node] = placement }
            let order = original.order(in: collection, selected: selected)
            for (rank, node) in order.enumerated() { items.append(Candidate(node: node, source: selected[node]!, bucket: bucket, rank: rank)) }
        }
        // A node may have historical claims in both columns. The newest claim
        // supplies its inactive anchor; its actual active winner is checked below.
        var newest: [NodeID: Candidate] = [:]
        for item in items where newest[item.node].map({ $0.source.id < item.source.id }) ?? true { newest[item.node] = item }
        candidates[layout] = Array(newest.values)
    }
    for route in routes {
        for item in candidates[route.layout] ?? [] {
            let id = NodePlacementID.columnRoute(layout: route.layout, slot: route.slot, node: item.node)
            output.placements[id] = .init(id: id, after: route.after, node: item.node, collection: route.collection,
                active: false, roleOrigin: item.source.id, columnBucket: item.bucket, columnRank: item.rank)
        }
    }
    // All immutable ordering chains are now present, including inactive routes.
    // Determine the highest raw active claim; normal collision/ancestry validation
    // runs on the complete derived view and retains any unsatisfiable union.
    var selected: [NodeID: StructuralState.Placement] = [:]
    for placement in original.placements.values where placement.active {
        if selected[placement.node].map({ $0.id < placement.id }) ?? true { selected[placement.node] = placement }
    }
    for (layout, route) in active {
        let columns = columnsByLayout[layout]!
        output.deleted.insert(layout); output.deleted.formUnion(columns)
        for item in candidates[layout] ?? [] {
            let source = selected[item.node]
            let routed = source?.collection.owner.map(columns.contains) ?? false
            // Remove every fallback into a flattened owner. Explicit independent
            // moves whose current winner is outside these owners remain intact.
            for (id, placement) in output.placements where placement.node == item.node {
                let owned = placement.collection.owner.map(columns.contains) ?? false
                if owned || routed && id != .columnRoute(layout: layout, slot: route.slot, node: item.node) {
                    output.placements[id] = .init(id: placement.id, after: placement.after, node: placement.node,
                        collection: placement.collection, active: false, rolePriority: placement.rolePriority, roleOrigin: placement.roleOrigin,
                        columnBucket: placement.columnBucket, columnRank: placement.columnRank)
                }
            }
            if routed {
                let id = NodePlacementID.columnRoute(layout: layout, slot: route.slot, node: item.node)
                let placement = output.placements[id]!
                output.placements[id] = .init(id: id, after: route.after, node: item.node, collection: route.collection,
                    active: true, roleOrigin: placement.roleOrigin, columnBucket: placement.columnBucket, columnRank: placement.columnRank)
            }
        }
    }
    return output
}

func modernColumnCollection(_ collection: NodeCollection, structure: StructuralState) throws {
    try modernColumnCollectionShape(collection)
    guard try structure.kind(in: collection) == .block else { throw EditorError.invalidPath }
    var owner = collection.owner
    let placements = try structure.effectivePlacements()
    while let node = owner {
        _ = try structure.address(of: node)
        guard structure.nodes[node]?.kind != .column,
              structure.nodes[node]?.fields["type"] != .string("columns") else { throw EditorError.invalidPath }
        owner = placements[node]?.collection.owner
    }
}
func validateModernColumnCreation(_ value: ModernColumnCreation, in observed: StructuralState) throws {
    try modernColumnCollection(value.collection, structure: observed)
    let order = try observed.visibleOrder(in: value.collection), placements = try observed.effectivePlacements()
    if let after = value.after {
        guard let anchor = observed.placements[after], anchor.collection == value.collection,
              placements[anchor.node]?.id == after else { throw EditorError.invalidPath }
        _ = try observed.address(of: anchor.node)
    }
    if !value.nodes.isEmpty {
        guard let start = order.firstIndex(of: value.nodes[0]), start + value.nodes.count <= order.count,
              Array(order[start..<(start + value.nodes.count)]) == value.nodes,
              value.after == (start == 0 ? nil : placements[order[start - 1]]?.id) else { throw EditorError.invalidPath }
    }
    for (index, node) in value.nodes.enumerated() {
        guard placements[node]?.id == value.sources[index], placements[node]?.collection == value.collection else { throw EditorError.invalidPath }
        for child in try observed.descendants(of: node) {
            guard observed.nodes[child]?.fields["type"] != .string("columns") else { throw EditorError.invalidPath }
        }
    }
    guard !order.contains(where: { observed.nodes[$0]?.label == value.layout["id"]?.string }) else { throw EditorError.invalidChange }
}
func modernCreationRoute(_ value: ModernColumnCreation, enabled: Bool) -> ModernColumnRoute {
    ModernColumnRoute(layout: value.identity, slot: value.placement, after: value.sources.last ?? .edit(value.placement), collection: value.collection, active: !enabled)
}
func modernRemovalRoute(_ layout: NodeID, source: NodePlacementID, change: ChangeID, enabled: Bool, structure: StructuralState) throws -> ModernColumnRoute {
    guard let placement = structure.placements[source], placement.node == layout else { throw EditorError.invalidChange }
    return ModernColumnRoute(layout: layout, slot: ElementID(change: change, index: 0), after: source, collection: placement.collection, active: enabled)
}
