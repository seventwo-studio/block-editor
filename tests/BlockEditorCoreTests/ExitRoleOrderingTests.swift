@testable import BlockEditorCore
import Testing

@Test func exitRolesWithRankedAndFallbackOriginsKeepOneStableOrder() throws {
    let owner = NodeID.baseline(blockID: "owner", path: [])
    let nodes = ["a", "m", "z"].map { NodeID.baseline(blockID: $0, path: []) }
    let source = NodeCollection(owner: owner, field: "items")
    let priority = ElementID(change: ChangeID(counter: 1, actor: "exit"), index: 0)
    let roles = nodes.map { NodePlacementID.role(owner: owner, node: $0) }
    let baseline = [NodePlacementID.initial(nodes[0]), NodePlacementID.initial(nodes[2])]
    // Two ranked exits and an unranked retained peer can share an owner and
    // predecessor. A conditional rank/raw tie-break used to form a sort cycle.
    for insertion in [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]] {
        var state = StructuralState()
        state.placements[baseline[0]] = .init(id: baseline[0], after: nil, node: nodes[0], collection: source, active: false)
        state.placements[baseline[1]] = .init(id: baseline[1], after: baseline[0], node: nodes[2], collection: source, active: false)
        var selected: [NodeID: StructuralState.Placement] = [:]
        for index in insertion {
            let origin = index == 0 ? baseline[0] : index == 2 ? baseline[1] : nil
            let placement = StructuralState.Placement(id: roles[index], after: nil, node: nodes[index], collection: .root,
                active: true, rolePriority: priority, roleOrigin: origin)
            state.placements[roles[index]] = placement; selected[nodes[index]] = placement
        }
        #expect(state.order(in: .root, selected: selected) == [nodes[0], nodes[2], nodes[1]])
    }
}
