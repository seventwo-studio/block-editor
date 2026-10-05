import Foundation

/// Captured placement, not a display offset or a lookup at execution time.
/// Tombstoned/moved anchors remain ordering boundaries in their original collection.
public struct ModernBlockBoundary: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let collection: NodeCollection
    public let after: NodePlacementID?
    public let observed: [ChangeID]
    public init(documentID: String, epoch: String, collection: NodeCollection, after: NodePlacementID?, observed: [ChangeID]) {
        self.documentID = documentID; self.epoch = epoch; self.collection = collection; self.after = after; self.observed = observed
    }
}
public struct ModernNodeSelection: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let nodes: [NodeID]
    public let observed: [ChangeID]
    public init(documentID: String, epoch: String, nodes: [NodeID], observed: [ChangeID]) {
        self.documentID = documentID; self.epoch = epoch; self.nodes = nodes; self.observed = observed
    }
}
public struct ModernMoveTarget: Codable, Equatable, Sendable {
    public let selection: ModernNodeSelection
    public let boundary: ModernBlockBoundary
    public let caret: WritingPosition?
    public init(selection: ModernNodeSelection, boundary: ModernBlockBoundary, caret: WritingPosition? = nil) {
        self.selection = selection; self.boundary = boundary; self.caret = caret
    }
}
public struct ModernDeleteTarget: Codable, Equatable, Sendable {
    public let nodes: ModernNodeSelection?
    public let ranges: [ModernTextRange]
    public init(nodes: ModernNodeSelection? = nil, ranges: [ModernTextRange] = []) { self.nodes = nodes; self.ranges = ranges }
}
/// Canonical local result intents. They do not instruct peers to change focus.
/// Indirect payloads keep large anchored ranges out of every command/replay
/// stack frame; synthesized Codable preserves the same wire discriminants.
public indirect enum ModernFocusIntent: Codable, Equatable, Sendable {
    case text(WritingPosition)
    case nodes(ModernNodeSelection)
    case insertion(ModernBlockBoundary)
}
public indirect enum ModernSelectionIntent: Codable, Equatable, Sendable {
    case text(WritingTextRange)
    case nodes(ModernNodeSelection)
    case mixed(ModernDeleteTarget)
}
public struct ModernStructuralResult: Codable, Equatable, Sendable {
    public let focus: ModernFocusIntent
    public let selection: ModernSelectionIntent?
}

extension ModernSession {
    public func captureBoundary(in collection: NodeCollection = .root, after identity: NodeID? = nil) throws -> ModernBlockBoundary {
        guard try structure.kind(in: collection) == .block else { throw EditorError.invalidPath }
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        var after: NodePlacementID?
        if let identity {
            guard (try structure.visibleOrder(in: collection)).contains(identity),
                  let placement = try structure.effectivePlacements()[identity] else { throw EditorError.invalidPath }
            after = placement.id
        }
        return ModernBlockBoundary(documentID: documentID, epoch: epoch, collection: collection, after: after, observed: modernObserved)
    }
    public func captureNodes(_ nodes: [NodeID]) throws -> ModernNodeSelection {
        try validateSelectedNodes(nodes, in: structure)
        return ModernNodeSelection(documentID: documentID, epoch: epoch, nodes: nodes, observed: modernObserved)
    }

    /// Result planning runs against the validated candidate before publication.
    /// A failed target or focus outcome cannot leave a partially accepted edit.
    public func insertBlock(_ block: Block, at boundary: ModernBlockBoundary) throws -> ModernStructuralResult {
        try authoringAllowed(command: "insertBlock"); endTypingGroup()
        try validateBoundary(boundary)
        try validateModernAuthoredBlock(.object(block.fields))
        guard !(try structure.visibleOrder(in: boundary.collection)).contains(where: { structure.nodes[$0]?.label == block.id }) else { throw EditorError.invalidChange }
        let id = try nextID(), placement = ElementID(change: id, index: 0), identity = NodeID.inserted(creation: placement, path: [])
        return try performReturning(id, [.structure(.insertNode(value: .object(block.fields), identity: identity, collection: boundary.collection,
            placement: placement, after: boundary.after))], historyBefore: historySelection(boundary)) { replay, observed in
            let selection = ModernNodeSelection(documentID: self.documentID, epoch: self.epoch, nodes: [identity], observed: observed)
            if let field = try self.editableFields(in: [identity], structure: replay.2).first {
                let position = self.edgePosition(field, projection: replay.0, end: false)
                return ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
            }
            return ModernStructuralResult(focus: .nodes(selection), selection: .nodes(selection))
        }
    }

