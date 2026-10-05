import Foundation

/// Retained births are independent of current placement and author Undo. This
/// registry is for admission only; visible state still comes from shared replay.
func modernBirthRegistry(_ changes: [ModernChange], baseline: StructuralState) throws -> (structure: StructuralState, births: [WritingField: WritingFieldBirth]) {
    var registry = baseline, births = retainedWritingFields(baseline)
    for change in changes {
        guard case .edit(let operations) = change.body else { continue }
        var introduced = Set<ElementID>()
        for operation in operations {
            switch operation {
            case .structure(let mutation):
                switch mutation {
                case .insertNode(let value, let identity, let collection, let placement, let after):
                    try modernStructuralBoundaryShape(collection, after: after)
                    guard placement.change == change.id, placement.index >= 0, placement.index <= 2_147_483_647,
                          introduced.insert(placement).inserted, identity == .inserted(creation: placement, path: []),
                          registry.nodes[identity] == nil else { throw EditorError.invalidChange }
                    try validateModernAuthoredBlock(value)
                    registry.register(value, identity: identity, kind: .block, active: true)
                case .moveNode(let identity, let collection, let placement, let after):
                    try modernStructuralIdentityShape(identity)
                    try modernStructuralBoundaryShape(collection, after: after)
                    guard placement.change == change.id, placement.index >= 0, placement.index <= 2_147_483_647,
                          introduced.insert(placement).inserted else { throw EditorError.invalidChange }
                case .deleteNodes(let identities):
                    for identity in identities { try modernStructuralIdentityShape(identity) }
                    guard !identities.isEmpty, Set(identities).count == identities.count,
                          !identities.contains(where: { if case .document = $0 { return true }; return false }) else { throw EditorError.invalidChange }
                default: throw EditorError.invalidChange
                }
            case .createColumns(let value):
                try validateModernColumnCreationShape(value, change: change.id)
                guard registry.nodes[value.identity] == nil else { throw EditorError.invalidChange }
                for index in 0...value.nodes.count {
                    guard introduced.insert(ElementID(change: change.id, index: index)).inserted else { throw EditorError.invalidChange }
                }
                registry.register(value.layout, identity: value.identity, kind: .block, active: true)
            case .removeColumns(let layout, let source):
                try modernStructuralIdentityShape(layout); try modernColumnPlacementShape(source)
                guard introduced.insert(ElementID(change: change.id, index: 0)).inserted else { throw EditorError.invalidChange }
            case .resizeColumns(let layout, let split):
                try modernStructuralIdentityShape(layout)
                guard (1000...9000).contains(split) else { throw EditorError.invalidChange }
            case .convertBlock(let node, let type, let attributes):
                try modernStructuralIdentityShape(node); try validateWritingConversionAttributes(type: type, attributes: attributes)
            case .schemaConvert(let conversion):
                try validateModernSchemaShape(conversion, change: change.id)
                if let creation = conversion.creation {
                    guard introduced.insert(creation).inserted, registry.nodes[conversion.destination.node] == nil else { throw EditorError.invalidChange }
                    var item: [String: JSONValue] = ["id": .string(conversion.itemID!), "content": .array([])]
                    if conversion.attributes["style"] == .string("todo") { item["checked"] = .bool(false) }
                    registry.register(.object(item), identity: conversion.destination.node, kind: .item, active: true)
                }
                births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: conversion.type == "code" ? .string("") : .array([]), active: true)
            case .enterListItem(let enter):
                try validateModernEnterShape(enter, change: change.id)
                for operation in enter.operations {
                    if case .schemaConvert(let conversion) = operation {
                        births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: .array([]), active: true)
                    }
                    if case .structure(let mutation) = operation {
                        switch mutation {
                        case .insertNode(let value, let identity, _, let placement, _):
                            guard introduced.insert(placement).inserted, registry.nodes[identity] == nil else { throw EditorError.invalidChange }
                            registry.register(value, identity: identity, kind: .block, active: true)
                        case .moveNode(_, _, let placement, _): guard introduced.insert(placement).inserted else { throw EditorError.invalidChange }
                        default: throw EditorError.invalidChange
                        }
                    }
                }
            case .splitBlock(let split):
                try validateModernSplitShape(split, change: change.id)
                guard introduced.insert(split.creation).inserted, registry.nodes[split.identity] == nil else { throw EditorError.invalidChange }
                registry.register(split.value, identity: split.identity, kind: split.item ? .item : .block, active: true)
            case .mergeBlocks(let join):
                guard join.selection.nodes.count == 2, Set(join.selection.nodes).count == 2 else { throw EditorError.invalidChange }
                for node in join.selection.nodes { try modernStructuralIdentityShape(node) }
            case .text(.insert(let atom)):
                guard introduced.insert(atom.key.element).inserted else { throw EditorError.invalidChange }
            default: break
            }
            switch operation {
            case .structure(.insertNode), .createColumns, .splitBlock, .enterListItem: retainModernFieldBirths(in: registry, births: &births)
            default: break
            }
        }
    }
    return (registry, births)
}

