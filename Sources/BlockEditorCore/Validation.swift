import Foundation

/// Validates known document shapes while retaining unrecognized block extensions.
/// Host authorization and media ownership are deliberately outside this validator.
enum Validation {
    static func block(_ block: Block, depth: Int = 0) throws {
        guard depth < 100 else { throw EditorError.invalidDocument("Too deeply nested") }
        let f = block.fields
        switch block.type {
        case "paragraph", "quote": try inline(f["content"])
        case "heading":
            guard [.number(1), .number(2), .number(3)].contains(f["level"]) else { throw invalid("heading level") }
            try inline(f["content"])
        case "list":
            guard ["ordered", "unordered", "todo"].contains(f["style"]?.string ?? ""), let items = f["items"]?.array else { throw invalid("list") }
            func item(_ value: JSONValue, depth: Int) throws {
                guard depth < 100, let id = value["id"]?.string, !id.isEmpty else { throw invalid("list item") }
                try inline(value["content"])
                if let checked = value["checked"], checked != .bool(true), checked != .bool(false) { throw invalid("checked") }
                if let children = value["children"] {
                    guard let children = children.array else { throw invalid("children") }
                    for child in children { try item(child, depth: depth + 1) }
                }
            }
            for value in items { try item(value, depth: depth + 1) }
        case "code": try string(f["code"], name: "code", max: 100_000); try string(f["language"], name: "language", max: 50, optional: true)
        case "callout":
            guard ["info", "warning", "error", "success"].contains(f["variant"]?.string ?? "") else { throw invalid("callout variant") }
            try inline(f["content"])
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
            guard let rows = f["rows"]?.array else { throw invalid("table rows") }
            for row in rows {
                guard let id = row["id"]?.string, !id.isEmpty, let cells = row["cells"]?.array else { throw invalid("table row") }
                for cell in cells {
                    guard let id = cell["id"]?.string, !id.isEmpty else { throw invalid("table cell") }
                    try inline(cell["content"])
                }
            }
        case "embed": try url(f["url"])
        case "math": try string(f["expression"], name: "math", min: 1, max: 10_000)
        case "toggle":
            try inline(f["summary"])
            if let value = f["children"] {
                guard let children = value.array else { throw invalid("toggle children") }
                for child in children { try self.block(Block(fields: child.object ?? [:]), depth: depth + 1) }
            }
        default: break // Unknown blocks are preserved, not implicitly made authorable.
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
            case "date": try string(node["date"], name: "date", min: 1)
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
    private static func invalid(_ field: String) -> EditorError { .invalidDocument("Invalid \(field)") }
}
