import Foundation

public enum ModernListAction: String, Codable, Sendable { case indent, outdent, reorder, setStyle, setChecked }
public struct ModernListTarget: Codable, Equatable, Sendable {
    public let selection: ModernNodeSelection
    public let caret: WritingPosition?
    public let boundary: ModernBlockBoundary?
    public init(selection: ModernNodeSelection, caret: WritingPosition? = nil, boundary: ModernBlockBoundary? = nil) {
        self.selection = selection; self.caret = caret; self.boundary = boundary
    }
}
/// Replay derives the exact list-only plan in the author's cohort before any
/// retained mutation is applied. This is not a general setter or move packet.
public struct ModernListStructure: Codable, Equatable, Sendable {
    public let target: ModernListTarget
    public let action: ModernListAction
    public let style: String?
    public let checked: Bool?
    public let operations: [WritingOperation]
}
func validateModernListArguments(action: ModernListAction, style: String?, checked: Bool?) throws {
    switch action {
    case .indent, .outdent, .reorder: guard style == nil, checked == nil else { throw EditorError.invalidChange }
    case .setStyle: guard ["ordered", "unordered", "todo"].contains(style ?? ""), checked == nil else { throw EditorError.invalidChange }
    case .setChecked: guard style == nil, checked != nil else { throw EditorError.invalidChange }
    }
}
func validateModernListShape(_ command: ModernListStructure, change: ChangeID) throws {
    try validateModernListArguments(action: command.action, style: command.style, checked: command.checked)
    let selection = command.target.selection
    guard !selection.nodes.isEmpty, selection.nodes.count <= 10_000, Set(selection.nodes).count == selection.nodes.count,
          selection.observed.count <= 100_000, !command.operations.isEmpty, command.operations.count <= 10_000 else { throw EditorError.invalidChange }
    try validateObservedFrontier(selection.observed, before: change)
    if let anchor = command.target.caret?.anchor, anchor.element.change.counter > 0 { guard anchor.element.change < change else { throw EditorError.invalidChange } }
    guard (command.action == .reorder) == (command.target.boundary != nil) else { throw EditorError.invalidChange }
    if let boundary = command.target.boundary {
        try validateObservedFrontier(boundary.observed, before: change)
        guard boundary.observed.count <= 100_000, let owner = boundary.collection.owner,
              ["items", "children"].contains(boundary.collection.field) else { throw EditorError.invalidChange }
        try modernStructuralIdentityShape(owner)
        if let after = boundary.after { try modernColumnPlacementShape(after) }
    }
    for node in selection.nodes { try modernStructuralIdentityShape(node) }
    for operation in command.operations {
        switch operation {
        case .structure(.moveNode(let node, let collection, let placement, let after)):
            guard command.action == .indent || command.action == .outdent || command.action == .reorder, let owner = collection.owner,
                  ["items", "children"].contains(collection.field), placement.change == change else { throw EditorError.invalidChange }
            try modernStructuralIdentityShape(node); try modernStructuralIdentityShape(owner)
            try modernStructuralIdentityShape(.inserted(creation: placement, path: []))
            if let after { try modernColumnPlacementShape(after) }
        case .structure(.setNodeField(let node, let path, let value)):
            guard command.action == .setChecked, path == ["checked"], value == .bool(command.checked!) else { throw EditorError.invalidChange }
            try modernStructuralIdentityShape(node)
        case .convertBlock(let node, let type, let attributes):
            guard command.action == .setStyle, type == "list", attributes == ["style": .string(command.style!)] else { throw EditorError.invalidChange }
            try modernStructuralIdentityShape(node)
        default: throw EditorError.invalidChange
        }
    }
}
func validateModernListNodes(_ nodes: [NodeID], in structure: StructuralState) throws {
    guard !nodes.isEmpty, nodes.count <= 10_000, Set(nodes).count == nodes.count else { throw EditorError.invalidPath }
    var selected = Set(nodes)
    for node in nodes {
        _ = try structure.address(of: node)
        guard let value = structure.nodes[node], value.kind == .item || (value.kind == .block && value.fields["type"] == .string("list")) else { throw EditorError.invalidPath }
        let descendants = Set(try structure.descendants(of: node)).subtracting([node])
        guard selected.isDisjoint(with: descendants) else { throw EditorError.invalidPath }
    }
    var logical: [NodeID] = [], pending = Array(try structure.visibleOrder(in: .root).reversed())
    while let node = pending.popLast() {
        if selected.remove(node) != nil { logical.append(node) }
        guard let value = structure.nodes[node] else { throw EditorError.invalidPath }
        let collections = StructuralState.collectionFields(value.kind, value.fields, modern: true)
        for field in ["columns", "items", "children", "rows", "cells"].reversed() where collections[field] != nil {
            pending.append(contentsOf: try structure.visibleOrder(in: NodeCollection(owner: node, field: field)).reversed())
        }
    }
    guard logical == nodes else { throw EditorError.invalidPath }
}
func planModernListStructure(target: ModernListTarget, action: ModernListAction, style: String?, checked: Bool?, change: ChangeID,
                             captured: (WritingProjection, StructuralState), authored: (WritingProjection, StructuralState), boundaryCaptured: StructuralState? = nil) throws -> ModernListStructure {
    try validateModernListArguments(action: action, style: style, checked: checked)
    guard (action == .reorder) == (target.boundary != nil) else { throw EditorError.invalidChange }
    try validateModernListNodes(target.selection.nodes, in: captured.1)
    for node in target.selection.nodes {
        _ = try authored.1.address(of: node)
        guard let value = authored.1.nodes[node], value.kind == .item || (value.kind == .block && value.fields["type"] == .string("list")) else { throw EditorError.invalidPath }
        let descendants = Set(try authored.1.descendants(of: node)).subtracting([node])
        guard Set(target.selection.nodes).isDisjoint(with: descendants) else { throw EditorError.invalidPath }
    }
    if let caret = target.caret {
        let original = try resolveWritingPosition(caret, projection: captured.0, structure: captured.1) { _ in nil }
        let current = try resolveWritingPosition(caret, projection: authored.0, structure: authored.1) { _ in nil }
        let originalNodes = try Set(target.selection.nodes.flatMap { try captured.1.descendants(of: $0) })
        let currentNodes = try Set(target.selection.nodes.flatMap { try authored.1.descendants(of: $0) })
        guard let origin = original.address.identity, let actual = current.address.identity,
              originalNodes.contains(origin), currentNodes.contains(actual) else { throw EditorError.invalidPath }
    }
    let operations: [WritingOperation]
    switch action {
    case .reorder:
        guard let boundary = target.boundary, let original = boundaryCaptured else { throw EditorError.invalidChange }
        try validateModernListBoundary(boundary, captured: original, authored: authored.1)
        operations = try planWritingListMove(target.selection.nodes, into: boundary.collection, after: boundary.after, change: change, structure: authored.1).map(WritingOperation.structure)
    case .indent, .outdent:
        operations = try planWritingListHierarchy(target.selection.nodes, outdent: action == .outdent, change: change, structure: authored.1).map(WritingOperation.structure)
    case .setChecked:
        var edits: [WritingOperation] = []
        for node in target.selection.nodes {
            guard let value = authored.1.nodes[node], value.kind == .item,
                  authored.1.nodes[try writingListOwner(of: node, structure: authored.1)]?.fields["style"] == .string("todo") else { throw EditorError.invalidPath }
            if (value.fields["checked"] ?? .bool(false)) != .bool(checked!) { edits.append(.structure(.setNodeField(identity: node, path: ["checked"], value: .bool(checked!)))) }
        }
        operations = edits
    case .setStyle:
        var seen = Set<NodeID>(), edits: [WritingOperation] = []
        for node in target.selection.nodes {
            let owner = authored.1.nodes[node]?.kind == .item ? try writingListOwner(of: node, structure: authored.1) : node
            guard authored.1.nodes[owner]?.fields["type"] == .string("list") else { throw EditorError.invalidPath }
            if seen.insert(owner).inserted, authored.1.nodes[owner]?.fields["style"] != .string(style!) {
                edits.append(.convertBlock(node: owner, type: "list", attributes: ["style": .string(style!)]))
            }
        }
        operations = edits
    }
    return ModernListStructure(target: target, action: action, style: style, checked: checked, operations: operations)
}
func applyModernMetadataConversion(node: NodeID, type: String, attributes: [String: JSONValue], enabled: Bool,
                                   raw: inout Materialized, collectionBirths: [NodeCollection: NodeKind]) throws {
    guard let current = raw.structure!.nodes[node] else { throw EditorError.invalidChange }
    guard enabled else { return }
    let retired = current.fields["type"] != .string("list") && type == "list" && collectionBirths[NodeCollection(owner: node, field: "items")] == .item
    let converted: StructuralState.Node
    do { converted = try writingConvertedBlock(current, type: type, attributes: attributes, modern: true, retiredList: retired) }
    catch EditorError.invalidChange { throw EditorError.invalidDocument("Metadata conversion conflicts with current block shape") }
    raw.structure!.nodes[node] = converted; raw.structure!.touched.insert(node)
}
func applyModernListStructure(_ command: ModernListStructure, change: ChangeID, enabled: Bool, raw: inout Materialized,
                              collectionBirths: [NodeCollection: NodeKind], introduced: inout Set<ElementID>) throws {
    for operation in command.operations {
        switch operation {
        case .structure(let mutation):
            if case .moveNode(_, _, let placement, _) = mutation { guard introduced.insert(placement).inserted else { throw EditorError.invalidChange } }
            let original = raw.structure!.nodes
            var validating = writingRetainedCollectionShape(raw, mutations: [mutation], collectionBirths: collectionBirths)
            if !enabled, case .moveNode(let node, let collection, _, _) = mutation,
               (try? validating.structure!.kind(in: collection)) == .item, var value = validating.structure!.nodes[node], value.birthKind == .item {
                value.kind = .item; validating.structure!.nodes[node] = value
            }
            let adjusted = validating.structure!.nodes.filter { original[$0.key]?.fields != $0.value.fields || original[$0.key]?.kind != $0.value.kind }
            raw.structure = validating.structure
            do { try apply([mutation], enabled: enabled, to: &raw) }
            catch EditorError.invalidPath { throw EditorError.invalidDocument("List hierarchy conflicts with current paragraph roles") }
            for owner in adjusted.keys { raw.structure!.nodes[owner] = original[owner] }
        case .convertBlock(let node, let type, let attributes):
            try applyModernMetadataConversion(node: node, type: type, attributes: attributes, enabled: enabled, raw: &raw, collectionBirths: collectionBirths)
        default: throw EditorError.invalidChange
        }
    }
}

