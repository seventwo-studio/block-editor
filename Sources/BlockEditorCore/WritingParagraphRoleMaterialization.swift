import Foundation

/// Materialize a session-proven retired paragraph role without copying its atoms.
/// Modern column routing can supply the complete retained placement shape.
func applyWritingParagraphRole(node: NodeID, owner: NodeID, after: NodePlacementID?, enabled: Bool,
                               raw: inout Materialized, placementShape: StructuralState? = nil) throws {
    guard var value = raw.structure?.nodes[node] else { throw EditorError.invalidChange }
    guard value.kind != .item || value.fields["type"] == nil || value.fields["type"] == .string("paragraph") else {
        throw EditorError.invalidDocument("Peer item role metadata collision")
    }
    let shape = placementShape ?? raw.structure!
    let selected = try shape.effectivePlacements()
    guard let root = selected[owner] else { throw EditorError.invalidDocument("Retired role owner is unavailable") }
    let id = NodePlacementID.role(owner: owner, node: node)
    let priority = raw.structure?.placements[id]?.rolePriority
    let origin = raw.structure?.placements[id]?.roleOrigin
    guard after != id else { throw EditorError.invalidChange }
    if let after = after {
        guard let anchor = shape.placements[after] else { throw WritingProjectionError.missingAtom }
        guard anchor.collection == root.collection else { throw EditorError.invalidDocument("Retained role anchor moved between collections") }
    }
    if let existing = raw.structure?.placements[id], existing.collection != root.collection {
        throw EditorError.invalidDocument("Retired role owner moved between collections")
    }
    if value.kind == .item { value.kind = .block; value.fields["type"] = .string("paragraph") }
    raw.structure?.nodes[node] = value
    if enabled {
        raw.structure?.touched.insert(node)
        for (key, old) in raw.structure!.placements where old.node == node && old.active {
            raw.structure?.placements[key] = StructuralState.Placement(id: old.id, after: old.after,
                node: old.node, collection: old.collection, active: false, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
        }
    }
    if enabled || raw.structure?.placements[id] == nil {
        raw.structure?.placements[id] = StructuralState.Placement(id: id, after: after,
            node: node, collection: root.collection, active: enabled, rolePriority: priority, roleOrigin: origin)
    }
}

func applyWritingListExit(node: NodeID, owner: NodeID, source: NodePlacementID, after: NodePlacementID?,
                          change: ChangeID, enabled: Bool, raw: inout Materialized,
                          placementShape: StructuralState? = nil) throws {
    guard var item = raw.structure?.nodes[node] else { throw EditorError.invalidChange }
    guard item.kind != .item || item.fields["type"] == nil else { throw EditorError.invalidDocument("Exited item type metadata collision") }
    let shape = placementShape ?? raw.structure!, placements = try shape.effectivePlacements()
    guard let root = placements[owner] else { throw EditorError.invalidDocument("Exited item owner unavailable") }
    let placement = NodePlacementID.role(owner: owner, node: node)
    guard after != placement else { throw EditorError.invalidChange }
    if let after {
        guard let anchor = shape.placements[after] else { throw WritingProjectionError.missingAtom }
        guard anchor.collection == root.collection else { throw EditorError.invalidChange }
    }
    if item.kind == .item { item.kind = .block; item.fields["type"] = .string("paragraph") }
    raw.structure?.nodes[node] = item
    if enabled {
        raw.structure?.touched.insert(node)
        for (key, old) in raw.structure!.placements where old.node == node && old.active {
            raw.structure?.placements[key] = StructuralState.Placement(id: old.id, after: old.after,
                node: old.node, collection: old.collection, active: false, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
        }
    }
    if enabled || raw.structure?.placements[placement] == nil {
        raw.structure?.placements[placement] = StructuralState.Placement(id: placement, after: after,
            node: node, collection: root.collection, active: enabled,
            rolePriority: ElementID(change: change, index: 0), roleOrigin: source)
    }
}
