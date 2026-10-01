#if canImport(SwiftUI)
import BlockEditorCore
import Foundation

/// SwiftUI state must follow origin identity, rather than a reusable sibling label.
@MainActor func nativeNodeIdentity(model: EditorModel, address: NodeAddress) -> NodeID {
    (try? model.session.node(at: address)) ?? .baseline(blockID: address.blockID, path: address.path)
}

@MainActor struct NativeFieldTarget {
    let address: NodeAddress
    let identity: NodeID?
    init(session: EditorSession, address: NodeAddress) throws {
        self.address = address
        identity = session.collaborationVersion == 2 ? try session.node(at: address) : nil
    }
    func set(in session: EditorSession, field: String, value: JSONValue) throws {
        if let identity { try session.setNodeField(identity, path: [field], value: value) }
        else { try session.setField(blockID: address.blockID, path: address.path + [field], value: value) }
    }
}

/// Asset-backed blocks are supplied by the host, rather than created from URLs.
public enum NativeBlockInsertion: String, CaseIterable, Identifiable, Sendable {
    case paragraph, heading, quote, callout, unorderedList, orderedList, checklist, code, toggle, table, divider
    public var id: String { rawValue }
    public var blockType: String {
        switch self {
        case .unorderedList, .orderedList, .checklist: "list"
        default: rawValue
        }
    }
    public var title: String {
        switch self {
        case .unorderedList: "Bulleted list"
        case .orderedList: "Numbered list"
        case .checklist: "Checklist"
        default: rawValue.capitalized
        }
    }
    public func isAllowed(in session: EditorSession) -> Bool {
        isAllowed(allowedBlockTypes: session.allowedBlockTypes)
    }
    public func isAllowed(allowedBlockTypes: Set<String>?) -> Bool {
        blockType == "paragraph" || allowedBlockTypes?.contains(blockType) != false
    }
    public func block(id: String = UUID().uuidString) throws -> Block {
        var fields: [String: JSONValue] = ["id": .string(id), "type": .string(blockType)]
        switch self {
        case .paragraph, .quote: fields["content"] = .array([])
        case .heading: fields["content"] = .array([]); fields["level"] = .number(1)
        case .callout: fields["content"] = .array([]); fields["variant"] = .string("info")
        case .unorderedList, .orderedList, .checklist:
            fields["style"] = .string(self == .checklist ? "todo" : self == .orderedList ? "ordered" : "unordered")
            fields["items"] = .array([.object(["id": .string(UUID().uuidString), "content": .array([]), "checked": .bool(false)])])
        case .code: fields["code"] = .string("")
        case .toggle: fields["summary"] = .array([]); fields["children"] = .array([])
        case .table:
            fields["rows"] = .array([.object(["id": .string(UUID().uuidString), "cells": .array((0..<2).map { _ in
                .object(["id": .string(UUID().uuidString), "content": .array([])])
            })])])
        case .divider: break
        }
        return try Block(fields: fields)
    }
}

/// Capture before committing native composition, which can release queued moves.
@MainActor struct NativeNodeTarget {
    let identity: NodeID?
    let address: NodeAddress
    init(session: EditorSession, address: NodeAddress) throws {
        guard session.collaborationVersion == 2 || address.path.isEmpty else { throw EditorError.unsupportedVersion(2) }
        self.address = address
        identity = session.collaborationVersion == 2 ? try session.node(at: address) : nil
    }
    func collection(in session: EditorSession) throws -> NodeCollection {
        guard let identity else { return .root }
        let live = try session.address(of: identity)
        guard let field = live.path.dropLast().last else { return .root }
        let parent = try session.node(at: NodeAddress(live.blockID, path: Array(live.path.dropLast(2))))
        return NodeCollection(owner: parent, field: field)
    }
    func canMove(in session: EditorSession, down: Bool) -> Bool {
        if let identity {
            guard let collection = try? collection(in: session), let siblings = try? session.nodes(in: collection),
                  let index = siblings.firstIndex(of: identity) else { return false }
            return down ? index < siblings.count - 1 : index > 0
        }
        guard let blocks = try? session.document.blocks, let index = blocks.firstIndex(where: { $0.id == address.blockID }) else { return false }
        return down ? index < blocks.count - 1 : index > 0
    }
    func canOutdent(in session: EditorSession) -> Bool {
        (try? collection(in: session).field) == "children"
    }
    func move(in session: EditorSession, down: Bool) throws {
        if let identity {
            let collection = try collection(in: session), siblings = try session.nodes(in: collection)
            guard let index = siblings.firstIndex(of: identity), down ? index < siblings.count - 1 : index > 0 else { throw EditorError.invalidPath }
            let after = down ? siblings[index + 1] : index > 1 ? siblings[index - 2] : nil
            try session.moveNode(identity, into: collection, after: after)
        } else {
            let blocks = try session.document.blocks
            guard let index = blocks.firstIndex(where: { $0.id == address.blockID }), down ? index < blocks.count - 1 : index > 0 else { throw EditorError.invalidPath }
            try session.move(blockID: address.blockID, after: down ? blocks[index + 1].id : index > 1 ? blocks[index - 2].id : nil)
        }
    }
    func delete(in session: EditorSession) throws {
        if let identity { try session.deleteNode(identity) }
        else { try session.delete(blockID: address.blockID) }
    }
}

@MainActor struct NativeFormattingSelection {
    let start: TextPosition
    let end: TextPosition
    init(session: EditorSession, address: TextAddress, range: NSRange) throws {
        guard range.location != NSNotFound, range.length > 0 else { throw EditorError.invalidRange }
        start = try session.position(at: address, offset: range.location)
        end = try session.position(at: address, offset: NSMaxRange(range))
    }
    func apply(in session: EditorSession, type: String, remove: Bool) throws {
        let lower = try session.offset(of: start), upper = try session.offset(of: end)
        try session.format(at: start.address, range: min(lower, upper)..<max(lower, upper),
                           markType: type, mark: remove ? nil : .object(["type": .string(type)]))
    }
    func toggle(in session: EditorSession, type: String) throws {
        var address = start.address
        if let identity = address.identity {
            let live = try session.address(of: identity)
            address = TextAddress(live.blockID, path: live.path + [address.path.last ?? "content"], identity: identity)
        }
        let nodes = try session.document.blocks.first { $0.id == address.blockID }?.value(at: address.path)?.array ?? []
        let lower = try session.offset(of: start), upper = try session.offset(of: end)
        let range = min(lower, upper)..<max(lower, upper)
        var offset = 0, selected: [JSONValue] = []
        for node in nodes {
            let end = offset + plainText([node]).utf16.count
            if end > range.lowerBound, offset < range.upperBound, node["type"]?.string == "text" { selected.append(node) }
            offset = end
        }
        let remove = !selected.isEmpty && selected.allSatisfy { ($0["marks"]?.array ?? []).contains { $0["type"]?.string == type } }
        try apply(in: session, type: type, remove: remove)
    }
}
#endif