func modernStructuralIdentityShape(_ identity: NodeID) throws {
    let path: [String]
    switch identity {
    case .document: throw EditorError.invalidChange
    case .baseline(let label, let suffix):
        guard !label.isEmpty else { throw EditorError.invalidChange }; path = suffix
    case .inserted(let creation, let suffix):
        guard creation.change.counter > 0, creation.change.counter <= 9_007_199_254_740_991,
              validToken(creation.change.actor), creation.index >= 0, creation.index <= 2_147_483_647 else { throw EditorError.invalidChange }
        path = suffix
    }
    guard path.count <= 100, path.count % 2 == 0, path.allSatisfy({ !$0.isEmpty }) else { throw EditorError.invalidChange }
}
private func modernStructuralBoundaryShape(_ collection: NodeCollection, after: NodePlacementID?) throws {
    if collection != .root {
        guard let owner = collection.owner, collection.field == "children" else { throw EditorError.invalidChange }
        try modernStructuralIdentityShape(owner)
    }
    if let after {
        try modernColumnPlacementShape(after)
    }
}

func validateModernAuthoredBlock(_ value: JSONValue) throws {
    try validateNode(value, kind: .block, modern: true)
    let known = Set(["paragraph", "heading", "quote", "callout", "toggle", "list", "table", "image", "code", "math", "divider", "embed"])
    var pending: [(JSONValue, NodeKind)] = [(value, .block)]
    while let (node, kind) = pending.popLast() {
        if kind == .block {
            guard let type = node["type"]?.string, known.contains(type) else { throw EditorError.invalidChange }
        }
        // Newly authored structural payloads must use the same inline-mark
        // policy as scalar text insertion. Unknown consumer fields stay opaque.
        let inlineFields: [String]
        if kind == .item || kind == .cell { inlineFields = ["content"] }
        else if kind == .block {
            switch node["type"]?.string {
            case "paragraph", "heading", "quote", "callout": inlineFields = ["content"]
            case "toggle": inlineFields = ["summary"]
            case "image": inlineFields = ["caption"]
            default: inlineFields = []
            }
        } else { inlineFields = [] }
        for field in inlineFields {
            for atom in node[field]?.array ?? [] {
                for mark in atom["marks"]?.array ?? [] { try validateModernMark(type: mark["type"]?.string ?? "", mark: mark) }
            }
        }
        for (field, childKind) in StructuralState.collectionFields(kind, node.object ?? [:], modern: true) {
            pending.append(contentsOf: (node[field]?.array ?? []).map { ($0, childKind) })
        }
    }
}

func modernReference(_ identity: NodeID, before change: ChangeID, cohort: Set<ChangeID>, registry: StructuralState) throws {
    guard registry.nodes[identity] != nil else { throw EditorError.invalidChange }
    if case .inserted(let creation, _) = identity {
        guard creation.change == change || cohort.contains(creation.change) else { throw EditorError.invalidChange }
    }
}

/// Generic block placement is confined to root and existing column children.
/// Columns themselves and document metadata require explicit compound commands.
func modernBlockCollection(_ collection: NodeCollection, structure: StructuralState) throws {
    if collection == .root { return }
    guard let owner = collection.owner, structure.nodes[owner]?.kind == .column,
          collection.field == "children" else { throw EditorError.invalidChange }
}

