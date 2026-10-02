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
private func validateClipboardURL(_ text: String?) throws {
    guard let text, !text.isEmpty,
          !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
          let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme),
          (scheme == "mailto" ? !url.path.isEmpty : !(url.host ?? "").isEmpty) else { throw EditorError.invalidChange }
}
private func validateClipboardAssetURL(_ text: String?) throws {
    guard let text, !text.isEmpty,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          ["http", "https", "asset", "content", "file", "blob"].contains(scheme) else { throw EditorError.invalidChange }
    if scheme == "http" || scheme == "https" { try validateClipboardURL(text) }
    else { guard !url.path.isEmpty else { throw EditorError.invalidChange } }
}
