import Foundation

/// Mirrors the existing editor's deliberately limited Markdown dialect.
/// Markdown is an interchange projection, not a lossless document archive.
public enum Markdown {
    public static func serialize(_ document: Document) -> String {
        document.blocks.map(render).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func render(_ block: Block) -> String {
        let f = block.fields
        let text = plainText(f["content"]?.array ?? [])
        func quote(_ text: String) -> String {
            text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        }
        switch block.type {
        case "paragraph": return text
        case "heading":
            let level: Int = if case .number(let n) = f["level"] { Int(min(3, max(1, n))) } else { 1 }
            return String(repeating: "#", count: level) + " " + text
        case "list":
            return (f["items"]?.array ?? []).enumerated().map { index, item in
                let prefix = f["style"]?.string == "ordered" ? "\(index + 1). " :
                    f["style"]?.string == "todo" ? (item["checked"] == .bool(true) ? "- [x] " : "- [ ] ") : "- "
                return prefix + plainText(item["content"]?.array ?? [])
            }.joined(separator: "\n")
        case "code": return "```\(f["language"]?.string ?? "")\n\(f["code"]?.string ?? "")\n```"
        case "quote": return quote(text)
        case "callout": return "> [!\(f["variant"]?.string ?? "info")]\n" + quote(text)
        case "divider": return "---"
        case "image": return "![\(f["alt"]?.string ?? "")](\(f["src"]?.string ?? ""))"
        case "embed": return f["url"]?.string ?? ""
        case "math": return "$$\n\(f["expression"]?.string ?? "")\n$$"
        case "toggle":
            let children = (f["children"]?.array ?? []).compactMap { try? Block(fields: $0.object ?? [:]) }
            return "<details>\n<summary>\(plainText(f["summary"]?.array ?? []))</summary>\n\n" + children.map(render).joined(separator: "\n\n") + "\n</details>"
        case "table":
            let rows = (f["rows"]?.array ?? []).map { row in
                (row["cells"]?.array ?? []).map { plainText($0["content"]?.array ?? []) }
            }
            guard let first = rows.first else { return "" }
            func row(_ values: [String]) -> String { "| " + values.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
            return ([row(first), row(Array(repeating: "---", count: first.count))] + rows.dropFirst().map(row)).joined(separator: "\n")
        default: return ""
        }
    }

    public static func parse(_ markdown: String, makeID: () -> String) throws -> Document {
        guard markdown.utf8.count <= 32_000_000 else { throw EditorError.invalidDocument("Markdown exceeds 32 MB") }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], i = 0
        func match(_ pattern: String, _ line: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (0..<result.numberOfRanges).map { Range(result.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
        }
        func content(_ text: String) -> JSONValue { .array(text.isEmpty ? [] : [textNode(text)]) }
        func add(_ type: String, _ fields: [String: JSONValue] = [:]) throws {
            var f = fields; f["id"] = .string(makeID()); f["type"] = .string(type)
            blocks.append(try Block(fields: f))
        }
        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
            var cells = [""], escaped = false
            for char in text {
                if char == "|", !escaped { cells.append("") }
                else { cells[cells.count - 1].append(char) }
                escaped = char == "\\"
            }
            return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        }
        func tableStart(_ index: Int) -> Bool {
            index + 1 < lines.count && match(#"^\|.*\|$"#, lines[index].trimmingCharacters(in: .whitespaces)) != nil &&
                match(#"^\|.*\|$"#, lines[index + 1].trimmingCharacters(in: .whitespaces)) != nil &&
                cells(lines[index + 1]).allSatisfy { match(#"^:?-{3,}:?$"#, $0) != nil }
        }
        let todo = #"^[-*]\s+\[([ xX])\]\s+(.*)$"#
        let bullet = #"^[-*]\s+(.*)$"#, ordered = #"^\d+\.\s+(.*)$"#
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if let fence = match(#"^```(\S*)\s*$"#, line) {
                i += 1; var body: [String] = []
                while i < lines.count, match(#"^```\s*$"#, lines[i]) == nil { body.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                try add("code", ["language": .string(fence[1]), "code": .string(body.joined(separator: "\n"))]); continue
            }
            if trimmed == "$$" {
                i += 1; var body: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "$$" { body.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                try add("math", ["expression": .string(body.joined(separator: "\n"))]); continue
            }
            if match(#"^---+$"#, trimmed) != nil { try add("divider"); i += 1; continue }
            if let heading = match(#"^(#{1,3})\s+(.*)$"#, line) {
                try add("heading", ["level": .number(Double(heading[1].count)), "content": content(heading[2])]); i += 1; continue
            }
            if tableStart(i) {
                var rows = [cells(lines[i])]; i += 2
                while i < lines.count, match(#"^\|.*\|$"#, lines[i].trimmingCharacters(in: .whitespaces)) != nil { rows.append(cells(lines[i])); i += 1 }
                let width = max(1, rows.map(\.count).max() ?? 1)
                let values: [JSONValue] = rows.enumerated().map { index, row in
                    .object(["id": .string(makeID()), "cells": .array((0..<width).map { column in
                        .object(["id": .string(makeID()), "content": content(column < row.count ? row[column] : ""), "header": .bool(index == 0)])
                    })])
                }
                try add("table", ["rows": .array(values)]); continue
            }
            if line.hasPrefix(">") {
                let callout = match(#"^>\s*\[!(\w+)\]\s*$"#, line)
                if callout != nil { i += 1 }
                var body: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    body.append(match(#"^>\s?(.*)$"#, lines[i])?[1] ?? ""); i += 1
                }
                var fields = ["content": content(body.joined(separator: "\n"))]
                if let callout {
                    let variant = callout[1].lowercased()
                    fields["variant"] = .string(["info", "warning", "error", "success"].contains(variant) ? variant : "info")
                    fields["icon"] = .string("lightbulb")
                }
                try add(callout == nil ? "quote" : "callout", fields); continue
            }
            let style = match(todo, line) != nil ? "todo" : match(bullet, line) != nil ? "unordered" : match(ordered, line) != nil ? "ordered" : nil
            if let style {
                let pattern = style == "todo" ? todo : style == "ordered" ? ordered : bullet
                var items: [JSONValue] = []
                while i < lines.count, let m = match(pattern, lines[i]) {
                    if style == "unordered", match(todo, lines[i]) != nil { break }
                    var fields: [String: JSONValue] = ["id": .string(makeID()), "content": content(m[style == "todo" ? 2 : 1]), "children": .array([])]
                    if style == "todo" { fields["checked"] = .bool(m[1].lowercased() == "x") }
                    items.append(.object(fields)); i += 1
                }
                try add("list", ["style": .string(style), "items": .array(items)]); continue
            }
            if let image = match(#"^!\[([^\]]*)\]\(([^)]+)\)\s*$"#, line) {
                try add("image", ["src": .string(image[2]), "alt": .string(image[1]), "caption": .array([])]); i += 1; continue
            }
            var body = [line]; i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty || tableStart(i) ||
                    match(#"^(```|\$\$\s*$|---+\s*$|#{1,3}\s|[-*]\s|\d+\.\s|>|!\[)"#, next) != nil { break }
                body.append(next); i += 1
            }
            try add("paragraph", ["content": content(body.joined(separator: "\n"))])
        }
        if blocks.isEmpty { try add("paragraph", ["content": .array([])]) }
        return try Document(blocks: blocks)
    }
}
