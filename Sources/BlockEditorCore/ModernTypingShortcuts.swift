import Foundation

public enum ModernMarkState: String, Codable, Sendable { case on, off, mixed }
extension ModernSession {
    public func markState(in range: ModernTextRange, type: String) throws -> ModernMarkState {
        try validateModernMark(type: type, mark: .object(["type": .string(type)]))
        let selected = try modernCapturedSelection(range), projection = modernCurrentReplay.0
        let keys = selected.keys.filter { (try? projection.value(of: $0)["type"]) == .string("text") }
        let values = try keys.map { key in (try projection.value(of: key)["marks"]?.array ?? []).contains { $0["type"] == .string(type) } }
        if values.isEmpty {
            return selected.marks.contains { $0["type"] == .string(type) } ? .on : .off
        }
        return values.allSatisfy({ $0 }) ? .on : values.allSatisfy({ !$0 }) ? .off : .mixed
    }
    /// Delimiters and their conversion/mark are one shared author transaction.
    /// Captured scalar atoms supply the target, including Undo selection. Code,
    /// title, captions and atomic references never enter paragraph shortcuts.
    public func typingShortcut(in range: ModernTextRange) throws -> ModernStructuralResult {
        try authoringAllowed(command: "typingShortcut")
        let caret = try modernCapturedCaret(range), field = caret.field
        guard field != titleField, field.name == "content", try resolve(range.start).offset == resolve(range.end).offset,
              let value = structure.nodes[field.node], value.kind == .block,
              ["paragraph", "heading", "quote", "callout"].contains(value.fields["type"]?.string ?? "") else { return modernRangeResult(range) }
        let offset = try resolve(caret).offset, content = try text(in: field)
        _ = try position(in: field, offset: offset)
        let prefix = String(decoding: content.utf16.prefix(offset), as: UTF16.self)
        let markers: [String: WritingBlockTarget] = ["# ": .init(type: "heading", level: 1), "## ": .init(type: "heading", level: 2), "### ": .init(type: "heading", level: 3), "> ": .init(type: "quote"), "- ": .init(type: "list", style: "unordered"), "* ": .init(type: "list", style: "unordered"), "1. ": .init(type: "list", style: "ordered"), "[] ": .init(type: "list", style: "todo"), "[ ] ": .init(type: "list", style: "todo")]
        let id = try nextID()
        if value.fields["type"] == .string("paragraph"), let target = markers[prefix] {
            guard availability(for: "convertBlock").available, allowedBlockTypes?.contains(target.type) != false else { return modernRangeResult(range) }
            let selected = try modernCapturedSelection(captureTextRange(in: field, start: 0, end: offset))
            guard !selected.keys.isEmpty, selected.keys.allSatisfy({ (try? modernCurrentReplay.0.value(of: $0)["type"]) == .string("text") }) else { return modernRangeResult(range) }
            var operations: [ModernOperation] = []
            if target.type == "list" {
                let conversion = try planWritingSchemaConversion(source: field, target: target, id: id, structure: structure, projection: modernCurrentReplay.0)
                operations.append(.schemaConvert(conversion))
            } else {
                let attributes = target.level.map { ["level": JSONValue.number(Double($0))] } ?? [:]
                operations.append(.convertBlock(node: field.node, type: target.type, attributes: attributes))
            }
            operations.append(.text(.delete(keys: selected.keys)))
            endTypingGroup()
            return try performReturning(id, operations, historyBefore: historySelection(range)) { replay, _ in
                let destination = try replay.0.destination(of: field), position = self.edgePosition(destination, projection: replay.0, end: false)
                return ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
            }
        }
        guard availability(for: "format").available else { return modernRangeResult(range) }
        for (delimiter, mark) in [("**", "bold"), ("~~", "strikethrough"), ("`", "code"), ("*", "italic")] {
            guard allowedMarkTypes?.contains(mark) != false else { continue }
            guard prefix.hasSuffix(delimiter), prefix.utf16.count > delimiter.utf16.count * 2 else { continue }
            let closing = offset - delimiter.utf16.count, beforeClosing = String(prefix.dropLast(delimiter.count))
            guard let openingRange = beforeClosing.range(of: delimiter, options: .backwards) else { continue }
            let opening = beforeClosing[..<openingRange.lowerBound].utf16.count, begin = opening + delimiter.utf16.count
            guard begin < closing else { continue }
            let middle = try modernCapturedSelection(captureTextRange(in: field, start: begin, end: closing))
            guard !middle.keys.isEmpty, middle.keys.allSatisfy({ (try? modernCurrentReplay.0.value(of: $0)["type"]) == .string("text") }) else { continue }
            let leading = try modernCapturedSelection(captureTextRange(in: field, start: opening, end: begin))
            let trailing = try modernCapturedSelection(captureTextRange(in: field, start: closing, end: offset))
            let position = try self.position(in: field, offset: closing, affinity: .after)
            let operations: [ModernOperation] = [.text(.format(keys: middle.keys, type: mark, mark: .object(["type": .string(mark)]))), .text(.delete(keys: leading.keys + trailing.keys))]
            endTypingGroup()
            return try performReturning(id, operations, historyBefore: historySelection(range)) { _, _ in ModernStructuralResult(focus: .text(position), selection: .text(WritingTextRange(start: position, end: position))) }
        }
        return modernRangeResult(range)
    }
}