    public func move(_ target: ModernMoveTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "move"); endTypingGroup()
        _ = try validateSelection(target.selection)
        try validateBoundary(target.boundary)
        let nodes = target.selection.nodes, collection = target.boundary.collection
        let placements = try structure.effectivePlacements()
        if let anchor = target.boundary.after, let anchored = structure.placements[anchor]?.node, nodes.contains(anchored) { throw EditorError.invalidPath }
        for identity in nodes {
            if let owner = collection.owner, try structure.descendants(of: identity).contains(owner) { throw EditorError.invalidPath }
        }
        let labels = nodes.compactMap { structure.nodes[$0]?.label }
        guard Set(labels).count == nodes.count,
              !(try structure.visibleOrder(in: collection)).contains(where: { !nodes.contains($0) && labels.contains(structure.nodes[$0]!.label) }) else { throw EditorError.invalidChange }
        if let caret = target.caret {
            _ = try resolve(caret)
            let selected = try Set(nodes.flatMap { try structure.descendants(of: $0) })
            guard selected.contains(caret.field.node) else { throw EditorError.invalidPath }
        }
        // A captured placement must match the actual current boundary before
        // treating an already contiguous selection as a no-op.
        let siblings = try structure.visibleOrder(in: collection)
        if let first = siblings.firstIndex(of: nodes[0]), first + nodes.count <= siblings.count,
           Array(siblings[first..<(first + nodes.count)]) == nodes,
           (first == 0 ? nil : placements[siblings[first - 1]]?.id) == target.boundary.after {
            return moveResult(nodes, caret: target.caret, observed: modernObserved)
        }
        let id = try nextID(); var after = target.boundary.after, operations: [ModernOperation] = []
        for (index, identity) in nodes.enumerated() {
            let placement = ElementID(change: id, index: index)
            operations.append(.structure(.moveNode(identity: identity, collection: collection, placement: placement, after: after)))
            after = .edit(placement)
        }
        return try performReturning(id, operations, historyBefore: historySelection(target.selection, caret: target.caret)) { _, observed in self.moveResult(nodes, caret: target.caret, observed: observed) }
    }

    public func delete(_ target: ModernDeleteTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "delete"); endTypingGroup()
        guard target.ranges.count <= 10_000, target.nodes != nil || !target.ranges.isEmpty else { throw EditorError.invalidPath }
        var removed = Set<NodeID>()
        if let nodes = target.nodes {
            let captured = try validateSelection(nodes)
            for identity in nodes.nodes { removed.formUnion(try captured.descendants(of: identity)) }
        }
        var keys = Set<WritingAtomKey>(), caret: WritingPosition?
        for range in target.ranges {
            guard range.start.field != titleField, range.end.field != titleField else { throw EditorError.invalidPath }
            let selected = try modernCapturedSelection(range)
            if caret == nil { caret = selected.position }
            if !removed.contains(range.start.field.node) { keys.formUnion(selected.keys) }
        }
        let logical = try logicalNodes(structure), removedIndices = logical.indices.filter { removed.contains(logical[$0]) }
        let first = removedIndices.first ?? caret.flatMap { logical.firstIndex(of: $0.field.node) } ?? 0
        let following = Array(logical.dropFirst(first).filter { !removed.contains($0) })
        let preceding = Array(logical.prefix(first).reversed().filter { !removed.contains($0) })
        var operations: [ModernOperation] = []
        if !removed.isEmpty { operations.append(.structure(.deleteNodes(identities: removed.sorted { $0.key < $1.key }))) }
        if !keys.isEmpty { operations.append(.text(.delete(keys: keys.sorted()))) }
        func result(_ replay: (WritingProjection, ModernDocument, StructuralState), _ observed: [ChangeID]) throws -> ModernStructuralResult {
            if let caret, !removed.contains(caret.field.node), (try? replay.2.address(of: caret.field.node)) != nil {
                return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
            }
            for node in following where (try? replay.2.address(of: node)) != nil {
                if let field = try self.editableFields(in: [node], structure: replay.2).first {
                    let position = self.edgePosition(field, projection: replay.0, end: false)
                    return ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
                }
            }
            for node in preceding where (try? replay.2.address(of: node)) != nil {
                if let field = try self.editableFields(in: [node], structure: replay.2).last {
                    let position = self.edgePosition(field, projection: replay.0, end: true)
                    return ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
                }
            }
            if replay.1.blocks.isEmpty {
                return ModernStructuralResult(focus: .insertion(ModernBlockBoundary(documentID: self.documentID, epoch: self.epoch,
                    collection: .root, after: nil, observed: observed)), selection: nil)
            }
            let position = self.edgePosition(self.titleField, projection: replay.0, end: true)
            return ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
        }
        if operations.isEmpty { return try result(modernCurrentReplay, modernObserved) }
        return try performReturning(nextID(), operations, historyBefore: historySelection(target), result: result)
    }

    func validateBoundary(_ boundary: ModernBlockBoundary, columns: Bool = false) throws {
        try validateTargetScope(boundary.documentID, boundary.epoch)
        let captured = try modernCapturedStructure(boundary.observed)
        if columns {
            try modernColumnCollection(boundary.collection, structure: captured)
            try modernColumnCollection(boundary.collection, structure: structure)
        } else {
            try modernBlockCollection(boundary.collection, structure: captured)
            try modernBlockCollection(boundary.collection, structure: structure)
        }
        if let owner = boundary.collection.owner { _ = try captured.address(of: owner); _ = try structure.address(of: owner) }
        if let after = boundary.after {
            guard captured.placements[after]?.collection == boundary.collection,
                  structure.placements[after]?.collection == boundary.collection else { throw EditorError.invalidPath }
            // The anchor must have been selected/live when captured, while its
            // immutable placement may subsequently survive a deletion or move.
            guard let identity = captured.placements[after]?.node,
                  try captured.effectivePlacements()[identity]?.id == after else { throw EditorError.invalidPath }
            _ = try captured.address(of: identity)
        }
    }
    func validateSelection(_ selection: ModernNodeSelection) throws -> StructuralState {
        try validateTargetScope(selection.documentID, selection.epoch)
        let captured = try modernCapturedStructure(selection.observed)
        try validateSelectedNodes(selection.nodes, in: captured)
        // Preserve capture order after peer moves, but check current liveness and overlap.
        for identity in selection.nodes { _ = try structure.address(of: identity) }
        for identity in selection.nodes {
            let descendants = Set(try structure.descendants(of: identity))
            guard !selection.nodes.contains(where: { $0 != identity && descendants.contains($0) }) else { throw EditorError.invalidPath }
        }
        return captured
    }
    func validateSelectedNodes(_ nodes: [NodeID], in shape: StructuralState) throws {
        guard !nodes.isEmpty, nodes.count <= 10_000, Set(nodes).count == nodes.count else { throw EditorError.invalidPath }
        for identity in nodes {
            _ = try shape.address(of: identity)
            guard shape.nodes[identity]?.kind == .block else { throw EditorError.invalidPath }
            let descendants = Set(try shape.descendants(of: identity))
            guard !nodes.contains(where: { $0 != identity && descendants.contains($0) }) else { throw EditorError.invalidPath }
        }
        let order = try logicalNodes(shape).filter { nodes.contains($0) }
        guard order == nodes else { throw EditorError.invalidPath }
    }
    func validateTargetScope(_ document: String, _ epoch: String) throws {
        guard document == documentID else { throw EditorError.differentDocument }
        guard epoch == self.epoch else { throw ModernSessionError.incompatibleEpoch }
    }
    func moveResult(_ nodes: [NodeID], caret: WritingPosition?, observed: [ChangeID]) -> ModernStructuralResult {
        let selected = ModernNodeSelection(documentID: documentID, epoch: epoch, nodes: nodes, observed: observed)
        return ModernStructuralResult(focus: caret.map(ModernFocusIntent.text) ?? .nodes(selected), selection: .nodes(selected))
    }
    func logicalNodes(_ shape: StructuralState) throws -> [NodeID] {
        var result: [NodeID] = [], pending = Array(try shape.visibleOrder(in: .root).reversed())
        while let node = pending.popLast() {
            result.append(node)
            let collections = StructuralState.collectionFields(shape.nodes[node]!.kind, shape.nodes[node]!.fields, modern: true)
            for field in ["columns", "items", "children", "rows", "cells"].reversed() where collections[field] != nil {
                pending.append(contentsOf: try shape.visibleOrder(in: NodeCollection(owner: node, field: field)).reversed())
            }
        }
        return result
    }
    func editableFields(in nodes: [NodeID], structure shape: StructuralState) throws -> [WritingField] {
        let births = retainedWritingFields(shape), descendants = try Set(nodes.flatMap { try shape.descendants(of: $0) })
        return try logicalNodes(shape).filter { descendants.contains($0) }.flatMap { node in
            ["content", "summary", "caption", "code", "expression"].map { WritingField(node: node, name: $0) }.filter { births[$0] != nil }
        }
    }
    func edgePosition(_ field: WritingField, projection: WritingProjection, end: Bool) -> WritingPosition {
        let keys = projection.visibleKeys(in: field)
        return WritingPosition(documentID: documentID, epoch: epoch, field: field,
            anchor: end ? keys.last : keys.first, affinity: end || keys.isEmpty ? .after : .before)
    }
}
