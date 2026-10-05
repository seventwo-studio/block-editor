import Foundation

/// Clipboard parts retain the visible order of mixed whole-node and partial-text
/// selections. Their data is inert: paste never resolves or downloads assets.
public enum WritingClipboardPart: Codable, Equatable, Sendable {
    case inline([JSONValue])
    case node(value: JSONValue, kind: String)
}
public struct WritingClipboard: Codable, Equatable, Sendable {
    public let version: Int
    public let parts: [WritingClipboardPart]
    public init(parts: [WritingClipboardPart], version: Int = 1) {
        self.version = version; self.parts = parts
    }
    /// A single normalized rich field. Multiline block import is adapter-owned.
    public static func plainText(_ text: String) -> WritingClipboard {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return WritingClipboard(parts: [.inline([textNode(normalized)])])
    }
    /// Plain multiline import retains empty and trailing paragraphs. Labels are
    /// provisional clipboard data; paste always allocates fresh schema labels.
    public static func multilineText(_ text: String) throws -> WritingClipboard {
        guard text.utf16.count <= 1_000_000 else { throw EditorError.invalidRange }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count <= 10_000 else { throw EditorError.invalidRange }
        return try WritingClipboard(parts: lines.enumerated().map { index, line in
            let block = try Block.paragraph(id: "clipboard-\(index)", text: line)
            return .node(value: .object(block.fields), kind: "block")
        })
    }
    /// Markdown is opt-in. The same shared dialect used for documents produces
    /// inert schema data and is checked by the local paste policy at admission.
    public static func markdown(_ text: String) throws -> WritingClipboard {
        guard text.utf16.count <= 1_000_000 else { throw EditorError.invalidRange }
        var serial = 0
        let document = try Markdown.parse(text) { serial += 1; return "clipboard-\(serial)" }
        return WritingClipboard(parts: document.blocks.map { .node(value: .object($0.fields), kind: "block") })
    }
}
/// Applies only to new clipboard content, never to accepted remote history.
/// Hosts explicitly permit copied image/embed metadata; this does not authorize
/// fetching, uploading or inserting an asynchronously resolved asset.
public struct WritingPastePolicy: Codable, Equatable, Sendable {
    public let allowedBlockTypes: Set<String>?
    public let allowedMarkTypes: Set<String>?
    public let allowAssetMetadata: Bool
    public init(allowedBlockTypes: Set<String>? = nil, allowedMarkTypes: Set<String>? = nil, allowAssetMetadata: Bool = false) {
        self.allowedBlockTypes = allowedBlockTypes
        self.allowedMarkTypes = allowedMarkTypes
        self.allowAssetMetadata = allowAssetMetadata
    }
}

