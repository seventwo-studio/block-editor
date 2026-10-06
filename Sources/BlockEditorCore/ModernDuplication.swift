import Foundation

public struct ModernDuplicateTarget: Codable, Equatable, Sendable {
    public let selection: ModernNodeSelection
    public let boundary: ModernBlockBoundary
    public init(selection: ModernNodeSelection, boundary: ModernBlockBoundary) {
        self.selection = selection; self.boundary = boundary
    }
}

/// The replicated payload is checked against the author's visible source. Only
/// schema IDs change; reference identities and consumer objects remain opaque.
public struct ModernDuplication: Codable, Equatable, Sendable {
    public let target: ModernDuplicateTarget
    public let newBlockIDs: [String]
    public let operations: [Mutation]
}

func modernDuplicationIsOnlyCommand(_ operations: [ModernOperation]) -> Bool {
    var copies = 0
    for operation in operations {
        switch operation {
        case .duplicateBlocks: copies += 1
        case .retainParagraphRole: break
        default: return false
        }
    }
    return copies == 1
}

func validateModernDuplicationShape(_ copy: ModernDuplication, change: ChangeID) throws {
    let selection = copy.target.selection, boundary = copy.target.boundary
    guard !selection.nodes.isEmpty, selection.nodes.count <= 10_000,
          Set(selection.nodes).count == selection.nodes.count,
          copy.newBlockIDs.count == selection.nodes.count, copy.operations.count == selection.nodes.count,
          Set(copy.newBlockIDs).count == copy.newBlockIDs.count,
          copy.newBlockIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 10_000 }) else { throw EditorError.invalidChange }
    try validateObservedFrontier(selection.observed, before: change)
    try validateObservedFrontier(boundary.observed, before: change)
    for node in selection.nodes { try modernStructuralIdentityShape(node) }
    try modernColumnCollectionShape(boundary.collection)
    if let after = boundary.after { try modernColumnPlacementShape(after) }
    var after = boundary.after
    for (index, operation) in copy.operations.enumerated() {
        guard case .insertNode(let value, let identity, let collection, let placement, let anchor) = operation,
              placement == ElementID(change: change, index: index), identity == .inserted(creation: placement, path: []),
              collection == boundary.collection, anchor == after, value["id"] == .string(copy.newBlockIDs[index]) else { throw EditorError.invalidChange }
        try inspectModernPayload(value)
        try validateNode(value, kind: .block, modern: true)
        after = .edit(placement)
    }
}

func modernVisibleValue(_ node: NodeID, in structure: StructuralState, document: ModernDocument) throws -> JSONValue {
    let address = try structure.address(of: node)
    guard let block = document.blocks.first(where: { $0.id == address.blockID }) else { throw EditorError.invalidPath }
    var value = JSONValue.object(block.fields)
    for index in stride(from: 0, to: address.path.count, by: 2) {
        guard let child = value[address.path[index]]?.array?.first(where: { $0["id"] == .string(address.path[index + 1]) }) else { throw EditorError.invalidPath }
        value = child
    }
    return value
}

extension ModernSession {
    public func duplicate(_ target: ModernDuplicateTarget, newBlockIDs: [String]) throws -> ModernStructuralResult {
        try authoringAllowed(command: "duplicate")
        let captured = try validateSelection(target.selection)
        try validateBoundary(target.boundary)
        let id = try nextID()
        let copy = try planModernDuplication(target, newBlockIDs: newBlockIDs, change: id,
            captured: captured, boundaryCaptured: modernCapturedStructure(target.boundary.observed), authored: structure, document: document)
        try validateModernDuplicationShape(copy, change: id)
        for operation in copy.operations {
            if case .insertNode(let value, _, _, _, _) = operation {
                try validateLocalContentPolicy(value)
            }
        }
        let nodes = (0..<newBlockIDs.count).map { NodeID.inserted(creation: ElementID(change: id, index: $0), path: []) }
        endTypingGroup()
        return try performReturning(id, [.duplicateBlocks(copy)], historyBefore: historySelection(target.selection)) { replay, observed in
            let selected = ModernNodeSelection(documentID: self.documentID, epoch: self.epoch, nodes: nodes, observed: observed)
            let focus: ModernFocusIntent
            if let field = try self.editableFields(in: nodes, structure: replay.2).first {
                focus = .text(self.edgePosition(field, projection: replay.0, end: false))
            } else { focus = .nodes(selected) }
            return ModernStructuralResult(focus: focus, selection: .nodes(selected))
        }
    }

