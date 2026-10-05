import Foundation

public struct ModernCreateColumnsTarget: Codable, Equatable, Sendable {
    public let selection: ModernNodeSelection?
    public let boundary: ModernBlockBoundary?
    public let caret: WritingPosition?
    /// Exactly one of a contiguous selection or an insertion boundary is required.
    public init(selection: ModernNodeSelection? = nil, boundary: ModernBlockBoundary? = nil, caret: WritingPosition? = nil) {
        self.selection = selection; self.boundary = boundary; self.caret = caret
    }
}
public struct ModernColumnTarget: Codable, Equatable, Sendable {
    public let layout: NodeID
    public let caret: WritingPosition?
    public init(layout: NodeID, caret: WritingPosition? = nil) { self.layout = layout; self.caret = caret }
}

extension ModernSession {
    public func createColumns(_ target: ModernCreateColumnsTarget, layout: JSONValue) throws -> ModernStructuralResult {
        try authoringAllowed(command: "createColumns")
        guard (target.selection == nil) != (target.boundary == nil) else { throw EditorError.invalidPath }
        let nodes = target.selection?.nodes ?? [], placements = try structure.effectivePlacements()
        let collection: NodeCollection, after: NodePlacementID?
        if let selected = target.selection {
            _ = try validateSelection(selected)
            guard let parent = placements[nodes[0]]?.collection else { throw EditorError.invalidPath }
            collection = parent
            let order = try structure.visibleOrder(in: parent)
            guard let first = order.firstIndex(of: nodes[0]) else { throw EditorError.invalidPath }
            after = first == 0 ? nil : placements[order[first - 1]]?.id
        } else {
            let boundary = target.boundary!
            try validateBoundary(boundary, columns: true)
            collection = boundary.collection; after = boundary.after
        }
        if let caret = target.caret {
            _ = try resolve(caret)
            guard try nodes.flatMap({ try structure.descendants(of: $0) }).contains(caret.field.node) else { throw EditorError.invalidPath }
        }
        let id = try nextID(), placement = ElementID(change: id, index: 0)
        let value = ModernColumnCreation(layout: layout, identity: .inserted(creation: placement, path: []), collection: collection,
            placement: placement, after: after, nodes: nodes, sources: try nodes.map { try requiredPlacement($0, in: placements) })
        try validateModernColumnCreationShape(value, change: id)
        try validateModernColumnCreation(value, in: structure)
        endTypingGroup()
        return try performReturning(id, [.createColumns(value)]) { _, observed in
            self.moveResult([value.identity], caret: target.caret, observed: observed)
        }
    }
    public func removeColumns(_ target: ModernColumnTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "removeColumns")
        _ = try structure.address(of: target.layout)
        let columns = try modernColumnIDs(target.layout, in: structure)
        let nodes = try columns.flatMap { try structure.visibleOrder(in: NodeCollection(owner: $0, field: "children")) }
        if let caret = target.caret {
            _ = try resolve(caret)
            guard try nodes.flatMap({ try structure.descendants(of: $0) }).contains(caret.field.node) else { throw EditorError.invalidPath }
        }
        let source = try requiredPlacement(target.layout, in: structure.effectivePlacements()), collection = structure.placements[source]!.collection
        let boundaryObserved = modernObserved // Prove this anchor while its layout is still live.
        endTypingGroup()
        return try performReturning(nextID(), [.removeColumns(layout: target.layout, source: source)]) { _, observed in
            if !nodes.isEmpty { return self.moveResult(nodes, caret: target.caret, observed: observed) }
            return ModernStructuralResult(focus: .insertion(ModernBlockBoundary(documentID: self.documentID, epoch: self.epoch,
                collection: collection, after: source, observed: boundaryObserved)), selection: nil)
        }
    }
    public func resizeColumns(_ target: ModernColumnTarget, splitBasisPoints: Int) throws -> ModernStructuralResult {
        try authoringAllowed(command: "resizeColumns")
        _ = try structure.address(of: target.layout); _ = try modernColumnIDs(target.layout, in: structure)
        guard (1000...9000).contains(splitBasisPoints) else { throw EditorError.invalidChange }
        if let caret = target.caret {
            _ = try resolve(caret)
            guard try structure.descendants(of: target.layout).contains(caret.field.node) else { throw EditorError.invalidPath }
        }
        let outcome = { (_: (WritingProjection, ModernDocument, StructuralState), observed: [ChangeID]) in
            self.moveResult([target.layout], caret: target.caret, observed: observed)
        }
        if structure.nodes[target.layout]?.fields["splitBasisPoints"] == .number(Double(splitBasisPoints)) {
            return outcome(modernCurrentReplay, modernObserved)
        }
        endTypingGroup()
        return try performReturning(nextID(), [.resizeColumns(layout: target.layout, splitBasisPoints: splitBasisPoints)], result: outcome)
    }
    private func requiredPlacement(_ node: NodeID, in placements: [NodeID: StructuralState.Placement]) throws -> NodePlacementID {
        guard let placement = placements[node] else { throw EditorError.invalidPath }; return placement.id
    }
}