extension WritingClipboard {
    func validate(policy: WritingPastePolicy, hostBlockTypes: Set<String>?) throws {
        guard version == 1 else { throw EditorError.unsupportedVersion(version) }
        guard !parts.isEmpty, parts.count <= 100_000,
              try canonicalEncoder().encode(self).count <= 32_000_000 else { throw EditorError.invalidRange }
        for part in parts {
            switch part {
            case .inline(let values): try validateInline(values, policy: policy)
            case .node(let value, let name):
                guard let kind = NodeKind(rawValue: name) else { throw EditorError.invalidPath }
                try validateNode(value, kind: kind)
                try validateNodePolicy(value, kind: kind, policy: policy, hostBlockTypes: hostBlockTypes)
            }
        }
    }
    private func validateInline(_ values: [JSONValue], policy: WritingPastePolicy) throws {
        try Validation.inline(.array(values))
        for value in values {
            for mark in value["marks"]?.array ?? [] {
                guard let type = mark["type"]?.string,
                      policy.allowedMarkTypes?.contains(type) ?? true else { throw EditorError.invalidChange }
                if type == "link" { try validateClipboardURL(mark["href"]?.string) }
            }
        }
    }
    private func validateNodePolicy(_ value: JSONValue, kind: NodeKind, policy: WritingPastePolicy, hostBlockTypes: Set<String>?) throws {
        guard let fields = value.object else { throw EditorError.invalidPath }
        let authoredType: String
        switch kind {
        case .document, .column: throw EditorError.invalidPath
        case .block:
            guard let type = fields["type"]?.string,
                  ["paragraph", "heading", "quote", "callout", "list", "code", "image", "table", "embed", "math", "toggle", "divider"].contains(type) else { throw EditorError.invalidChange }
            authoredType = type
            if type == "image" || type == "embed" {
                guard policy.allowAssetMetadata else { throw EditorError.invalidChange }
                if type == "embed" { try validateClipboardURL(fields["url"]?.string) }
                else { try validateClipboardAssetURL(fields["src"]?.string) }
            }
        case .item: authoredType = "list"
        case .row, .cell: authoredType = "table"
        }
        guard policy.allowedBlockTypes?.contains(authoredType) ?? true,
              hostBlockTypes?.contains(authoredType) ?? true else { throw EditorError.restrictedBlock(authoredType) }
        for field in ["content", "summary", "caption"] {
            if let values = fields[field]?.array { try validateInline(values, policy: policy) }
        }
        for (name, childKind) in StructuralState.collectionFields(kind, fields) {
            for child in fields[name]?.array ?? [] {
                try validateNodePolicy(child, kind: childKind, policy: policy, hostBlockTypes: hostBlockTypes)
            }
        }
    }
}

/// Clipboard URLs have a deliberately narrower boundary than persisted host
/// document URLs. Tightening the global validator would reject old content.
func validateClipboardURL(_ text: String?) throws {
    guard let text, !text.isEmpty,
          !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
          let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme),
          (scheme == "mailto" ? !url.path.isEmpty : !(url.host ?? "").isEmpty) else { throw EditorError.invalidChange }
}
func validateClipboardAssetURL(_ text: String?) throws {
    guard let text, !text.isEmpty,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https", "asset", "content", "file", "blob"].contains(scheme) else { throw EditorError.invalidChange }
    if scheme == "http" || scheme == "https" { try validateClipboardURL(text) }
    else { guard !url.path.isEmpty else { throw EditorError.invalidChange } }
}

/// External normalization is explicit. Hosts decide whether to adopt the suggested
/// paragraph-capable authoring policy; this value never changes a live session.
public struct WritingImportResult: Codable, Equatable, Sendable {
    public let clipboard: WritingClipboard
    public let effectivePastePolicy: WritingPastePolicy
    public let suggestedHostBlockTypes: Set<String>?
    private enum CodingKeys: String, CodingKey { case clipboard, effectivePastePolicy, suggestedHostBlockTypes }
    private struct EncodedPolicy: Encodable {
        let allowedBlockTypes: [String]?
        let allowedMarkTypes: [String]?
        let allowAssetMetadata: Bool
    }
    public func encode(to encoder: any Encoder) throws {
        func ordered(_ values: Set<String>?) -> [String]? { values?.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clipboard, forKey: .clipboard)
        try values.encode(EncodedPolicy(allowedBlockTypes: ordered(effectivePastePolicy.allowedBlockTypes),
            allowedMarkTypes: ordered(effectivePastePolicy.allowedMarkTypes), allowAssetMetadata: effectivePastePolicy.allowAssetMetadata), forKey: .effectivePastePolicy)
        try values.encodeIfPresent(ordered(suggestedHostBlockTypes), forKey: .suggestedHostBlockTypes)
    }
}

