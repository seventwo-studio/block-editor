import Foundation

extension ModernSession {
    /// Conversion keeps retained field/atom origins across code and list shapes.
    public func convertBlock(in range: ModernTextRange, to target: WritingBlockTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "convertBlock")
        let caret = try modernCapturedCaret(range)
        guard caret.field != titleField else { throw EditorError.invalidPath }
        let node = structure.nodes[caret.field.node]?.kind == .item ? try writingListOwner(of: caret.field.node, structure: structure) : caret.field.node
        _ = try structure.address(of: node)
        guard let original = structure.nodes[node] else { throw EditorError.invalidPath }
        let attributes = try modernConversionAttributes(target)
        let outcome = { (_: (WritingProjection, ModernDocument, StructuralState), _: [ChangeID]) in
            ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
        }
        let inline = ["paragraph", "heading", "quote", "callout"]
        if (inline.contains(original.fields["type"]?.string ?? "") && inline.contains(target.type)) || (original.fields["type"] == .string("list") && target.type == "list") {
            let converted = try writingConvertedBlock(original, type: target.type, attributes: attributes, modern: true)
            if converted.fields == original.fields { return outcome(modernCurrentReplay, modernObserved) }
            endTypingGroup()
            return try performReturning(nextID(), [.convertBlock(node: node, type: target.type, attributes: attributes)], result: outcome)
        }
        if original.fields["type"] == .string("code"), target.type == "code" { return outcome(modernCurrentReplay, modernObserved) }
        let id = try nextID()
        let conversion = try planWritingSchemaConversion(source: caret.field, target: target, id: id, structure: structure, projection: modernCurrentReplay.0)
        try validateModernSchemaShape(conversion, change: id)
        endTypingGroup()
        return try performReturning(id, [.schemaConvert(conversion)], result: outcome)
    }
    @discardableResult public func softBreak(in range: ModernTextRange) throws -> WritingPosition {
        try authoringAllowed(command: "softBreak")
        guard range.start.field == range.end.field, range.start.field != titleField else { throw EditorError.invalidPath }
        let selected = try modernCapturedSelection(range)
        let field = try selected.position.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: selected.position.field)
        endTypingGroup()
        return try replaceSelected(field: field, selected: selected, text: "\n", group: nil)
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
    case "code":
        guard target.level == nil, target.style == nil, target.variant == nil else { throw EditorError.invalidChange }
        return [:]
    default: throw ModernSessionError.unavailable("unsupportedConversion")
    }
}