    func planModernDuplication(_ target: ModernDuplicateTarget, newBlockIDs: [String], change: ChangeID,
                              captured: StructuralState, boundaryCaptured: StructuralState,
                              authored: StructuralState, document: ModernDocument) throws -> ModernDuplication {
        try validateSelectedNodes(target.selection.nodes, in: captured)
        let selected = Set(target.selection.nodes)
        for node in target.selection.nodes {
            _ = try authored.address(of: node)
            guard authored.nodes[node]?.kind == .block,
                  selected.isDisjoint(with: Set(try authored.descendants(of: node)).subtracting([node])) else { throw EditorError.invalidPath }
        }
        let boundary = target.boundary
        if boundary.collection != .root {
            for node in target.selection.nodes {
                guard try authored.descendants(of: node).allSatisfy({ authored.nodes[$0]?.fields["type"] != .string("columns") }) else { throw EditorError.invalidPath }
            }
        }
        try modernBlockCollection(boundary.collection, structure: boundaryCaptured)
        try modernBlockCollection(boundary.collection, structure: authored)
        if let owner = boundary.collection.owner { _ = try boundaryCaptured.address(of: owner); _ = try authored.address(of: owner) }
        if let after = boundary.after {
            guard let anchor = boundaryCaptured.placements[after], anchor.collection == boundary.collection,
                  try boundaryCaptured.effectivePlacements()[anchor.node]?.id == after,
                  authored.placements[after]?.collection == boundary.collection else { throw EditorError.invalidPath }
            _ = try boundaryCaptured.address(of: anchor.node)
        }
        var reserved = Set(authored.nodes.values.map(\.label))
        guard newBlockIDs.count == target.selection.nodes.count, Set(newBlockIDs).count == newBlockIDs.count,
              newBlockIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 10_000 && !reserved.contains($0) }) else { throw EditorError.invalidChange }
        reserved.formUnion(newBlockIDs)
        var serial = 0
        func fresh(_ value: JSONValue, kind: NodeKind, rootID: String? = nil, depth: Int = 0) throws -> JSONValue {
            guard depth <= 100, var fields = value.object else { throw EditorError.invalidChange }
            if let rootID { fields["id"] = .string(rootID) }
            else {
                var label: String
                repeat { serial += 1; label = "copy-\(change.actor)-\(change.counter)-\(serial)" } while reserved.contains(label)
                reserved.insert(label); fields["id"] = .string(label)
            }
            for (field, childKind) in StructuralState.collectionFields(kind, fields, modern: true).sorted(by: { $0.key < $1.key }) {
                if let children = fields[field]?.array {
                    fields[field] = .array(try children.map { try fresh($0, kind: childKind, depth: depth + 1) })
                }
            }
            return .object(fields)
        }
        var operations: [Mutation] = [], after = boundary.after
        for (index, node) in target.selection.nodes.enumerated() {
            let value = try fresh(modernVisibleValue(node, in: authored, document: document), kind: .block, rootID: newBlockIDs[index])
            // A copied layout remains subject to the same two-column/no-nesting
            // document invariant. Generic insertion cannot author a layout.
            let placement = ElementID(change: change, index: index)
            operations.append(.insertNode(value: value, identity: .inserted(creation: placement, path: []),
                collection: boundary.collection, placement: placement, after: after))
            after = .edit(placement)
        }
        return ModernDuplication(target: target, newBlockIDs: newBlockIDs, operations: operations)
    }
}
