import Foundation

/// A retired collection keeps its admitted item kind for historical mutations.
/// The temporary validation shape never replaces the visible owner's schema.
func writingRetainedCollectionShape(_ original: Materialized, mutations: [Mutation],
                                    collectionBirths: [NodeCollection: NodeKind], retainedRoles: Set<NodeID> = [],
                                    inactive: Bool = false) -> Materialized {
    var copy = original
    for mutation in mutations {
        let collection: NodeCollection
        switch mutation {
        case .insertNode(_, _, let destination, _, _), .moveNode(_, let destination, _, _): collection = destination
        default: continue
        }
        if inactive, case .moveNode(let identity, _, _, _) = mutation, retainedRoles.contains(identity),
           (try? copy.structure?.kind(in: collection)) == .block, var value = copy.structure?.nodes[identity], value.kind == .item {
            value.kind = .block; value.fields["type"] = .string("paragraph"); copy.structure?.nodes[identity] = value
        }
        if (try? copy.structure?.kind(in: collection)) == nil,
           collection.field == "children",
           let owner = collection.owner, var value = copy.structure?.nodes[owner], value.birthKind == .item {
            value.kind = .item; copy.structure?.nodes[owner] = value
        }
        if (try? copy.structure?.kind(in: collection)) == nil,
           collectionBirths[collection] == .item, collection.field == "items",
           let owner = collection.owner, var value = copy.structure?.nodes[owner], value.kind == .block {
            value.fields["type"] = .string("list"); value.fields["style"] = .string("unordered")
            value.collections.insert("items"); copy.structure?.nodes[owner] = value
        }
    }
    return copy
}
