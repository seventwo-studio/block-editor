import Foundation

/// List-only hierarchy planning shared by legacy single-item commands and modern
/// checked multi-item commands. Placement and text origins remain unchanged.
func planWritingListHierarchy(_ nodes: [NodeID], outdent: Bool, change: ChangeID, structure: StructuralState) throws -> [Mutation] {
    guard !nodes.isEmpty, nodes.count <= 10_000, Set(nodes).count == nodes.count else { throw EditorError.invalidPath }
    let placements = try structure.effectivePlacements()
    guard let first = placements[nodes[0]], try structure.kind(in: first.collection) == .item else { throw EditorError.invalidPath }
    for node in nodes {
        _ = try structure.address(of: node)
        guard structure.nodes[node]?.kind == .item, placements[node]?.collection == first.collection else { throw EditorError.invalidPath }
    }
    let siblings = try structure.visibleOrder(in: first.collection)
    guard let index = siblings.firstIndex(of: nodes[0]), index + nodes.count <= siblings.count,
          Array(siblings[index..<(index + nodes.count)]) == nodes else { throw EditorError.invalidPath }
    let destination: NodeCollection
    var after: NodePlacementID?
    if outdent {
        guard let owner = first.collection.owner, structure.nodes[owner]?.kind == .item,
              first.collection.field == "children", let parent = placements[owner] else { throw EditorError.invalidPath }
        destination = parent.collection; after = parent.id
    } else {
        guard index > 0 else { throw EditorError.invalidPath }
        let owner = siblings[index - 1]
        destination = NodeCollection(owner: owner, field: "children")
        after = try structure.visibleOrder(in: destination).last.flatMap { placements[$0]?.id }
    }
    return try planWritingListMove(nodes, into: destination, after: after, change: change, structure: structure)
}

func planWritingListMove(_ nodes: [NodeID], into destination: NodeCollection, after anchor: NodePlacementID?,
                         change: ChangeID, structure: StructuralState) throws -> [Mutation] {
    guard !nodes.isEmpty, nodes.count <= 10_000, Set(nodes).count == nodes.count,
          try structure.kind(in: destination) == .item, let owner = destination.owner else { throw EditorError.invalidPath }
    let placements = try structure.effectivePlacements()
    _ = try structure.address(of: owner)
    for node in nodes { _ = try structure.address(of: node); guard structure.nodes[node]?.kind == .item else { throw EditorError.invalidPath } }
    if let anchor {
        guard let placement = structure.placements[anchor], placement.collection == destination,
              !nodes.contains(placement.node) else { throw EditorError.invalidPath }
    }
    let labels = Set(nodes.compactMap { structure.nodes[$0]?.label })
    guard labels.count == nodes.count,
          !(try structure.visibleOrder(in: destination)).contains(where: { !nodes.contains($0) && labels.contains(structure.nodes[$0]!.label) }) else { throw EditorError.invalidDocument("Sibling ID already exists") }
    for node in nodes { guard !(try structure.descendants(of: node)).contains(owner) else { throw EditorError.invalidPath } }
    let order = try structure.visibleOrder(in: destination)
    if let index = order.firstIndex(of: nodes[0]), index + nodes.count <= order.count,
       Array(order[index..<(index+nodes.count)]) == nodes, (index == 0 ? nil : placements[order[index-1]]?.id) == anchor { return [] }
    var after = anchor
    return nodes.enumerated().map { index, node in
        let placement = ElementID(change: change, index: index)
        let mutation = Mutation.moveNode(identity: node, collection: destination, placement: placement, after: after)
        after = .edit(placement); return mutation
    }
}
