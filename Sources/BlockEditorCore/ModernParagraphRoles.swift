import Foundation

func validateModernRoleShape(_ role: WritingParagraphRole, change: ChangeID) throws {
    func priorNode(_ node: NodeID) throws {
        try modernStructuralIdentityShape(node)
        if case .inserted(let creation, _) = node { guard creation.change < change else { throw EditorError.invalidChange } }
    }
    try priorNode(role.node); try priorNode(role.owner)
    guard role.node != role.owner, !role.exposure.isEmpty, role.exposure.count <= 100_000,
          role.after != .role(owner: role.owner, node: role.node) else { throw EditorError.invalidChange }
    try validateObservedFrontier([role.retirement], before: change)
    try validateObservedFrontier(role.exposure, before: change)
    if let after = role.after {
        try modernColumnPlacementShape(after)
        switch after {
        case .initial(let node): try priorNode(node)
        case .role(let owner, let node): try priorNode(owner); try priorNode(node)
        case .edit(let element): guard element.change < change else { throw EditorError.invalidChange }
        case .columnRoute(let layout, let slot, let node):
            try priorNode(layout); try priorNode(node); guard slot.change < change else { throw EditorError.invalidChange }
        }
    }
}
func modernRetirement(_ change: ModernChange, owner: NodeID, node: NodeID, changes: [ChangeID: ModernChange]) -> Bool {
    switch change.body {
    case .edit:
        guard case .edit(let operations) = modernProjectionChanges([change])[0].body else { return false }
        return writingRetirementOperations(operations, owner: owner, node: node)
    case .setActive(let targets, let enabled):
        return !enabled && targets.contains { target in
            guard let original = changes[target], case .edit(let operations) = modernProjectionChanges([original])[0].body else { return false }
            return writingListCreationOperations(operations, owner: owner)
        }
    }
}
/// Local commands pin only the paragraph roles they use. Packet admission still
/// verifies their original exposure and retirement against the author's cohort.
func modernRoleTargets(_ operations: [ModernOperation]) -> [NodeID] {
    var result: [NodeID] = []
    func anchor(_ placement: NodePlacementID?) { if case .role(_, let node) = placement { result.append(node) } }
    for operation in operations {
        switch operation {
        case .structure(.insertNode(_, _, _, _, let after)): anchor(after)
        case .structure(.moveNode(let node, _, _, let after)): result.append(node); anchor(after)
        case .structure(.deleteNodes(let nodes)): result += nodes
        case .createColumns(let creation): result += creation.nodes; anchor(creation.after)
        case .convertBlock(let node, _, _), .setSemanticDefault(let node, _, _): result.append(node)
        case .schemaConvert(let conversion): result += [conversion.node, conversion.source.node]
        case .splitBlock(let split): result.append(split.source.node); anchor(split.after)
        case .mergeBlocks(let join): result += join.selection.nodes
        case .listStructure(let command): result += command.target.selection.nodes
        default: break
        }
    }
    return result
}
