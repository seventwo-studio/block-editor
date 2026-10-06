import Foundation

public struct ModernInsertionDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let blockType: String
    public let requiresHost: Bool
}
/// One vocabulary and one ordering across slash menus, keyboard and touch.
public enum ModernInsertionCatalog {
    public static let descriptors: [ModernInsertionDescriptor] = [
        .init(id: "paragraph", title: "Text", description: "Start a paragraph", blockType: "paragraph", requiresHost: false),
        .init(id: "heading1", title: "Heading 1", description: "A main section", blockType: "heading", requiresHost: false),
        .init(id: "heading2", title: "Heading 2", description: "A subsection", blockType: "heading", requiresHost: false),
        .init(id: "heading3", title: "Heading 3", description: "A small heading", blockType: "heading", requiresHost: false),
        .init(id: "unordered", title: "Bulleted list", description: "An unordered sequence", blockType: "list", requiresHost: false),
        .init(id: "ordered", title: "Numbered list", description: "An ordered sequence", blockType: "list", requiresHost: false),
        .init(id: "todo", title: "Checklist", description: "Track completed items", blockType: "list", requiresHost: false),
        .init(id: "toggle", title: "Toggle", description: "A disclosure with nested writing", blockType: "toggle", requiresHost: false),
        .init(id: "quote", title: "Quote", description: "Set apart a quotation", blockType: "quote", requiresHost: false),
        .init(id: "callout", title: "Callout", description: "Highlight useful information", blockType: "callout", requiresHost: false),
        .init(id: "code", title: "Code", description: "Literal text and whitespace", blockType: "code", requiresHost: false),
        .init(id: "table", title: "Simple table", description: "Rows and columns of text", blockType: "table", requiresHost: false),
        .init(id: "divider", title: "Divider", description: "Separate sections", blockType: "divider", requiresHost: false),
        .init(id: "columns", title: "Two columns", description: "Two ordered writing containers", blockType: "columns", requiresHost: false),
        .init(id: "image", title: "Image", description: "Choose an image through the application", blockType: "image", requiresHost: true),
        .init(id: "file", title: "File", description: "Attach a file through the application", blockType: "file", requiresHost: true),
        .init(id: "embed", title: "Link preview", description: "Ask the application to resolve a URL", blockType: "embed", requiresHost: true)
    ]
    public static func search(_ query: String) -> [ModernInsertionDescriptor] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        return descriptors.filter { descriptor in words.allSatisfy { (descriptor.title + " " + descriptor.description).lowercased().contains($0) } }
    }
    public static func block(_ descriptorID: String, id: String, childIDs: [String] = []) throws -> Block {
        guard let descriptor = descriptors.first(where: { $0.id == descriptorID }), !descriptor.requiresHost,
              descriptor.blockType != "columns", validToken(id) else { throw ModernSessionError.unavailable("hostInsertionRequired") }
        var fields: [String: JSONValue] = ["id": .string(id), "type": .string(descriptor.blockType)]
        switch descriptor.blockType {
        case "paragraph", "heading", "quote", "callout", "toggle":
            fields["content"] = .array([])
            if descriptor.blockType == "heading" { fields["level"] = .number(Double(Int(descriptorID.suffix(1)) ?? 1)) }
            if descriptor.blockType == "callout" { fields["variant"] = .string("info") }
            if descriptor.blockType == "toggle" { fields.removeValue(forKey: "content"); fields["summary"] = .array([]); fields["children"] = .array([]) }
        case "list":
            guard childIDs.count == 1, validToken(childIDs[0]) else { throw EditorError.invalidChange }
            fields["style"] = .string(descriptorID)
            fields["items"] = .array([.object(["id": .string(childIDs[0]), "content": .array([]), "checked": .bool(false)])])
        case "code": fields["code"] = .string("")
        case "table":
            guard childIDs.count == 6, Set(childIDs).count == 6, childIDs.allSatisfy({ validToken($0) }) else { throw EditorError.invalidChange }
            fields["rows"] = .array((0..<2).map { row in .object(["id": .string(childIDs[row * 3]), "cells": .array((1...2).map { col in
                .object(["id": .string(childIDs[row * 3 + col]), "content": .array([]), "header": .bool(row == 0)])
            })]) })
        case "divider": break
        default: throw EditorError.invalidChange
        }
        let block = try Block(fields: fields)
        try validateModernAuthoredBlock(.object(fields))
        return block
    }
    public static func value(_ descriptorID: String, id: String, childIDs: [String] = []) throws -> JSONValue {
        if descriptorID == "columns" {
            guard validToken(id), childIDs.count == 2, Set(childIDs).count == 2, childIDs.allSatisfy({ validToken($0) }) else { throw EditorError.invalidChange }
            return .object(["id": .string(id), "type": .string("columns"), "splitBasisPoints": .number(5000),
                            "columns": .array(childIDs.map { .object(["id": .string($0), "children": .array([])]) })])
        }
        return try .object(block(descriptorID, id: id, childIDs: childIDs).fields)
    }
}

public struct ModernCommandAvailability: Codable, Equatable, Sendable {
    public let command: String
    public let available: Bool
    public let reason: String?
}
extension ModernSession {
    public static let authorCommands = ["replaceText", "replaceTitle", "setAppearance", "format", "insertBlock", "duplicate", "paste", "move", "delete", "createColumns", "removeColumns", "resizeColumns", "convertBlock", "softBreak", "splitBlock", "mergeBlocks", "listStructure", "typingShortcut", "tableStructure", "mediaProperties", "codeProperties", "setSemanticColor", "setLink", "completeAsyncBlock", "undo", "redo"]
    public func availability(for command: String) -> ModernCommandAvailability {
        let reason: String?
        if !Self.authorCommands.contains(command) { reason = "unsupportedCommand" }
        else if allowedCommands?.contains(command) == false { reason = "hostPolicy" }
        else if mergeRecovery != nil { reason = "pendingRecovery" }
        else if isComposing { reason = "compositionActive" }
        else if command == "undo" && !canUndo { reason = "emptyHistory" }
        else if command == "redo" && !canRedo { reason = "emptyHistory" }
        else { reason = nil }
        return ModernCommandAvailability(command: command, available: reason == nil, reason: reason)
    }
}

extension ModernSession {
    /// Local author restrictions are distinct from untrusted clipboard import.
    /// Existing opaque nodes, asset identifiers and metadata can be duplicated
    /// verbatim while only known content fields are checked against host policy.
    func validateLocalContentPolicy(_ value: JSONValue, kind: NodeKind = .block) throws {
        guard let fields = value.object else { throw EditorError.invalidPath }
        let type = kind == .block ? fields["type"]?.string : kind == .item ? "list" : kind == .column ? "columns" : "table"
        if let type, allowedBlockTypes?.contains(type) == false { throw ModernSessionError.unavailable("hostBlockPolicy") }
        for name in ["content", "summary", "caption"] {
            for atom in fields[name]?.array ?? [] {
                for mark in atom["marks"]?.array ?? [] {
                    if let name = mark["type"]?.string, allowedMarkTypes?.contains(name) == false { throw ModernSessionError.unavailable("hostMarkPolicy") }
                }
            }
        }
        for (name, childKind) in StructuralState.collectionFields(kind, fields, modern: true) {
            for child in fields[name]?.array ?? [] { try validateLocalContentPolicy(child, kind: childKind) }
        }
    }
}
