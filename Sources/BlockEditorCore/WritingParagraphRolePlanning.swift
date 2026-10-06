import Foundation

func writingRetirementOperations(_ operations: [WritingOperation], owner: NodeID, node: NodeID?) -> Bool {
    operations.contains {
        if case .schemaConvert(let conversion) = $0 { return conversion.node == owner && conversion.type != "list" && conversion.source.node != owner }
        if case .exitListItem(let exited, let wrapper, _, _) = $0 { return wrapper == owner && exited == node }
        return false
    }
}
func writingListCreationOperations(_ operations: [WritingOperation], owner: NodeID) -> Bool {
    operations.contains { if case .schemaConvert(let conversion) = $0 { return conversion.node == owner && conversion.type == "list" }; return false }
}

/// Emit predecessor roles before their dependents without a recursive walk.
func planWritingParagraphRoles(for identities: [NodeID], structure: StructuralState, changes: [WritingChange], frontier: [ChangeID],
                               isRetirement: (ChangeID, NodeID, NodeID) -> Bool) throws -> [WritingOperation] {
    let selected = try structure.effectivePlacements(), newest = changes.sorted { $1.id < $0.id }
    var visiting = Set<NodeID>(), done = Set<NodeID>(), result: [WritingOperation] = []
    var prior: [NodePlacementID: WritingParagraphRole] = [:]
    for change in newest {
        guard case .edit(let operations) = change.body else { continue }
        for operation in operations {
            if case .retainParagraphRole(let role) = operation {
                let key = NodePlacementID.role(owner: role.owner, node: role.node)
                prior[key] = prior[key] ?? role
            }
        }
    }
    for identity in Set(identities).sorted(by: { $0.key < $1.key }) {
        var pending: [(NodeID, WritingParagraphRole?)] = [(identity, nil)]
        while let (node, planned) = pending.popLast() {
            if let planned {
                result.append(.retainParagraphRole(planned)); visiting.remove(node); done.insert(node); continue
            }
            guard !done.contains(node), let placement = selected[node], case .role(let owner, let roleNode) = placement.id else { continue }
            guard visiting.insert(node).inserted, roleNode == node,
                  let proof = newest.first(where: { isRetirement($0.id, owner, node) }) else { throw EditorError.invalidChange }
            let previous = prior[placement.id]
            let role = WritingParagraphRole(node: node, owner: owner, retirement: previous?.retirement ?? proof.id,
                exposure: previous?.exposure ?? frontier, after: placement.after)
            pending.append((node, role))
            if let after = placement.after, case .role(_, let predecessor) = after, selected[predecessor]?.id == after { pending.append((predecessor, nil)) }
        }
    }
    return result
}