extension WritingClipboard {
    /// Removes unsupported external formatting and unsafe active URLs, retaining
    /// visible content as paragraph fallback. Strict copy/paste APIs are unchanged.
    public func normalizeForImport(policy: WritingPastePolicy = WritingPastePolicy(), hostBlockTypes: Set<String>? = nil) throws -> WritingImportResult {
        guard version == 1 else { throw EditorError.unsupportedVersion(version) }
        guard !parts.isEmpty, parts.count <= 100_000 else { throw EditorError.invalidRange }
        // Bound unknown metadata before walking schema fields or encoding it.
        var pending: [(JSONValue, Int)] = parts.map { part in
            switch part { case .inline(let values): return (.array(values), 0)
            case .node(let value, _): return (value, 0) }
        }
        while let (value, depth) = pending.popLast() {
            guard depth <= 100 else { throw EditorError.invalidRange }
            if let object = value.object { pending.append(contentsOf: object.values.map { ($0, depth + 1) }) }
            else if let values = value.array { pending.append(contentsOf: values.map { ($0, depth + 1) }) }
        }
        guard try canonicalEncoder().encode(self).count <= 32_000_000 else { throw EditorError.invalidRange }
        let effective = WritingPastePolicy(allowedBlockTypes: policy.allowedBlockTypes.map { $0.union(["paragraph"]) },
            allowedMarkTypes: policy.allowedMarkTypes, allowAssetMetadata: policy.allowAssetMetadata)
        let host = hostBlockTypes.map { $0.union(["paragraph"]) }
        var normalizer = WritingImportNormalizer(policy: effective, hostBlockTypes: host)
        let normalized = try parts.map { part -> WritingClipboardPart in
            switch part {
            case .inline(let values): return .inline(normalizer.inline(values))
            case .node(let value, let name):
                guard let kind = NodeKind(rawValue: name) else { throw EditorError.invalidPath }
                if let node = normalizer.node(value, kind: kind) { return .node(value: node, kind: name) }
                let fields: [String: JSONValue] = ["id": .string(normalizer.label()), "type": .string("paragraph"),
                    "content": .array(normalizer.visible(value, kind: kind))]
                return .node(value: .object(fields), kind: "block")
            }
        }
        let clipboard = WritingClipboard(parts: normalized)
        try clipboard.validate(policy: effective, hostBlockTypes: host)
        return WritingImportResult(clipboard: clipboard, effectivePastePolicy: effective, suggestedHostBlockTypes: host)
    }
}

