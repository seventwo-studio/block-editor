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
            return try performReturning(nextID(), [.convertBlock(node: node, type: target.type, attributes: attributes)], historyBefore: historySelection(range), result: outcome)
        }
        if original.fields["type"] == .string("code"), target.type == "code" { return outcome(modernCurrentReplay, modernObserved) }
        let id = try nextID()
        let conversion = try planWritingSchemaConversion(source: caret.field, target: target, id: id, structure: structure, projection: modernCurrentReplay.0)
        try validateModernSchemaShape(conversion, change: id)
        endTypingGroup()
        return try performReturning(id, [.schemaConvert(conversion)], historyBefore: historySelection(range), result: outcome)
    }
    /// A captured ordered block cohort converts atomically. Every lossless plan
    /// is checked before publication; one incompatible member rejects the action.
    public func convertBlocks(_ selection: ModernNodeSelection, to target: WritingBlockTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "convertBlock")
        _ = try validateSelection(selection)
        let attributes = try modernConversionAttributes(target), id = try nextID()
        var operations: [ModernOperation] = []
        let inline = ["paragraph", "heading", "quote", "callout"]
        for (index, node) in selection.nodes.enumerated() {
            guard let original = structure.nodes[node] else { throw EditorError.invalidPath }
            let type = original.fields["type"]?.string ?? ""
            if (inline.contains(type) && inline.contains(target.type)) || (type == "list" && target.type == "list") {
                let converted = try writingConvertedBlock(original, type: target.type, attributes: attributes, modern: true)
                if converted.fields != original.fields { operations.append(.convertBlock(node: node, type: target.type, attributes: attributes)) }
            } else if !(type == "code" && target.type == "code") {
                let field: WritingField
                if type == "list" {
                    let items = try structure.visibleOrder(in: NodeCollection(owner: node, field: "items"))
                    guard items.count == 1 else { throw ModernSessionError.unavailable("lossyRangeConversion") }
                    field = WritingField(node: items[0], name: "content")
                } else { field = WritingField(node: node, name: type == "code" ? "code" : "content") }
                let conversion = try planWritingSchemaConversion(source: field, target: target, id: id, structure: structure, projection: modernCurrentReplay.0, creationIndex: index)
                try validateModernSchemaShape(conversion, change: id)
                operations.append(.schemaConvert(conversion))
            }
        }
        guard !operations.isEmpty else { return moveResult(selection.nodes, caret: nil, observed: modernObserved) }
        endTypingGroup()
        return try performReturning(id, operations, historyBefore: historySelection(selection)) { _, observed in
            self.moveResult(selection.nodes, caret: nil, observed: observed)
        }
    }
    @discardableResult public func softBreak(in range: ModernTextRange) throws -> WritingPosition {
        try authoringAllowed(command: "softBreak")
        guard range.start.field == range.end.field, range.start.field != titleField else { throw EditorError.invalidPath }
        let selected = try modernCapturedSelection(range)
        let field = try selected.position.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: selected.position.field)
        endTypingGroup()
        return try replaceSelected(field: field, selected: selected, text: "\n", group: nil, historyBefore: historySelection(range))
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
