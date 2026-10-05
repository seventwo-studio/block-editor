import Foundation

/// Version 2 is deliberately distinct from the legacy version-1 clipboard.
/// Rich data and its explicit visible fallback are inert, with no source lookup.
public struct ModernClipboard: Codable, Equatable, Sendable {
    public let version: Int
    public let collaborationVersion: Int
    public let parts: [WritingClipboardPart]
    public let plainText: String

    public init(parts: [WritingClipboardPart]) throws {
        version = 2; collaborationVersion = 7; self.parts = parts
        // Bound the complete rich input before walking only its schema fields.
        try validateModernClipboardParts(parts)
        plainText = modernClipboardPlainText(parts)
        try validate()
    }
    public init(json: Data) throws {
        guard json.count <= 32_000_000 else { throw EditorError.invalidRange }
        let wire = try modernWireValue(json)
        let value = try JSONDecoder().decode(Self.self, from: canonicalEncoder().encode(wire))
        guard try modernWireValue(canonicalEncoder().encode(value)) == wire else { throw EditorError.invalidChange }
        try value.validate(); self = value
    }
    public func json() throws -> Data { try validate(); return try canonicalEncoder().encode(self) }
    public func validate() throws {
        guard version == 2 else { throw EditorError.unsupportedVersion(version) }
        guard collaborationVersion == 7 else { throw EditorError.unsupportedVersion(collaborationVersion) }
        try validateModernClipboardParts(parts)
        guard plainText == modernClipboardPlainText(parts),
              try canonicalEncoder().encode(self).count <= 32_000_000 else { throw EditorError.invalidChange }
    }
    /// Separate new-content admission. Copy never applies this local policy to
    /// accepted content, and rejection leaves the complete payload available.
    public func validateForPaste(policy: WritingPastePolicy = WritingPastePolicy()) throws {
        try validate()
        for part in parts {
            switch part {
            case .inline(let values): try modernClipboardInlinePolicy(values, policy: policy)
            case .node(let value, let name):
                guard let kind = NodeKind(rawValue: name) else { throw EditorError.invalidPath }
                try modernClipboardNodePolicy(value, kind: kind, policy: policy)
            }
        }
    }
    public static func plain(_ text: String) throws -> ModernClipboard {
        guard text.utf16.count <= 1_000_000 else { throw EditorError.invalidRange }
        return try ModernClipboard(parts: WritingClipboard.plainText(text).parts)
    }
    public static func multiline(_ text: String) throws -> ModernClipboard {
        let parts = try WritingClipboard.multilineText(text).parts.map { part -> WritingClipboardPart in
            guard case .node(let value, let kind) = part, var fields = value.object else { return part }
            fields["content"] = .array((fields["content"]?.array ?? []).map { atom in
                guard var item = atom.object else { return atom }
                if item["marks"] == .array([]) { item.removeValue(forKey: "marks") }; return .object(item)
            })
            return .node(value: .object(fields), kind: kind)
        }
        return try ModernClipboard(parts: parts)
    }
    public static func markdown(_ text: String) throws -> ModernClipboard {
        try ModernClipboard(parts: WritingClipboard.markdown(text).parts)
    }
}

private func validateModernClipboardParts(_ parts: [WritingClipboardPart]) throws {
    guard !parts.isEmpty, parts.count <= 100_000 else { throw EditorError.invalidRange }
    for part in parts {
        switch part {
        case .inline(let values):
            try inspectModernPayload(.array(values)); try Validation.inline(.array(values), modern: true)
        case .node(let value, let name):
            try inspectModernPayload(value)
            guard let kind = NodeKind(rawValue: name), let fields = value.object,
                  let id = fields["id"]?.string, !id.isEmpty else { throw EditorError.invalidPath }
            let block: Block
            switch kind {
            case .document, .column: throw EditorError.invalidPath
            case .block: block = try Block(fields: fields)
            case .item:
                block = try Block(fields: ["id": .string("clipboard-validation"), "type": .string("list"), "style": .string("unordered"), "items": .array([value])])
            case .row:
                block = try Block(fields: ["id": .string("clipboard-validation"), "type": .string("table"), "rows": .array([value])])
            case .cell:
                block = try Block(fields: ["id": .string("clipboard-validation"), "type": .string("table"), "rows": .array([.object(["id": .string("row"), "cells": .array([value])])])])
            }
            try Validation.block(block, modern: true)
        }
    }
    guard try canonicalEncoder().encode(parts).count <= 32_000_000 else { throw EditorError.invalidRange }
}

