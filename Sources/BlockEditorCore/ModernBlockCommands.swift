import Foundation

extension ModernSession {
    /// Same-content conversion keeps field and atom origins. Schema-changing
    /// list/code conversion remains explicit subsequent ST-122 work.
    public func convertBlock(in range: ModernTextRange, to target: WritingBlockTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "convertBlock")
        _ = try modernCapturedCaret(range)
        guard range.start.field != titleField else { throw EditorError.invalidPath }
        var node = range.start.field.node
        let placements = try structure.effectivePlacements()
        if target.type == "list", structure.nodes[node]?.kind == .item {
            var visited = Set<NodeID>()
            while let owner = placements[node]?.collection.owner {
                guard visited.insert(node).inserted else { throw EditorError.invalidPath }
                node = owner
                if structure.nodes[node]?.kind == .block { break }
            }
        }
        _ = try structure.address(of: node)
        guard let original = structure.nodes[node] else { throw EditorError.invalidPath }
        let attributes = try modernConversionAttributes(target)
        let converted = try writingConvertedBlock(original, type: target.type, attributes: attributes, modern: true)
        let outcome = { (_: (WritingProjection, ModernDocument, StructuralState), _: [ChangeID]) in
            ModernStructuralResult(focus: .text(range.start), selection: .text(WritingTextRange(start: range.start, end: range.start)))
        }
        if converted.fields == original.fields { return outcome(modernCurrentReplay, modernObserved) }
        endTypingGroup()
        return try performReturning(nextID(), [.convertBlock(node: node, type: target.type, attributes: attributes)], result: outcome)
    }
    @discardableResult public func softBreak(in range: ModernTextRange) throws -> WritingPosition {
        try authoringAllowed(command: "softBreak")
        guard range.start.field == range.end.field, range.start.field != titleField else { throw EditorError.invalidPath }
        let selected = try modernCapturedSelection(range)
        endTypingGroup()
        return try replaceSelected(field: range.start.field, selected: selected, text: "\n", group: nil)
    }
}

private func modernConversionAttributes(_ target: WritingBlockTarget) throws -> [String: JSONValue] {
    switch target.type {
    case "paragraph", "quote":
        guard target.level == nil, target.style == nil, target.variant == nil else { throw EditorError.invalidChange }
        return [:]
    case "heading":
        guard target.style == nil, target.variant == nil else { throw EditorError.invalidChange }
        return ["level": .number(Double(target.level ?? 1))]
    case "callout":
        guard target.level == nil, target.style == nil else { throw EditorError.invalidChange }
        return ["variant": .string(target.variant ?? "info")]
    case "list":
        guard target.level == nil, target.variant == nil else { throw EditorError.invalidChange }
        return ["style": .string(target.style ?? "unordered")]
    default: throw ModernSessionError.unavailable("schemaConversionPending")
    }
}
