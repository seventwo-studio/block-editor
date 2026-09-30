import Foundation

/// Retains fields the current editor does not understand instead of silently dropping them.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> JSONValue? { object?[key] }

    /// Object keys and stable array element IDs, never positional array indices.
    public func value(at path: [String]) -> JSONValue? {
        guard let first = path.first else { return self }
        let child = object?[first] ?? array?.first { $0["id"]?.string == first }
        return child?.value(at: Array(path.dropFirst()))
    }

    func setting(_ path: [String], to value: JSONValue) throws -> JSONValue {
        guard let first = path.first else { return value }
        let rest = Array(path.dropFirst())
        if var fields = object {
            if rest.isEmpty { fields[first] = value }
            else {
                guard let child = fields[first] else { throw EditorError.invalidPath }
                fields[first] = try child.setting(rest, to: value)
            }
            return .object(fields)
        }
        if var elements = array, let index = elements.firstIndex(where: { $0["id"]?.string == first }) {
            elements[index] = try elements[index].setting(rest, to: value)
            return .array(elements)
        }
        throw EditorError.invalidPath
    }
}

public enum EditorError: Error, Equatable, Sendable {
    case invalidDocument(String), invalidPath, invalidRange, unsupportedVersion(Int)
    case differentDocument, conflictingChange, invalidChange, restrictedBlock(String)
}

public struct Block: Codable, Equatable, Sendable, Identifiable {
    public var fields: [String: JSONValue]
    public var id: String { fields["id"]?.string ?? "" }
    public var type: String { fields["type"]?.string ?? "" }
    public init(fields: [String: JSONValue]) throws {
        guard let id = fields["id"]?.string, !id.isEmpty,
              let type = fields["type"]?.string, !type.isEmpty else {
            throw EditorError.invalidDocument("Every block needs an ID and type")
        }
        self.fields = fields
    }
    public init(from decoder: any Decoder) throws {
        try self.init(fields: decoder.singleValueContainer().decode([String: JSONValue].self))
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(fields)
    }
    public static func paragraph(id: String, text: String = "") throws -> Block {
        try Block(fields: ["id": .string(id), "type": .string("paragraph"), "content": .array([textNode(text)])])
    }
    public func value(at path: [String]) -> JSONValue? { JSONValue.object(fields).value(at: path) }
    public var text: String { plainText(fields["content"]?.array ?? []) }
}

public func textNode(_ text: String, marks: [JSONValue] = []) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text), "marks": .array(marks)])
}

public func plainText(_ nodes: [JSONValue]) -> String {
    nodes.map { node in
        switch node["type"]?.string {
        case "text": return node["text"]?.string ?? ""
        case "mention", "entity-ref": return node["label"]?.string ?? ""
        case "emoji": return ":\(node["name"]?.string ?? ""):"
        case "date": return node["date"]?.string ?? ""
        case "inline-math": return node["expression"]?.string ?? ""
        default: return ""
        }
    }.joined()
}

public struct Document: Codable, Equatable, Sendable {
    public var blocks: [Block]
    public init(blocks: [Block]) throws {
        guard blocks.count <= 10_000 else { throw EditorError.invalidDocument("Too many blocks") }
        var ids = Set<String>()
        func inspect(_ value: JSONValue, depth: Int) throws {
            guard depth <= 100 else { throw EditorError.invalidDocument("Document nesting exceeds 100") }
            if let fields = value.object {
                for child in fields.values { try inspect(child, depth: depth + 1) }
            } else if let elements = value.array {
                for child in elements { try inspect(child, depth: depth + 1) }
            }
        }
        for block in blocks {
            guard !block.id.isEmpty, ids.insert(block.id).inserted else { throw EditorError.invalidDocument("Duplicate or empty root block ID") }
            try Validation.block(block)
            try inspect(.object(block.fields), depth: 0)
        }
        self.blocks = blocks
    }
    public init(json: Data) throws {
        guard json.count <= 32_000_000 else { throw EditorError.invalidDocument("Document exceeds 32 MB") }
        try self.init(blocks: JSONDecoder().decode([Block].self, from: json))
    }
    private enum CodingKeys: CodingKey { case blocks }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(blocks: container.decode([Block].self, forKey: .blocks))
    }
    public func json() throws -> Data { try canonicalEncoder().encode(blocks) }
}

func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
}
