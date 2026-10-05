import Foundation

/// A document ID is scoped to its containing array. This identity additionally
/// records its origin, so moving a node never retargets another container's ID.
public enum NodeID: Codable, Hashable, Sendable {
    case document(documentID: String)
    case baseline(blockID: String, path: [String])
    case inserted(creation: ElementID, path: [String])

    var key: String { String(decoding: (try? canonicalEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    func textAddress(_ field: String) -> TextAddress {
        switch self {
        case .document: return TextAddress("", path: [field], identity: self)
        case .baseline(let blockID, let path): return TextAddress(blockID, path: path + [field], identity: self)
        case .inserted(let creation, let path):
            return TextAddress("@\(creation.change.actor)/\(creation.change.counter)/\(creation.index)", path: path + [field], identity: self)
        }
    }
}

/// A live path is for lookup only. Store a NodeID when an operation must follow a move.
public struct NodeAddress: Codable, Equatable, Sendable {
    public let blockID: String
    public let path: [String]
    public init(_ blockID: String, path: [String] = []) { self.blockID = blockID; self.path = path }
}

public struct NodeCollection: Codable, Hashable, Sendable {
    public let owner: NodeID?
    public let field: String
    public init(owner: NodeID, field: String) { self.owner = owner; self.field = field }
    private init() { owner = nil; field = "blocks" }
    public static let root = Self()
}

public enum NodePlacementID: Codable, Hashable, Comparable, Sendable {
    case initial(NodeID)
    /// A protocol-4 derived paragraph placement, distinct from birth placement.
    case role(owner: NodeID, node: NodeID)
    /// A protocol-7 flattened child anchor retained across layout Undo/Redo.
    indirect case columnRoute(layout: NodeID, slot: ElementID, node: NodeID)
    case edit(ElementID)
    public static func < (lhs: Self, rhs: Self) -> Bool {
        func tier(_ value: Self) -> Int {
            switch value { case .initial: return 0; case .role: return 1; case .columnRoute: return 2; case .edit: return 3 }
        }
        if tier(lhs) != tier(rhs) { return tier(lhs) < tier(rhs) }
        switch (lhs, rhs) {
        case (.initial(let a), .initial(let b)): return a.key.utf8.lexicographicallyPrecedes(b.key.utf8)
        case (.role(let ownerA, let nodeA), .role(let ownerB, let nodeB)):
            return ownerA.key == ownerB.key ? nodeA.key.utf8.lexicographicallyPrecedes(nodeB.key.utf8) : ownerA.key.utf8.lexicographicallyPrecedes(ownerB.key.utf8)
        case (.columnRoute(let layoutA, let slotA, let nodeA), .columnRoute(let layoutB, let slotB, let nodeB)):
            if slotA != slotB { return slotA < slotB }
            return layoutA.key == layoutB.key ? nodeA.key.utf8.lexicographicallyPrecedes(nodeB.key.utf8) : layoutA.key.utf8.lexicographicallyPrecedes(layoutB.key.utf8)
        case (.edit(let a), .edit(let b)): return a < b
        default: return false
        }
    }
}

enum NodeKind: String { case document, block, column, item, row, cell }

struct StructuralState {
    struct Node {
        let identity: NodeID
        var kind: NodeKind
        let birthKind: NodeKind
        var fields: [String: JSONValue]
        var collections: Set<String>
        let birthActive: Bool
        var label: String { fields["id"]?.string ?? "" }
    }
    struct Placement {
        let id: NodePlacementID
        let after: NodePlacementID?
        let node: NodeID
        let collection: NodeCollection
        let active: Bool
        let rolePriority: ElementID?
        let roleOrigin: NodePlacementID?
        let columnBucket: Int?
        let columnRank: Int?
        init(id: NodePlacementID, after: NodePlacementID?, node: NodeID, collection: NodeCollection, active: Bool,
             rolePriority: ElementID? = nil, roleOrigin: NodePlacementID? = nil, columnBucket: Int? = nil, columnRank: Int? = nil) {
            self.id = id; self.after = after; self.node = node; self.collection = collection; self.active = active
            self.rolePriority = rolePriority; self.roleOrigin = roleOrigin; self.columnBucket = columnBucket; self.columnRank = columnRank
        }
    }
    var nodes: [NodeID: Node] = [:]
    var placements: [NodePlacementID: Placement] = [:]
    var deleted = Set<NodeID>()
    var touched = Set<NodeID>()
    private(set) var modern = false

    static func seed(_ document: Document) -> Self {
        var result = Self(), after: NodePlacementID?
        for block in document.blocks {
            let identity = NodeID.baseline(blockID: block.id, path: [])
            result.register(.object(block.fields), identity: identity, kind: .block, active: true)
            let id = NodePlacementID.initial(identity)
            result.placements[id] = Placement(id: id, after: after, node: identity, collection: .root, active: true)
            after = id
        }
        return result
    }

    static func seed(_ document: ModernDocument) -> Self {
        var result = Self(), after: NodePlacementID?
        result.modern = true
        var metadata = document.fields; metadata.removeValue(forKey: "blocks")
        result.register(.object(metadata), identity: .document(documentID: document.documentID), kind: .document, active: true)
        for block in document.blocks {
            let identity = NodeID.baseline(blockID: block.id, path: [])
            result.register(.object(block.fields), identity: identity, kind: .block, active: true)
            let id = NodePlacementID.initial(identity)
            result.placements[id] = Placement(id: id, after: after, node: identity, collection: .root, active: true)
            after = id
        }
        return result
    }

    static func collectionFields(_ kind: NodeKind, _ fields: [String: JSONValue], modern: Bool = false) -> [String: NodeKind] {
        switch kind {
        case .block:
            switch fields["type"]?.string {
            case "columns": return modern ? ["columns": .column] : [:]
            case "list": return ["items": .item]
            case "toggle": return ["children": .block]
            case "table": return ["rows": .row]
            default: return [:]
            }
        case .item: return ["children": .item]
        case .row: return ["cells": .cell]
        case .cell: return [:]
        case .column: return modern ? ["children": .block] : [:]
        case .document: return [:]
        }
    }

    mutating func register(_ value: JSONValue, identity: NodeID, kind: NodeKind, active: Bool) {
        guard nodes[identity] == nil, var fields = value.object else { return }
        let collections = Self.collectionFields(kind, fields, modern: modern)
        let present = Set(collections.keys.filter { fields[$0] != nil })
        let arrays = collections.reduce(into: [String: [JSONValue]]()) { $0[$1.key] = fields[$1.key]?.array ?? [] }
        for field in present { fields.removeValue(forKey: field) }
        nodes[identity] = Node(identity: identity, kind: kind, birthKind: kind, fields: fields, collections: present, birthActive: active)
        for (field, childKind) in collections {
            var after: NodePlacementID?
            for child in arrays[field] ?? [] {
                let path = [field, child["id"]?.string ?? ""]
                let childID: NodeID
                switch identity {
                case .document: return // Metadata is never a visible block/child collection.
                case .baseline(let root, let prefix): childID = .baseline(blockID: root, path: prefix + path)
                case .inserted(let creation, let prefix): childID = .inserted(creation: creation, path: prefix + path)
                }
                register(child, identity: childID, kind: childKind, active: active)
                let id = NodePlacementID.initial(childID)
                placements[id] = Placement(id: id, after: after, node: childID,
                                           collection: NodeCollection(owner: identity, field: field), active: true)
                after = id
            }
        }
    }

    func kind(in collection: NodeCollection) throws -> NodeKind {
        if collection == .root { return .block }
        guard let owner = collection.owner, let node = nodes[owner],
              let kind = Self.collectionFields(node.kind, node.fields, modern: modern)[collection.field] else { throw EditorError.invalidPath }
        return kind
    }

    /// Highest active placement wins. Cyclic or duplicate-label moves fall back to
    /// an earlier placement deterministically, without changing document IDs.
    func effectivePlacements() throws -> [NodeID: Placement] {
        // A known immediate anchor can itself depend on an absent earlier anchor.
        // Only complete ordering chains may replace a node's previous placement.
        // Inactive placements remain traversable anchors, just like tombstones.
        var successors: [NodePlacementID: [NodePlacementID]] = [:], pending: [NodePlacementID] = []
        for p in placements.values {
            if let anchor = p.after {
                // Undo cannot turn a known invalid ordering reference into a
                // valid transaction. Validate inactive anchors before admission.
                if let predecessor = placements[anchor], predecessor.collection != p.collection { throw EditorError.invalidChange }
                successors[anchor, default: []].append(p.id)
            }
            else { pending.append(p.id) }
        }
        var anchored = Set<NodePlacementID>()
        while let id = pending.popLast() {
            guard anchored.insert(id).inserted, let placement = placements[id] else { continue }
            pending.append(contentsOf: (successors[id] ?? []).filter { placements[$0]?.collection == placement.collection })
        }
        var candidates: [NodeID: [Placement]] = [:]
        for p in placements.values where p.active && nodes[p.node] != nil {
            if let owner = p.collection.owner, nodes[owner] == nil { continue }
            guard anchored.contains(p.id) else { continue }
            candidates[p.node, default: []].append(p)
        }
        // A created owner can exist before its own ordering chain is complete.
        // Moving existing content into that owner must also wait; otherwise the
        // content has no renderable path back to the document's root collection.
        var children: [NodeID: [NodeID]] = [:], roots: [NodeID] = []
        for alternatives in candidates.values {
            for placement in alternatives {
                if let owner = placement.collection.owner { children[owner, default: []].append(placement.node) }
                else { roots.append(placement.node) }
            }
        }
        var attached = Set<NodeID>()
        while let node = roots.popLast() {
            guard attached.insert(node).inserted else { continue }
            roots.append(contentsOf: children[node] ?? [])
        }
        for node in candidates.keys {
            candidates[node]?.removeAll { placement in
                placement.collection.owner.map { !attached.contains($0) } ?? false
            }
        }
        for key in candidates.keys { candidates[key]?.sort { $1.id < $0.id } }
        var indices: [NodeID: Int] = [:]
        func selected() -> [NodeID: Placement] {
            candidates.reduce(into: [:]) { result, entry in
                let index = indices[entry.key] ?? 0
                if index < entry.value.count { result[entry.key] = entry.value[index] }
            }
        }
        func retreat(_ conflicts: [NodeID], _ current: [NodeID: Placement]) throws {
            let movable = conflicts.filter { (indices[$0] ?? 0) + 1 < (candidates[$0]?.count ?? 0) }
            guard let loser = movable.min(by: { current[$0]!.id < current[$1]!.id }) else {
                throw EditorError.structuralConflict
            }
            indices[loser, default: 0] += 1
        }
        while true {
            let current = selected()
            var cycle: [NodeID]?
            for start in current.keys.sorted(by: { $0.key < $1.key }) {
                var path: [NodeID] = [], seen: [NodeID: Int] = [:], cursor: NodeID? = start
                while let id = cursor, let p = current[id] {
                    if let first = seen[id] { cycle = Array(path[first...]); break }
                    seen[id] = path.count; path.append(id); cursor = p.collection.owner
                }
                if cycle != nil { break }
            }
            if let cycle { try retreat(cycle, current); continue }
            // Deleted nodes are still valid anchors but do not reserve visible labels.
            let visible = visibleNodes(current)
            var labels: [NodeCollection: [String: [NodeID]]] = [:]
            for (id, p) in current where visible.contains(id) {
                labels[p.collection, default: [:]][nodes[id]!.label, default: []].append(id)
            }
            let collisions = labels.values.flatMap { $0.values.filter { $0.count > 1 } }
            if let collision = collisions.sorted(by: {
                $0.map(\.key).sorted().joined() < $1.map(\.key).sorted().joined()
            }).first { try retreat(collision, current); continue }
            return current
        }
    }

    /// An undone insertion retains active remote work. A deleted ancestor is
    /// retained as a container if an unobserved concurrent descendant survives.
    func visibleNodes(_ selected: [NodeID: Placement]) -> Set<NodeID> {
        var visible = Set(nodes.values.filter { selected[$0.identity] != nil && !deleted.contains($0.identity) && ($0.birthActive || touched.contains($0.identity)) }.map(\.identity))
        var pending = Array(visible)
        while let id = pending.popLast() {
            guard let parent = selected[id]?.collection.owner else { continue }
            if nodes[parent] != nil, visible.insert(parent).inserted { pending.append(parent) }
        }
        if modern {
            // Retained peer work in an undone layout still requires its two
            // column containers. Their hidden author content stays hidden.
            let layouts = Set(visible.filter { nodes[$0]?.kind == .block && nodes[$0]?.fields["type"] == .string("columns") })
            for (id, placement) in selected where nodes[id]?.kind == .column && placement.collection.field == "columns" {
                if let owner = placement.collection.owner, layouts.contains(owner) { visible.insert(id) }
            }
        }
        return visible
    }

    func order(in collection: NodeCollection, selected: [NodeID: Placement]) -> [NodeID] {
        let entries = placements.filter { $0.value.collection == collection }
        var children: [NodePlacementID: [NodePlacementID]] = [:], roots: [NodePlacementID] = []
        for (id, p) in entries {
            if let after = p.after { children[after, default: []].append(id) } else { roots.append(id) }
        }
        var itemRanks: [NodePlacementID: Int] = [:]
        let originCollections = Set(entries.values.compactMap { $0.roleOrigin.flatMap { placements[$0]?.collection } })
        for originCollection in originCollections {
            let old = placements.filter { $0.value.collection == originCollection }
            var successors: [NodePlacementID: [NodePlacementID]] = [:], pending: [NodePlacementID] = []
            for (id, placement) in old {
                if let after = placement.after { successors[after, default: []].append(id) } else { pending.append(id) }
            }
            pending.sort(); var visited = Set<NodePlacementID>(), index = 0
            while let id = pending.popLast() {
                guard visited.insert(id).inserted else { continue }
                itemRanks[id] = index; index += 1
                pending.append(contentsOf: (successors[id] ?? []).sorted())
            }
        }
        var groupPriorities: [NodeID: ElementID] = [:]
        for entry in entries.values {
            if case .role(let owner, _) = entry.id, let priority = entry.rolePriority,
               groupPriorities[owner].map({ $0 < priority }) ?? true { groupPriorities[owner] = priority }
        }
        func orderingKey(_ placement: Placement) -> NodePlacementID {
            if case .role(let owner, _) = placement.id, let priority = groupPriorities[owner] { return .edit(priority) }
            if case .columnRoute(_, let slot, _) = placement.id { return .edit(slot) }
            return placement.id
        }
        func ordered(_ lhs: NodePlacementID, _ rhs: NodePlacementID) -> Bool {
            let a = entries[lhs]!, b = entries[rhs]!
            let keyA = orderingKey(a), keyB = orderingKey(b)
            if keyA != keyB { return keyA < keyB }
            if case .columnRoute(let ownerA, _, _) = lhs, case .columnRoute(let ownerB, _, _) = rhs {
                if ownerA != ownerB { return ownerA.key < ownerB.key }
                if a.columnBucket != b.columnBucket { return (a.columnBucket ?? 0) > (b.columnBucket ?? 0) }
                if a.columnRank != b.columnRank { return (a.columnRank ?? 0) > (b.columnRank ?? 0) }
            }
            if case .role(let ownerA, _) = lhs, case .role(let ownerB, _) = rhs {
                if ownerA != ownerB { return ownerA.key < ownerB.key }
                let sourceA = a.roleOrigin.flatMap { placements[$0]?.collection }
                let sourceB = b.roleOrigin.flatMap { placements[$0]?.collection }
                let bucketA = sourceA.map { ($0.owner?.key ?? "") + ":" + $0.field } ?? ""
                let bucketB = sourceB.map { ($0.owner?.key ?? "") + ":" + $0.field } ?? ""
                if bucketA != bucketB { return bucketA < bucketB }
                let rankA = a.roleOrigin.flatMap { itemRanks[$0] } ?? Int.max
                let rankB = b.roleOrigin.flatMap { itemRanks[$0] } ?? Int.max
                if rankA != rankB { return rankA > rankB }
            }
            return lhs < rhs
        }
        var stack = roots.sorted(by: ordered), result: [NodeID] = [], seen = Set<NodePlacementID>()
        while let id = stack.popLast() {
            guard seen.insert(id).inserted, let p = entries[id] else { continue }
            if selected[p.node]?.id == id { result.append(p.node) }
            stack.append(contentsOf: (children[id] ?? []).sorted(by: ordered))
        }
        return result
    }

    func visibleOrder(in collection: NodeCollection) throws -> [NodeID] {
        let selected = try effectivePlacements(), visible = visibleNodes(selected)
        return order(in: collection, selected: selected).filter { visible.contains($0) }
    }

    func node(at address: NodeAddress) throws -> NodeID {
        let selected = try effectivePlacements(), visible = visibleNodes(selected)
        guard var id = order(in: .root, selected: selected).first(where: { visible.contains($0) && nodes[$0]?.label == address.blockID }) else { throw EditorError.invalidPath }
        guard address.path.count % 2 == 0 else { throw EditorError.invalidPath }
        for index in stride(from: 0, to: address.path.count, by: 2) {
            let collection = NodeCollection(owner: id, field: address.path[index])
            guard let child = order(in: collection, selected: selected).first(where: { visible.contains($0) && nodes[$0]?.label == address.path[index + 1] }) else { throw EditorError.invalidPath }
            id = child
        }
        return id
    }

    func address(of identity: NodeID) throws -> NodeAddress {
        let selected = try effectivePlacements()
        guard visibleNodes(selected).contains(identity) else { throw EditorError.invalidPath }
        var cursor = identity, path: [String] = [], visited = Set<NodeID>()
        while let placement = selected[cursor], let node = nodes[cursor] {
            guard visited.insert(cursor).inserted else { throw EditorError.invalidPath }
            if let owner = placement.collection.owner {
                path = [placement.collection.field, node.label] + path; cursor = owner
            } else { return NodeAddress(node.label, path: path) }
        }
        throw EditorError.invalidPath
    }

    func descendants(of identity: NodeID) throws -> [NodeID] {
        let selected = try effectivePlacements(), visible = visibleNodes(selected)
        var result: [NodeID] = [], stack = [identity], seen = Set<NodeID>()
        while let id = stack.popLast() {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
            stack.append(contentsOf: selected.filter { $0.value.collection.owner == id && visible.contains($0.key) }.map(\.key))
        }
        return result.sorted { $0.key < $1.key }
    }

    func document(text: [NodeID: [String: JSONValue]]) throws -> Document {
        guard !modern else { throw EditorError.invalidPath }
        return try Document(blocks: renderedBlocks(text: text))
    }

    func document(documentID: String, text: [NodeID: [String: JSONValue]]) throws -> ModernDocument {
        guard modern, let metadata = nodes[.document(documentID: documentID)], metadata.kind == .document,
              !deleted.contains(metadata.identity) else { throw EditorError.invalidPath }
        var fields = metadata.fields
        for (key, value) in text[metadata.identity] ?? [:] { fields[key] = value }
        fields["blocks"] = .array(try renderedBlocks(text: text).map { .object($0.fields) })
        return try ModernDocument(fields: fields)
    }

    private func renderedBlocks(text: [NodeID: [String: JSONValue]]) throws -> [Block] {
        let selected = try effectivePlacements(), visible = visibleNodes(selected)
        var childCollections: [NodeID: Set<String>] = [:]
        for p in selected.values where visible.contains(p.node) {
            if let owner = p.collection.owner { childCollections[owner, default: []].insert(p.collection.field) }
        }
        let roots = order(in: .root, selected: selected).filter { visible.contains($0) }
        var rendered: [NodeID: JSONValue] = [:]
        var pending = roots.reversed().map { ($0, 0, false) }
        while let (identity, depth, ready) = pending.popLast() {
            guard depth <= 100 else { throw EditorError.invalidDocument("Document nesting exceeds 100") }
            guard let node = nodes[identity] else { throw EditorError.invalidPath }
            let collections = node.collections.union(childCollections[identity] ?? [])
            if !ready {
                pending.append((identity, depth, true))
                for field in collections.sorted().reversed() {
                    let children = order(in: NodeCollection(owner: identity, field: field), selected: selected).filter { visible.contains($0) }
                    pending.append(contentsOf: children.reversed().map { ($0, depth + 2, false) })
                }
                continue
            }
            var fields = node.fields
            if !node.birthActive {
                for field in ["content", "summary", "caption", "code", "expression"] where fields[field] != nil {
                    fields[field] = fields[field]?.string != nil ? .string("") : .array([])
                }
            }
            for (key, value) in text[identity] ?? [:] { fields[key] = value }
            for field in collections {
                fields[field] = .array(try order(in: NodeCollection(owner: identity, field: field), selected: selected)
                    .filter { visible.contains($0) }.map {
                        guard let value = rendered[$0] else { throw EditorError.invalidPath }; return value
                    })
            }
            rendered[identity] = .object(fields)
        }
        return try roots.map { try Block(fields: rendered[$0]?.object ?? [:]) }
    }
}

func validateNode(_ value: JSONValue, kind: NodeKind, modern: Bool = false) throws {
    guard let label = value["id"]?.string, !label.isEmpty else { throw EditorError.invalidPath }
    switch kind {
    case .document, .column: throw EditorError.invalidPath // Only explicit modern compound commands may create these.
    case .block:
        if modern { try Validation.block(Block(fields: value.object ?? [:]), modern: true) }
        else { _ = try Document(blocks: [Block(fields: value.object ?? [:])]) }
    case .item:
        let wrapper = try Block(fields: ["id": .string("validation"), "type": .string("list"), "style": .string("unordered"), "items": .array([value])])
        if modern { try Validation.block(wrapper, modern: true) } else { _ = try Document(blocks: [wrapper]) }
    case .row:
        let wrapper = try Block(fields: ["id": .string("validation"), "type": .string("table"), "rows": .array([value])])
        if modern { try Validation.block(wrapper, modern: true) } else { _ = try Document(blocks: [wrapper]) }
    case .cell:
        let row: JSONValue = .object(["id": .string("row"), "cells": .array([value])])
        try validateNode(row, kind: .row, modern: modern)
    }
}
