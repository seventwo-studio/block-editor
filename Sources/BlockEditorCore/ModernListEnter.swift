import Foundation

/// A checked empty-item transition, derived again from the captured and authored
/// cohorts. Its embedded operations are not a general structural mutation API.
public struct ModernListEnter: Codable, Equatable, Sendable {
    public let range: ModernTextRange
    public let newBlockID: String
    public let operations: [WritingOperation]
}
func validateModernEnterShape(_ enter: ModernListEnter, change: ChangeID) throws {
    guard enter.range.start.field == enter.range.end.field, ["content", "code"].contains(enter.range.start.field.name),
          enter.range.observed.count <= 100_000, !enter.operations.isEmpty, enter.operations.count <= 100_000 else { throw EditorError.invalidChange }
    try modernStructuralIdentityShape(enter.range.start.field.node)
    try validateObservedFrontier(enter.range.observed, before: change)
    for operation in enter.operations {
        switch operation {
        case .schemaConvert(let conversion):
            try inspectModernPayload(.object(conversion.attributes)); try inspectModernPayload(.object(conversion.preservedItemFields))
            try validateModernSchemaShape(conversion, change: change)
            guard enter.operations.count == 1, conversion.type == "paragraph", conversion.source.node != conversion.node else { throw EditorError.invalidChange }
        case .exitListItem(let node, let owner, let source, let after):
            try modernStructuralIdentityShape(node); try modernStructuralIdentityShape(owner)
            guard node != owner else { throw EditorError.invalidChange }
            try modernColumnPlacementShape(source)
            if let after { try modernColumnPlacementShape(after) }
        case .structure(let mutation):
            let identity: NodeID, collection: NodeCollection, placement: ElementID, after: NodePlacementID?
            switch mutation {
            case .insertNode(let value, let node, let target, let element, let anchor):
                try inspectModernPayload(value); try validateModernAuthoredBlock(value)
                guard value["type"] == .string("list"), value["items"] == .array([]), node == .inserted(creation: element, path: []) else { throw EditorError.invalidChange }
                (identity, collection, placement, after) = (node, target, element, anchor)
            case .moveNode(let node, let target, let element, let anchor): (identity, collection, placement, after) = (node, target, element, anchor)
            default: throw EditorError.invalidChange
            }
            try modernStructuralIdentityShape(identity)
            if let owner = collection.owner { try modernStructuralIdentityShape(owner) }
            guard ["blocks", "items", "children"].contains(collection.field), placement.change == change else { throw EditorError.invalidChange }
            try modernStructuralIdentityShape(.inserted(creation: placement, path: []))
            if let after { try modernColumnPlacementShape(after) }
        default: throw EditorError.invalidChange
        }
    }
}
func planModernEmptyEnter(range: ModernTextRange, newBlockID: String, change: ChangeID,
                          captured: (WritingProjection, StructuralState), authored: (WritingProjection, StructuralState)) throws -> ModernListEnter {
    guard range.start.field == range.end.field else { throw EditorError.invalidRange }
    let first = try resolveWritingPosition(range.start, projection: captured.0, structure: captured.1) { _ in nil }
    let last = try resolveWritingPosition(range.end, projection: captured.0, structure: captured.1) { _ in nil }
    guard first.address == last.address, first.offset == last.offset else { throw EditorError.invalidRange }
    let source = try range.start.anchor.map { try authored.0.field(of: $0) } ?? authored.0.destination(of: range.start.field)
    let end = try range.end.anchor.map { try authored.0.field(of: $0) } ?? authored.0.destination(of: range.end.field)
    guard source == end else { throw EditorError.invalidRange }
    _ = try authored.1.address(of: source.node)
    let operations = try planWritingEmptyListEnter(source: source, id: change, newItemID: newBlockID, structure: authored.1, projection: authored.0)
    return ModernListEnter(range: range, newBlockID: newBlockID, operations: operations)
}
func applyModernEmptyEnter(_ enter: ModernListEnter, change: ChangeID, enabled: Bool, raw: inout Materialized,
                           births: inout [WritingField: WritingFieldBirth], collectionBirths: inout [NodeCollection: NodeKind],
                           introduced: inout Set<ElementID>, placementShape: StructuralState) throws -> Set<NodeID> {
    var roles = Set<NodeID>()
    for operation in enter.operations {
        switch operation {
        case .schemaConvert(let conversion):
            try applyWritingSchemaConversion(conversion, change: change, enabled: enabled, raw: &raw,
                births: &births, collectionBirths: &collectionBirths, introduced: &introduced, modern: true)
        case .exitListItem(let node, let owner, let source, let after):
            guard raw.structure!.nodes[owner]?.kind == .block, let item = raw.structure!.nodes[node], item.birthKind == .item,
                  births[WritingField(node: node, name: "content")] != nil,
                  let original = raw.structure!.placements[source], original.node == node,
                  original.collection == NodeCollection(owner: owner, field: "items"),
                  item.kind == .item || raw.structure!.placements[.role(owner: owner, node: node)] != nil else { throw EditorError.invalidChange }
            roles.insert(node)
            var shape = placementShape
            if let after, let anchor = shape.placements[after], anchor.node == owner,
               try shape.effectivePlacements()[owner]?.collection != anchor.collection {
                if enabled { throw EditorError.invalidDocument("Exited item owner moved between collections") }
                // An inactive exit retains its original placement proof even if
                // Undo has restored the owner to a former column. This temporary
                // view never moves the visible owner or reactivates the exit.
                for (key, old) in shape.placements where old.node == owner {
                    shape.placements[key] = StructuralState.Placement(id: old.id, after: old.after, node: old.node,
                        collection: old.collection, active: key == after, rolePriority: old.rolePriority, roleOrigin: old.roleOrigin)
                }
                shape.touched.insert(owner)
            }
            try applyWritingListExit(node: node, owner: owner, source: source, after: after, change: change, enabled: enabled,
                raw: &raw, placementShape: shape)
        case .structure(let mutation):
            switch mutation {
            case .insertNode(_, _, _, let element, _), .moveNode(_, _, let element, _):
                guard introduced.insert(element).inserted else { throw EditorError.invalidChange }
            default: throw EditorError.invalidChange
            }
            let original = raw.structure!.nodes
            let validating = writingRetainedCollectionShape(raw, mutations: [mutation], collectionBirths: collectionBirths, retainedRoles: roles, inactive: !enabled)
            let adjusted = validating.structure!.nodes.filter { original[$0.key]?.fields != $0.value.fields || original[$0.key]?.kind != $0.value.kind }
            raw.structure = validating.structure
            try apply([mutation], enabled: enabled, to: &raw)
            for owner in adjusted.keys { raw.structure!.nodes[owner] = original[owner] }
            retainModernFieldBirths(in: raw.structure!, births: &births)
            collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
        default: throw EditorError.invalidChange
        }
    }
    return roles
}

func modernEnterTransitions(_ enter: ModernListEnter) -> [NodeID] {
    enter.operations.compactMap {
        if case .schemaConvert(let conversion) = $0 { return conversion.node }
        if case .exitListItem(let node, _, _, _) = $0 { return node }
        return nil
    }
}
