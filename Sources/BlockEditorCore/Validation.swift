import Foundation

/// Validates known document shapes while retaining unrecognized block extensions.
/// Host authorization and media ownership are deliberately outside this validator.
enum Validation {
    static func block(_ block: Block, depth: Int = 0) throws {
        var pending = [(block, depth)]
        while let (next, level) = pending.popLast() {
            try inspectBlock(next, depth: level, pending: &pending)
        }
    }
    private static func inspectBlock(_ block: Block, depth: Int, pending: inout [(Block, Int)]) throws {
        guard depth < 100 else { throw EditorError.invalidDocument("Too deeply nested") }
        let f = block.fields
        switch block.type {
        case "paragraph", "quote": try inline(f["content"])
        case "heading":
            guard [.number(1), .number(2), .number(3)].contains(f["level"]) else { throw invalid("heading level") }
            try inline(f["content"])
        case "list":
            guard ["ordered", "unordered", "todo"].contains(f["style"]?.string ?? ""), let items = f["items"]?.array else { throw invalid("list") }
            var pendingItems = items.reversed().map { ($0, depth + 1) }
            try uniqueIDs(items)
            while let (value, itemDepth) = pendingItems.popLast() {
                guard itemDepth < 100, let id = value["id"]?.string, !id.isEmpty else { throw invalid("list item") }
                try inline(value["content"])
                if let checked = value["checked"], checked != .bool(true), checked != .bool(false) { throw invalid("checked") }
                if let children = value["children"] {
                    guard let children = children.array else { throw invalid("children") }
                    try uniqueIDs(children)
                    pendingItems.append(contentsOf: children.reversed().map { ($0, itemDepth + 1) })
                }
            }
        case "code": try string(f["code"], name: "code", max: 100_000); try string(f["language"], name: "language", max: 50, optional: true)
        case "callout":
            guard ["info", "warning", "error", "success"].contains(f["variant"]?.string ?? "") else { throw invalid("callout variant") }
            try inline(f["content"])
            try string(f["icon"], name: "callout icon", optional: true)
            try string(f["color"], name: "callout color", optional: true)
            if let color = f["color"]?.string, color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) == nil { throw invalid("callout color") }
        case "image":
            try string(f["src"], name: "image source", min: 1)
            try string(f["alt"], name: "alt", optional: true); try inline(f["caption"])
            for key in ["width", "height"] {
                if let value = f[key] {
                    guard case .number(let n) = value, n.isFinite, n > 0, n.rounded() == n else { throw invalid(key) }
                }
            }
        case "table":
            if let widths = f["columnWidths"] {
                guard let widths = widths.array, widths.allSatisfy({ if case .number(let n) = $0 { return n.isFinite }; return false }) else { throw invalid("column widths") }
            }
            guard let rows = f["rows"]?.array else { throw invalid("table rows") }
            try uniqueIDs(rows)
            for row in rows {
                guard let id = row["id"]?.string, !id.isEmpty, let cells = row["cells"]?.array else { throw invalid("table row") }
                try uniqueIDs(cells)
                for cell in cells {
                    guard let id = cell["id"]?.string, !id.isEmpty else { throw invalid("table cell") }
                    try inline(cell["content"])
                    if let header = cell["header"], header != .bool(true), header != .bool(false) { throw invalid("cell header") }
                }
            }
        case "embed":
            try url(f["url"])
            for key in ["title", "description", "thumbnail"] { try string(f[key], name: "embed \(key)", optional: true) }
        case "math": try string(f["expression"], name: "math", min: 1, max: 10_000)
        case "toggle":
            try inline(f["summary"])
            if let value = f["children"] {
                guard let children = value.array else { throw invalid("toggle children") }
                try uniqueIDs(children)
                for child in children.reversed() { pending.append((try Block(fields: child.object ?? [:]), depth + 1)) }
            }
        default: break // Unknown blocks are preserved, not implicitly made authorable.
        }
    }
    /// Stable paths scope identities to each containing array. Extension metadata
    /// may have unrelated IDs, and separate containers may reuse a child ID.
    private static func uniqueIDs(_ values: [JSONValue]) throws {
        var ids = Set<String>()
        for value in values {
            guard let id = value["id"]?.string, !id.isEmpty, ids.insert(id).inserted else { throw invalid("duplicate or empty sibling ID") }
        }
    }
    static func inline(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let nodes = value.array else { throw invalid("inline content") }
        for node in nodes {
            switch node["type"]?.string {
            case "text":
                try string(node["text"], name: "text")
                if let value = node["marks"] {
                    guard let marks = value.array else { throw invalid("marks") }
                    for mark in marks { try self.mark(mark) }
                }
            case "mention", "entity-ref":
                try string(node["entityId"], name: "entity ID", min: 1)
                try string(node["entityType"], name: "entity type", min: 1)
                try string(node["label"], name: "label")
                if node["type"]?.string == "mention", !["user", "team", "channel"].contains(node["entityType"]?.string ?? "") { throw invalid("mention") }
            case "date":
                try date(node["date"])
                if let format = node["format"], !["date", "datetime", "relative"].contains(format.string ?? "") { throw invalid("date format") }
            case "emoji": try string(node["name"], name: "emoji", min: 1, max: 64)
            case "inline-math": try string(node["expression"], name: "inline math", min: 1, max: 10_000)
            default: throw invalid("inline node type")
            }
        }
    }
    static func mark(_ mark: JSONValue) throws {
        guard let type = mark["type"]?.string, ["bold", "italic", "strikethrough", "code", "link"].contains(type) else { throw invalid("mark") }
        if type == "link" { try url(mark["href"]) }
    }
    private static func string(_ value: JSONValue?, name: String, min: Int = 0, max: Int = Int.max, optional: Bool = false) throws {
        if optional, value == nil { return }
        guard let text = value?.string, text.utf16.count >= min, text.utf16.count <= max else { throw invalid(name) }
    }
    private static func url(_ value: JSONValue?) throws {
        guard let text = value?.string, URL(string: text)?.scheme != nil else { throw invalid("URL") }
    }
    private static func date(_ value: JSONValue?) throws {
        guard let text = value?.string,
              text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\.[0-9]+)?)?Z$"#, options: .regularExpression) != nil else { throw invalid("date") }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { throw invalid("date") }
        let leap = parts[0] % 4 == 0 && (parts[0] % 100 != 0 || parts[0] % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[parts[1] - 1]).contains(parts[2]) else { throw invalid("date") }
    }
    private static func invalid(_ field: String) -> EditorError { .invalidDocument("Invalid \(field)") }
}
