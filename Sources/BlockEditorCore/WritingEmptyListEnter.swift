import Foundation

/// Lossless empty-item Enter planning. Policy and captured intent are owned by
/// the caller; the retained structure supplies identities and placement order.
func planWritingEmptyListEnter(source: WritingField, id: ChangeID, newItemID: String,
                               structure: StructuralState, projection: WritingProjection) throws -> [WritingOperation] {
    guard source.name == "content", let value = structure.nodes[source.node], value.kind == .item,
          projection.nodes(in: source).allSatisfy({ $0["type"] == .string("text") && ($0["text"]?.string ?? "").isEmpty }) else { throw EditorError.invalidPath }
    let owner = try writingListOwner(of: source.node, structure: structure), placements = try structure.effectivePlacements()
    guard let parent = placements[source.node] else { throw EditorError.invalidPath }
    let siblings = try structure.visibleOrder(in: parent.collection)
    guard let index = siblings.firstIndex(of: source.node) else { throw EditorError.invalidPath }
    if let immediate = parent.collection.owner, structure.nodes[immediate]?.kind == .item {
        guard let outer = placements[immediate],
              !(try structure.visibleOrder(in: outer.collection)).contains(where: { $0 != source.node && structure.nodes[$0]?.label == value.label }) else { throw EditorError.invalidChange }
        return [.structure(.moveNode(identity: source.node, collection: outer.collection,
            placement: ElementID(change: id, index: 0), after: outer.id))]
    }
    if siblings.count == 1 {
        return [.schemaConvert(try planWritingSchemaConversion(source: source, target: WritingBlockTarget(type: "paragraph"),
            id: id, structure: structure, projection: projection))]
    }
    guard siblings.count > 1, let wrapper = placements[owner], !value.fields.keys.contains("type"),
          !structure.placements.values.contains(where: {
              $0.collection == wrapper.collection && $0.node != owner && $0.node != source.node && structure.nodes[$0.node]?.label == value.label
          }) else { throw EditorError.invalidChange }
    let role = NodePlacementID.role(owner: owner, node: source.node)
    var operations: [WritingOperation] = [.exitListItem(node: source.node, owner: owner, source: parent.id, after: wrapper.id)]
    if index == 0 {
        operations.append(.structure(.moveNode(identity: owner, collection: wrapper.collection,
            placement: ElementID(change: id, index: 0), after: role)))
    } else if index + 1 < siblings.count {
        guard !newItemID.isEmpty, newItemID != value.label,
              !structure.placements.values.contains(where: { $0.collection == wrapper.collection && structure.nodes[$0.node]?.label == newItemID }) else { throw EditorError.invalidChange }
        let creation = ElementID(change: id, index: 0), tail = NodeID.inserted(creation: creation, path: [])
        var fields = structure.nodes[owner]!.fields; fields["id"] = .string(newItemID); fields["items"] = .array([])
        operations.append(.structure(.insertNode(value: .object(fields), identity: tail,
            collection: wrapper.collection, placement: creation, after: role)))
        var after: NodePlacementID?
        for (offset, item) in siblings[(index + 1)...].enumerated() {
            let placement = ElementID(change: id, index: offset + 1)
            operations.append(.structure(.moveNode(identity: item, collection: NodeCollection(owner: tail, field: "items"), placement: placement, after: after)))
            after = .edit(placement)
        }
    }
    return operations
}
