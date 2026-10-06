import Foundation

extension ModernSession {
    /// Catalog blocks are siblings of the containing block, never cells or list
    /// items. Capture this once before a picker takes the native input focus.
    public func captureInsertionBoundary(after field: WritingField) throws -> ModernBlockBoundary {
        _ = try text(in: field)
        if field == titleField { return try captureBoundary(after: nodes().last) }
        var node = field.node, visited = Set<NodeID>()
        while visited.insert(node).inserted {
            let collection = try parentCollection(of: node)
            if try structure.kind(in: collection) == .block { return try captureBoundary(in: collection, after: node) }
            guard let owner = collection.owner else { throw EditorError.invalidPath }
            node = owner
        }
        throw EditorError.invalidPath
    }
    /// Logical reading order, independent of the visual column presentation.
    /// A disclosed container retains its own field while hidden descendants are
    /// omitted only from this local navigation projection.
    public func logicalFields(collapsed: Set<NodeID> = [], includingTitle: Bool = true) throws -> [WritingField] {
        let hidden = try Set(collapsed.flatMap { container in try structure.descendants(of: container).filter { $0 != container } })
        let births = retainedWritingFields(structure)
        return (includingTitle ? [titleField] : []) + (try logicalNodes(structure)).filter { !hidden.contains($0) }.flatMap { node in
            ["content", "summary", "caption", "code", "expression"].map { WritingField(node: node, name: $0) }.filter { births[$0] != nil }
        }
    }
    public func parentCollection(of node: NodeID) throws -> NodeCollection {
        _ = try structure.address(of: node)
        guard let placement = try structure.effectivePlacements()[node] else { throw EditorError.invalidPath }
        return placement.collection
    }
    /// One capture cohort for all fields in a directed text selection. Each
    /// range selects its captured atoms; subsequent peer insertions stay intact.
    public func captureTextSpan(from start: WritingPosition, to end: WritingPosition, collapsed: Set<NodeID> = []) throws -> [ModernTextRange] {
        let fields = try logicalFields(collapsed: collapsed)
        let first = try resolve(start), last = try resolve(end)
        let firstField = try start.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: start.field)
        let lastField = try end.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: end.field)
        guard let a = fields.firstIndex(of: firstField), let b = fields.firstIndex(of: lastField) else { throw EditorError.invalidRange }
        if a == b { return [try captureTextRange(in: firstField, start: first.offset, end: last.offset)] }
        guard firstField != titleField, lastField != titleField else { throw EditorError.invalidRange }
        let backward = a > b
        return try Array(fields[min(a, b)...max(a, b)]).map { field in
            let lower = field == (backward ? lastField : firstField) ? (backward ? last.offset : first.offset) : 0
            let upper = field == (backward ? firstField : lastField) ? (backward ? first.offset : last.offset) : try text(in: field).utf16.count
            return try captureTextRange(in: field, start: backward ? upper : lower, end: backward ? lower : upper)
        }
    }
}

/// Multi-field formatting is captured once and committed as one author action.
/// Existing single-field format requests remain source and wire compatible.
public struct ModernTextSpanTarget: Codable, Equatable, Sendable {
    public let ranges: [ModernTextRange]
    public init(ranges: [ModernTextRange]) { self.ranges = ranges }
}
extension ModernSession {
    @discardableResult public func format(in ranges: [ModernTextRange], markType: String, mark: JSONValue?) throws -> ModernStructuralResult {
        try authoringAllowed(command: "format")
        guard !ranges.isEmpty, ranges.count <= 10_000, Set(ranges.map { $0.start.field }).count == ranges.count,
              ranges.allSatisfy({ $0.observed == ranges[0].observed }) else { throw EditorError.invalidRange }
        if ranges.count == 1 { return try format(in: ranges[0], markType: markType, mark: mark) }
        let operations = try ranges.flatMap { try modernMarkOperations(in: $0, type: markType, mark: mark) }
        let target = ModernDeleteTarget(ranges: ranges)
        let backward = try resolve(ranges[0].start).offset > resolve(ranges[0].end).offset
        let result = ModernStructuralResult(focus: .text(backward ? ranges[0].end : ranges.last!.end), selection: .mixed(target))
        endTypingGroup()
        if operations.isEmpty { return result }
        return try performReturning(nextID(), operations, historyBefore: historySelection(target)) { _, _ in result }
    }
    public func markState(in ranges: [ModernTextRange], type: String) throws -> ModernMarkState {
        guard !ranges.isEmpty, ranges.count <= 10_000 else { throw EditorError.invalidRange }
        let states = try ranges.map { try markState(in: $0, type: type) }
        return states.allSatisfy({ $0 == .on }) ? .on : states.allSatisfy({ $0 == .off }) ? .off : .mixed
    }
}