private struct WritingImportNormalizer {
    let policy: WritingPastePolicy
    let hostBlockTypes: Set<String>?
    private var serial = 0
    init(policy: WritingPastePolicy, hostBlockTypes: Set<String>?) { self.policy = policy; self.hostBlockTypes = hostBlockTypes }
    mutating func label() -> String { serial += 1; return "clipboard-import-\(serial)" }
    private func allowed(_ type: String) -> Bool {
        (policy.allowedBlockTypes?.contains(type) ?? true) && (hostBlockTypes?.contains(type) ?? true)
    }
    private func text(_ value: String) -> String { value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    func inline(_ values: [JSONValue]) -> [JSONValue] {
        values.compactMap { value in
            guard var fields = value.object else { return value.string.map { textNode(text($0)) } }
            let marks = (fields["marks"]?.array ?? []).filter { mark in
                guard let type = mark["type"]?.string, policy.allowedMarkTypes?.contains(type) ?? true,
                      (try? Validation.mark(mark)) != nil else { return false }
                return type != "link" || (try? validateClipboardURL(mark["href"]?.string)) != nil
            }
            if fields["type"] == .string("text"), let text = fields["text"]?.string {
                fields["text"] = .string(self.text(text))
                fields["marks"] = .array(marks)
            } else if fields["marks"] != nil { fields["marks"] = .array(marks) }
            let normalized = JSONValue.object(fields)
            if (try? Validation.inline(.array([normalized]))) != nil { return normalized }
            // Invalid references become their visible label, never an invented ID.
            let text = fields["text"]?.string ?? fields["label"]?.string ?? fields["expression"]?.string
                ?? fields["date"]?.string ?? fields["name"]?.string ?? ""
            return text.isEmpty ? nil : textNode(self.text(text), marks: marks)
        }
    }
    mutating func node(_ value: JSONValue, kind: NodeKind) -> JSONValue? {
        guard var fields = value.object else { return nil }
        let type: String
        switch kind {
        case .document, .column: return nil
        case .block:
            guard let name = fields["type"]?.string,
                  ["paragraph", "heading", "quote", "callout", "list", "code", "image", "table", "embed", "math", "toggle", "divider"].contains(name) else { return nil }
            type = name
        case .item: type = "list"
        case .row, .cell: type = "table"
        }
        guard allowed(type) else { return nil }
        if type == "image" || type == "embed" {
            guard policy.allowAssetMetadata else { return nil }
            if type == "image" { guard (try? validateClipboardAssetURL(fields["src"]?.string)) != nil else { return nil } }
            else {
                guard (try? validateClipboardURL(fields["url"]?.string)) != nil else { return nil }
                if fields["thumbnail"] != nil, (try? validateClipboardAssetURL(fields["thumbnail"]?.string)) == nil { fields.removeValue(forKey: "thumbnail") }
            }
        }
        fields["id"] = .string(label())
        for field in ["content", "summary", "caption"] {
            if let values = fields[field]?.array { fields[field] = .array(inline(values)) }
            else if let text = fields[field]?.string { fields[field] = .array([textNode(self.text(text))]) }
        }
        for (field, childKind) in StructuralState.collectionFields(kind, fields).sorted(by: { $0.key < $1.key }) {
            guard let children = fields[field] else { continue }
            guard let values = children.array else { return nil }
            var normalized: [JSONValue] = []
            for child in values {
                guard let child = node(child, kind: childKind) else { return nil }
                normalized.append(child)
            }
            fields[field] = .array(normalized)
        }
        let result = JSONValue.object(fields)
        guard (try? validateNode(result, kind: kind)) != nil else { return nil }
        return result
    }
    // Only schema-visible fields are imported as text; opaque metadata is inert
    // and is not rendered or guessed to be a URL or an additional child.
    func visible(_ value: JSONValue, kind: NodeKind) -> [JSONValue] {
        guard let fields = value.object else { return value.string.map { [textNode(text($0))] } ?? [] }
        func field(_ key: String) -> [JSONValue] {
            if let values = fields[key]?.array { return inline(values) }
            return fields[key]?.string.map { [textNode(text($0))] } ?? []
        }
        func joined(_ groups: [[JSONValue]], separator: String = "\n") -> [JSONValue] {
            groups.enumerated().flatMap { index, group in (index == 0 ? [] : [textNode(separator)]) + group }
        }
        switch kind {
        case .document, .column: return []
        case .item: return joined([field("content")] + (fields["children"]?.array ?? []).map { visible($0, kind: .item) })
        case .row: return joined((fields["cells"]?.array ?? []).map { visible($0, kind: .cell) }, separator: "\t")
        case .cell: return field("content")
        case .block:
            switch fields["type"]?.string {
            case "list": return joined((fields["items"]?.array ?? []).map { visible($0, kind: .item) })
            case "table": return joined((fields["rows"]?.array ?? []).map { visible($0, kind: .row) })
            case "toggle": return joined([field("summary")] + (fields["children"]?.array ?? []).map { visible($0, kind: .block) })
            case "code": return field("code")
            case "math": return field("expression")
            case "image": return joined([field("alt"), field("caption")].filter { !$0.isEmpty })
            case "embed":
                let title = field("title"), description = field("description")
                if !title.isEmpty || !description.isEmpty { return joined([title, description].filter { !$0.isEmpty }) }
                return (try? validateClipboardURL(fields["url"]?.string)) == nil ? [] : field("url")
            default:
                var groups = ["content", "summary", "caption", "text", "label", "title", "description", "alt", "code", "expression"].map(field).filter { !$0.isEmpty }
                for (name, childKind) in [("children", NodeKind.block), ("items", .item), ("rows", .row), ("cells", .cell)] {
                    groups += (fields[name]?.array ?? []).map { visible($0, kind: childKind) }
                }
                return joined(groups)
            }
        }
    }
}