private func modernClipboardInlinePolicy(_ values: [JSONValue], policy: WritingPastePolicy) throws {
    for value in values where value["type"] == .string("text") {
        for mark in value["marks"]?.array ?? [] {
            guard let type = mark["type"]?.string, policy.allowedMarkTypes?.contains(type) ?? true else { throw EditorError.invalidChange }
            if type == "link" { try validateClipboardURL(mark["href"]?.string) }
        }
    }
}
private func modernClipboardNodePolicy(_ value: JSONValue, kind: NodeKind, policy: WritingPastePolicy) throws {
    guard let fields = value.object else { throw EditorError.invalidPath }
    let type: String
    switch kind {
    case .document: throw EditorError.invalidPath
    case .column: type = "columns"
    case .item: type = "list"
    case .row, .cell: type = "table"
    case .block:
        guard let name = fields["type"]?.string,
              ["paragraph", "heading", "quote", "callout", "list", "code", "image", "file", "table", "embed", "math", "toggle", "divider", "columns"].contains(name) else { throw EditorError.invalidChange }
        type = name
        if ["image", "file", "embed"].contains(type) {
            guard policy.allowAssetMetadata else { throw EditorError.invalidChange }
            if type == "embed" {
                try validateClipboardURL(fields["url"]?.string)
                if let thumbnail = fields["thumbnail"] { try validateClipboardAssetURL(thumbnail.string) }
            } else { try validateClipboardAssetURL(fields["src"]?.string) }
        }
    }
    guard policy.allowedBlockTypes?.contains(type) ?? true else { throw EditorError.restrictedBlock(type) }
    for field in ["content", "summary", "caption"] {
        if let values = fields[field]?.array { try modernClipboardInlinePolicy(values, policy: policy) }
    }
    for (field, childKind) in StructuralState.collectionFields(kind, fields, modern: true) {
        for child in fields[field]?.array ?? [] { try modernClipboardNodePolicy(child, kind: childKind, policy: policy) }
    }
}

private func modernClipboardPlainText(_ parts: [WritingClipboardPart]) -> String {
    func visible(_ value: JSONValue, kind: NodeKind) -> String {
        guard let fields = value.object else { return "" }
        func children(_ field: String, _ kind: NodeKind) -> [String] { (fields[field]?.array ?? []).map { visible($0, kind: kind) } }
        func inline(_ field: String) -> String { BlockEditorCore.plainText(fields[field]?.array ?? []) }
        switch kind {
        case .document: return ""
        case .column: return children("children", .block).joined(separator: "\n")
        case .item: return ([inline("content")] + children("children", .item)).joined(separator: "\n")
        case .row: return children("cells", .cell).joined(separator: "\t")
        case .cell: return inline("content")
        case .block:
            switch fields["type"]?.string {
            case "paragraph", "heading", "quote", "callout": return inline("content")
            case "list": return children("items", .item).joined(separator: "\n")
            case "table": return children("rows", .row).joined(separator: "\n")
            case "toggle": return ([inline("summary")] + children("children", .block)).joined(separator: "\n")
            case "columns": return children("columns", .column).joined(separator: "\n")
            case "code": return fields["code"]?.string ?? ""
            case "math": return fields["expression"]?.string ?? ""
            case "file": return fields["name"]?.string ?? ""
            case "embed": return fields["url"]?.string ?? ""
            case "image": return [fields["alt"]?.string, fields["caption"] == nil ? nil : inline("caption")].compactMap { $0 }.joined(separator: "\n")
            default: return "" // Opaque consumer fields are never guessed as visible content.
            }
        }
    }
    return parts.map { part in
        switch part {
        case .inline(let values): return BlockEditorCore.plainText(values)
        case .node(let value, let name): return NodeKind(rawValue: name).map { visible(value, kind: $0) } ?? ""
        }
    }.joined(separator: "\n")
}

extension ModernSession {
    /// Copy is read-only, including during composition/recovery or reduced
    /// authoring policy. Hosts settle native drafts before capturing their input.
    public func copyClipboard(_ target: ModernDeleteTarget) throws -> ModernClipboard {
        guard target.ranges.count <= 10_000, target.nodes != nil || !target.ranges.isEmpty else { throw EditorError.invalidPath }
        var whole = Set<NodeID>(), covered = Set<NodeID>()
        if let selection = target.nodes {
            _ = try validateSelection(selection); whole = Set(selection.nodes)
            for node in selection.nodes { covered.formUnion(try structure.descendants(of: node)) }
        }
        let title = target.ranges.contains { $0.start.field == titleField || $0.end.field == titleField }
        if title {
            guard whole.isEmpty, target.ranges.allSatisfy({ $0.start.field == titleField && $0.end.field == titleField }) else { throw EditorError.invalidPath }
        }
        var selected = Set<WritingAtomKey>()
        for range in target.ranges { selected.formUnion(try modernCapturedSelection(range).keys) }
        let replay = modernCurrentReplay.0
        var parts: [WritingClipboardPart] = []
        func append(_ field: WritingField) throws {
            let values = try replay.visibleKeys(in: field).filter { selected.contains($0) }.map { try replay.value(of: $0) }
            if !values.isEmpty { parts.append(.inline(values)) }
        }
        if title { try append(titleField) }
        else {
            let fields = retainedWritingFields(structure)
            for node in try logicalNodes(structure) {
                if whole.contains(node) { parts.append(.node(value: try modernVisibleValue(node, in: structure, document: document), kind: "block")) }
                else if !covered.contains(node) {
                    for name in ["content", "summary", "caption", "code", "expression"] {
                        let field = WritingField(node: node, name: name)
                        if fields[field] != nil { try append(field) }
                    }
                }
            }
        }
        // Empty/collapsed selections remain a successful inert empty copy.
        return try ModernClipboard(parts: parts.isEmpty ? [.inline([])] : parts)
    }
}
