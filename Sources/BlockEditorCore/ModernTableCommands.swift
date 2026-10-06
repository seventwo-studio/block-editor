import Foundation

public enum ModernTableAction: String, Codable, CaseIterable, Sendable {
    case insertRow, removeRow, insertColumn, removeColumn, setHeader
}
/// A table action is bound to retained row/cell identities and its capture cohort.
/// Display indices never cross the command boundary.
public struct ModernTableTarget: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let table: NodeID
    public let row: NodeID?
    public let cell: NodeID?
    public let observed: [ChangeID]
}
public struct ModernTableStructure: Codable, Equatable, Sendable {
    public let target: ModernTableTarget
    public let action: ModernTableAction
    public let newIDs: [String]
    public let header: Bool?
    public let operations: [Mutation]
}

func modernTableLocation(_ target: ModernTableTarget, in shape: StructuralState) throws -> (rows: [NodeID], cells: [[NodeID]], row: Int?, column: Int?) {
    _ = try shape.address(of: target.table)
    guard shape.nodes[target.table]?.fields["type"] == .string("table") else { throw EditorError.invalidPath }
    let rows = try shape.visibleOrder(in: NodeCollection(owner: target.table, field: "rows"))
    let cells = try rows.map { try shape.visibleOrder(in: NodeCollection(owner: $0, field: "cells")) }
    guard rows.count <= 1000, cells.allSatisfy({ $0.count <= 100 }), cells.reduce(0, { $0 + $1.count }) <= 20_000 else { throw EditorError.recoveryCapacityExceeded }
    let row = target.row.flatMap { rows.firstIndex(of: $0) }
    if target.row != nil && row == nil { throw EditorError.invalidPath }
    let column = row.flatMap { index in target.cell.flatMap { cells[index].firstIndex(of: $0) } }
    if target.cell != nil && column == nil { throw EditorError.invalidPath }
    return (rows, cells, row, column)
}
func validateModernTableShape(_ command: ModernTableStructure, change: ChangeID) throws {
    try modernStructuralIdentityShape(command.target.table)
    if let row = command.target.row { try modernStructuralIdentityShape(row) }
    if let cell = command.target.cell { try modernStructuralIdentityShape(cell) }
    try validateObservedFrontier(command.target.observed, before: change)
    guard command.target.observed.count <= 100_000, command.operations.count <= 2001,
          command.newIDs.count <= 1001, Set(command.newIDs).count == command.newIDs.count,
          command.newIDs.allSatisfy({ validToken($0) }),
          (command.action == .setHeader) == (command.header != nil) else { throw EditorError.invalidChange }
    for mutation in command.operations {
        switch mutation {
        case .insertNode(let value, let identity, let collection, let placement, let after):
            guard command.action == .insertRow || command.action == .insertColumn,
                  placement.change == change, placement.index >= 0,
                  identity == .inserted(creation: placement, path: []), let owner = collection.owner,
                  ["rows", "cells"].contains(collection.field) else { throw EditorError.invalidChange }
            try modernStructuralIdentityShape(owner)
            try validateNode(value, kind: collection.field == "rows" ? .row : .cell, modern: true)
            if let after { try modernColumnPlacementShape(after) }
        case .deleteNodes(let nodes):
            guard command.action == .removeRow || command.action == .removeColumn, !nodes.isEmpty else { throw EditorError.invalidChange }
            for node in nodes { try modernStructuralIdentityShape(node) }
        case .setNodeField(let node, let path, let value):
            try modernStructuralIdentityShape(node)
            guard (command.action == .setHeader && path == ["header"] && value == .bool(command.header!)) ||
                  ([ModernTableAction.insertColumn, .removeColumn].contains(command.action) && node == command.target.table && path == ["columnWidths"]) else { throw EditorError.invalidChange }
        default: throw EditorError.invalidChange
        }
    }
}
func planModernTable(_ target: ModernTableTarget, action: ModernTableAction, newIDs: [String], header: Bool?, change: ChangeID,
                     captured: StructuralState, authored: StructuralState) throws -> ModernTableStructure {
    let original = try modernTableLocation(target, in: captured), current = try modernTableLocation(target, in: authored)
    guard (action == .setHeader) == (header != nil), Set(newIDs).count == newIDs.count, newIDs.allSatisfy({ validToken($0) }) else { throw EditorError.invalidChange }
    // A structural action cannot silently reinterpret a ragged admitted table.
    let width = current.cells.first?.count ?? 1
    if action != .setHeader { guard current.cells.allSatisfy({ $0.count == width }) else { throw ModernSessionError.unavailable("raggedTable") } }
    var edits: [Mutation] = []
    let placements = try authored.effectivePlacements()
    func cell(_ id: String) -> JSONValue { .object(["id": .string(id), "content": .array([])]) }
    switch action {
    case .insertRow:
        guard current.rows.count < 1000, width > 0, newIDs.count == width + 1 else { throw EditorError.invalidChange }
        let value = JSONValue.object(["id": .string(newIDs[0]), "cells": .array(newIDs.dropFirst().map(cell))])
        guard !current.rows.contains(where: { authored.nodes[$0]?.label == newIDs[0] }) else { throw EditorError.invalidChange }
        let element = ElementID(change: change, index: 0)
        edits = [.insertNode(value: value, identity: .inserted(creation: element, path: []), collection: NodeCollection(owner: target.table, field: "rows"), placement: element, after: target.row.flatMap { placements[$0]?.id })]
    case .removeRow:
        guard let row = target.row, current.rows.count > 1, newIDs.isEmpty else { throw ModernSessionError.unavailable("lastTableRow") }
        // Only the captured descendants are deleted; later peer cells survive.
        edits = [.deleteNodes(identities: try captured.descendants(of: row))]
    case .insertColumn, .removeColumn:
        guard let column = current.column, original.column != nil, !current.rows.isEmpty else { throw EditorError.invalidPath }
        if action == .insertColumn {
            guard width < 100, newIDs.count == current.rows.count else { throw EditorError.invalidChange }
            for (index, row) in current.rows.enumerated() {
                guard !current.cells[index].contains(where: { authored.nodes[$0]?.label == newIDs[index] }) else { throw EditorError.invalidChange }
                let element = ElementID(change: change, index: index)
                edits.append(.insertNode(value: cell(newIDs[index]), identity: .inserted(creation: element, path: []), collection: NodeCollection(owner: row, field: "cells"), placement: element, after: placements[current.cells[index][column]]?.id))
            }
        } else {
            guard width > 1, newIDs.isEmpty else { throw ModernSessionError.unavailable("lastTableColumn") }
            // Reject reinterpretation when another structural writer changed the
            // captured column. Text and formatting peers remain compatible.
            guard current.rows == original.rows, current.cells == original.cells else { throw ModernSessionError.unavailable("tableStructureChanged") }
            edits = [.deleteNodes(identities: current.cells.map { $0[column] })]
        }
        if let widths = authored.nodes[target.table]?.fields["columnWidths"]?.array {
            guard widths.count == width else { throw ModernSessionError.unavailable("tableWidthsChanged") }
            var next = widths
            if action == .insertColumn { next.insert(widths[column], at: column + 1) } else { next.remove(at: column) }
            edits.append(.setNodeField(identity: target.table, path: ["columnWidths"], value: .array(next)))
        }
    case .setHeader:
        guard let node = target.cell, newIDs.isEmpty else { throw EditorError.invalidPath }
        if authored.nodes[node]?.fields["header"] != .bool(header!) { edits = [.setNodeField(identity: node, path: ["header"], value: .bool(header!))] }
    }
    return ModernTableStructure(target: target, action: action, newIDs: newIDs, header: header, operations: edits)
}
func applyModernTable(_ command: ModernTableStructure, enabled: Bool, raw: inout Materialized,
                      births: inout [WritingField: WritingFieldBirth], collectionBirths: inout [NodeCollection: NodeKind]) throws {
    try apply(command.operations, enabled: enabled, to: &raw)
    retainModernFieldBirths(in: raw.structure!, births: &births)
    collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
}
extension ModernSession {
    public func captureTableTarget(table: NodeID, row: NodeID? = nil, cell: NodeID? = nil) throws -> ModernTableTarget {
        let target = ModernTableTarget(documentID: documentID, epoch: epoch, table: table, row: row, cell: cell, observed: modernObserved)
        _ = try modernTableLocation(target, in: structure)
        return target
    }
    public func tableStructure(_ target: ModernTableTarget, action: ModernTableAction, newIDs: [String] = [], header: Bool? = nil) throws -> ModernStructuralResult {
        try authoringAllowed(command: "tableStructure")
        try validateTargetScope(target.documentID, target.epoch)
        let id = try nextID(), captured = try modernCapturedStructure(target.observed)
        let command = try planModernTable(target, action: action, newIDs: newIDs, header: header, change: id, captured: captured, authored: structure)
        try validateModernTableShape(command, change: id)
        let selection = try captureLocalNodes([target.table])
        if command.operations.isEmpty { return ModernStructuralResult(focus: .nodes(selection), selection: .nodes(selection)) }
        endTypingGroup()
        return try performReturning(id, [.tableStructure(command)]) { _, observed in
            let selected = ModernNodeSelection(documentID: self.documentID, epoch: self.epoch, nodes: [target.table], observed: observed)
            return ModernStructuralResult(focus: .nodes(selected), selection: .nodes(selected))
        }
    }
}