func validateModernStructure(_ mutation: Mutation, change: ChangeID, cohort: Set<ChangeID>, registry: StructuralState,
                             structure: StructuralState, introduced: inout Set<ElementID>) throws {
    func node(_ identity: NodeID) throws {
        try modernReference(identity, before: change, cohort: cohort, registry: registry)
        guard structure.nodes[identity] != nil else { throw EditorError.invalidChange }
    }
    func boundary(_ collection: NodeCollection, _ after: NodePlacementID?) throws {
        try modernBlockCollection(collection, structure: structure)
        if let owner = collection.owner { try node(owner) }
        if let after {
            try modernColumnPlacementReference(after, change: change, cohort: cohort, registry: registry)
            guard structure.placements[after]?.collection == collection else { throw EditorError.invalidChange }
        }
    }
    switch mutation {
    case .insertNode(let value, let identity, let collection, let placement, let after):
        guard identity == .inserted(creation: placement, path: []), placement.change == change,
              introduced.insert(placement).inserted, structure.nodes[identity] == nil else { throw EditorError.invalidChange }
        try validateModernAuthoredBlock(value); try boundary(collection, after)
    case .moveNode(let identity, let collection, let placement, let after):
        try node(identity)
        guard structure.nodes[identity]?.kind == .block, placement.change == change,
              introduced.insert(placement).inserted else { throw EditorError.invalidChange }
        try boundary(collection, after)
        guard after.flatMap({ structure.placements[$0]?.node }) != identity else { throw EditorError.invalidChange }
    case .deleteNodes(let identities):
        for identity in identities {
            try node(identity)
            guard let kind = structure.nodes[identity]?.kind, kind != .document else { throw EditorError.invalidChange }
            if kind != .block {
                guard let parent = structure.placements[.initial(identity)]?.collection.owner,
                      identities.contains(parent) else { throw EditorError.invalidChange }
            }
            if structure.nodes[identity]?.fields["type"] == .string("columns") {
                let columns = structure.placements.values.filter { $0.collection == NodeCollection(owner: identity, field: "columns") }.map(\.node)
                guard columns.allSatisfy(identities.contains) else { throw EditorError.invalidChange }
            }
        }
    default: throw EditorError.invalidChange
    }
}

extension ModernSession {
    @discardableResult public func insertBlock(_ block: Block, into collection: NodeCollection = .root, after: NodeID? = nil) throws -> NodeID {
        try authoringAllowed(command: "insertBlock"); endTypingGroup()
        try modernBlockCollection(collection, structure: structure)
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        try validateModernAuthoredBlock(.object(block.fields))
        guard !(try structure.visibleOrder(in: collection)).contains(where: { structure.nodes[$0]?.label == block.id }) else { throw EditorError.invalidChange }
        let anchor = try modernBoundary(after, in: collection), id = try nextID()
        let placement = ElementID(change: id, index: 0), identity = NodeID.inserted(creation: placement, path: [])
        try perform(id, [.structure(.insertNode(value: .object(block.fields), identity: identity, collection: collection, placement: placement, after: anchor))])
        return identity
    }
    public func move(_ identity: NodeID, into collection: NodeCollection, after: NodeID? = nil) throws {
        try authoringAllowed(command: "move"); endTypingGroup()
        _ = try structure.address(of: identity)
        guard structure.nodes[identity]?.kind == .block, identity != after else { throw EditorError.invalidChange }
        try modernBlockCollection(collection, structure: structure)
        if let owner = collection.owner {
            _ = try structure.address(of: owner)
            guard !(try structure.descendants(of: identity)).contains(owner) else { throw EditorError.invalidChange }
        }
        guard !(try structure.visibleOrder(in: collection)).contains(where: { $0 != identity && structure.nodes[$0]?.label == structure.nodes[identity]?.label }) else { throw EditorError.invalidChange }
        let anchor = try modernBoundary(after, in: collection), id = try nextID()
        let current = try structure.effectivePlacements()[identity]
        if current?.collection == collection {
            let siblings = try structure.visibleOrder(in: collection), offset = siblings.firstIndex(of: identity)!
            if (offset == 0 ? nil : siblings[offset - 1]) == after { return }
        }
        try perform(id, [.structure(.moveNode(identity: identity, collection: collection, placement: ElementID(change: id, index: 0), after: anchor))])
    }
    public func delete(_ identity: NodeID) throws {
        try authoringAllowed(command: "delete"); endTypingGroup()
        _ = try structure.address(of: identity)
        guard structure.nodes[identity]?.kind == .block else { throw EditorError.invalidChange }
        try perform(nextID(), [.structure(.deleteNodes(identities: structure.descendants(of: identity)))])
    }
    public func address(of identity: NodeID) throws -> NodeAddress { try structure.address(of: identity) }
    public func nodes(in collection: NodeCollection = .root) throws -> [NodeID] { try structure.visibleOrder(in: collection) }
    private func modernBoundary(_ identity: NodeID?, in collection: NodeCollection) throws -> NodePlacementID? {
        guard let identity else { return nil }
        guard (try structure.visibleOrder(in: collection)).contains(identity),
              let placement = try structure.effectivePlacements()[identity] else { throw EditorError.invalidPath }
        return placement.id
    }
}
