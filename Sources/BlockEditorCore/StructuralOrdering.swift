import Foundation

/// Decorate once per item. These are ephemeral sort keys, never identity or
/// admission keys. Keep each comparator's existing String/UTF8 semantics.
func structuralNodesSorted<S: Sequence>(_ nodes: S) -> [NodeID] where S.Element == NodeID {
    nodes.map { (node: $0, key: $0.key) }.sorted { $0.key < $1.key }.map(\.node)
}

private struct PlacementOrderingKey {
    let tier: Int
    let priority: ElementID?
    let owner: String
    let node: [UInt8]
    init(_ placement: NodePlacementID) {
        switch placement {
        case .initial(let id): tier = 0; priority = nil; owner = ""; node = Array(id.key.utf8)
        case .role(let ownerID, let id): tier = 1; priority = nil; owner = ownerID.key; node = Array(id.key.utf8)
        case .columnRoute(let layout, let slot, let id): tier = 2; priority = slot; owner = layout.key; node = Array(id.key.utf8)
        case .edit(let id): tier = 3; priority = id; owner = ""; node = []
        }
    }
    func precedes(_ other: Self) -> Bool {
        if tier != other.tier { return tier < other.tier }
        if tier == 0 { return node.lexicographicallyPrecedes(other.node) }
        if tier == 3 { return priority! < other.priority! }
        if tier == 2, priority != other.priority { return priority! < other.priority! }
        // Public placement ordering compares owner key Strings for equality,
        // then compares their exact UTF8 bytes. Preserve that deliberate split.
        return owner == other.owner ? node.lexicographicallyPrecedes(other.node) : owner.utf8.lexicographicallyPrecedes(other.owner.utf8)
    }
}

func structuralPlacementsSorted<Element>(_ values: [Element], by identity: (Element) -> NodePlacementID, descending: Bool = false) -> [Element] {
    values.map { (value: $0, key: PlacementOrderingKey(identity($0))) }
        .sorted { descending ? $1.key.precedes($0.key) : $0.key.precedes($1.key) }.map(\.value)
}