func validateModernListBoundary(_ boundary: ModernBlockBoundary, captured: StructuralState, authored: StructuralState) throws {
    guard try captured.kind(in: boundary.collection) == .item, try authored.kind(in: boundary.collection) == .item,
          let owner = boundary.collection.owner else { throw EditorError.invalidPath }
    _ = try captured.address(of: owner); _ = try authored.address(of: owner)
    if let after = boundary.after {
        guard let anchor = captured.placements[after], anchor.collection == boundary.collection,
              try captured.effectivePlacements()[anchor.node]?.id == after,
              authored.placements[after]?.collection == boundary.collection else { throw EditorError.invalidPath }
        _ = try captured.address(of: anchor.node)
    }
}

extension ModernSession {
    public func captureListBoundary(in collection: NodeCollection, after node: NodeID? = nil) throws -> ModernBlockBoundary {
        guard try structure.kind(in: collection) == .item, let owner = collection.owner else { throw EditorError.invalidPath }
        _ = try structure.address(of: owner)
        var after: NodePlacementID?
        if let node {
            guard (try structure.visibleOrder(in: collection)).contains(node) else { throw EditorError.invalidPath }
            after = try structure.effectivePlacements()[node]?.id
        }
        return ModernBlockBoundary(documentID: documentID, epoch: epoch, collection: collection, after: after, observed: modernObserved)
    }
    public func captureListNodes(_ nodes: [NodeID]) throws -> ModernNodeSelection {
        try validateModernListNodes(nodes, in: structure)
        return ModernNodeSelection(documentID: documentID, epoch: epoch, nodes: nodes, observed: modernObserved)
    }
    public func listStructure(_ target: ModernListTarget, action: ModernListAction, style: String? = nil, checked: Bool? = nil) throws -> ModernStructuralResult {
        try authoringAllowed(command: "listStructure")
        guard allowedListActions?.contains(action) ?? true else { throw ModernSessionError.unavailable("hostPolicy") }
        try validateTargetScope(target.selection.documentID, target.selection.epoch)
        if let caret = target.caret { try validateTargetScope(caret.documentID, caret.epoch) }
        let captured = try modernCapturedReplay(target.selection.observed), id = try nextID()
        let boundaryCaptured: StructuralState?
        if let boundary = target.boundary {
            try validateTargetScope(boundary.documentID, boundary.epoch)
            boundaryCaptured = try modernCapturedStructure(boundary.observed)
        } else { boundaryCaptured = nil }
        let command: ModernListStructure
        do { command = try planModernListStructure(target: target, action: action, style: style, checked: checked, change: id,
            captured: (captured.0, captured.2), authored: (modernCurrentReplay.0, structure), boundaryCaptured: boundaryCaptured) }
        catch EditorError.invalidDocument { throw ModernSessionError.unavailable("listPlacementConflict") }
        if let caret = target.caret { _ = try modernResolve(caret, in: captured, observed: target.selection.observed) }
        if command.operations.isEmpty { return moveResult(target.selection.nodes, caret: target.caret, observed: modernObserved) }
        endTypingGroup()
        return try performReturning(id, [.listStructure(command)]) { _, observed in self.moveResult(target.selection.nodes, caret: target.caret, observed: observed) }
    }
}
