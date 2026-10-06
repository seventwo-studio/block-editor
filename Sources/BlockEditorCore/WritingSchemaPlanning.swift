import Foundation

func writingListOwner(of item: NodeID, structure: StructuralState) throws -> NodeID {
    let placements = try structure.effectivePlacements()
    var current = item, visited = Set<NodeID>()
    while let owner = placements[current]?.collection.owner {
        guard visited.insert(owner).inserted else { throw EditorError.invalidPath }
        if structure.nodes[owner]?.fields["type"] == .string("list"), structure.nodes[owner]?.kind == .block { return owner }
        guard structure.nodes[owner]?.kind == .item else { throw EditorError.invalidPath }
        current = owner
    }
    throw EditorError.invalidPath
}

/// Pure conversion planning shared by retained legacy and modern sessions.
func planWritingSchemaConversion(source: WritingField, target: WritingBlockTarget, id: ChangeID,
                                 structure: StructuralState, projection: WritingProjection, creationIndex: Int = 0) throws -> WritingSchemaConversion {
    let root = structure.nodes[source.node]?.kind == .item ? try writingListOwner(of: source.node, structure: structure) : source.node
    guard let node = structure.nodes[root], node.kind == .block,
          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(node.fields["type"]?.string ?? ""),
          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(target.type) else { throw EditorError.invalidChange }
    var preserved: [String: JSONValue] = [:]
    if node.fields["type"] == .string("list") {
        let items = try structure.visibleOrder(in: NodeCollection(owner: root, field: "items"))
        guard items == [source.node], let item = structure.nodes[source.node] else { throw EditorError.invalidChange }
        // Unknown item properties are retained only where the root has no
        // conflicting value. No overwrite can make a conversion lossless.
        for (key, value) in item.fields where key != "id" && key != "content" {
            guard !["type", "code", "summary", "caption", "expression", "items", "rows"].contains(key),
                  node.fields[key] == nil || node.fields[key] == value else { throw EditorError.invalidChange }
            preserved[key] = value
        }
        if item.collections.contains("children") {
            guard node.fields["children"] == nil || node.fields["children"] == .array([]) else { throw EditorError.invalidChange }
            preserved["children"] = .array([])
        }
    }
    if target.type == "code" {
        guard projection.nodes(in: source).allSatisfy({
            $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty &&
            Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"])
        }) else { throw EditorError.invalidChange }
    }
    var attributes: [String: JSONValue] = [:]
    if target.type == "heading" { attributes["level"] = .number(Double(target.level ?? 1)) }
    if target.type == "callout" { attributes["variant"] = .string(target.variant ?? "info") }
    if target.type == "list" {
        guard node.fields["items"] == nil, node.fields["type"] != .string("list") else { throw EditorError.invalidChange }
        attributes["style"] = .string(target.style ?? "unordered")
        guard node.fields["style"] == nil || node.fields["style"] == attributes["style"] else { throw EditorError.invalidChange }
        let creation = ElementID(change: id, index: creationIndex)
        return WritingSchemaConversion(node: root, type: target.type, attributes: attributes, source: source,
            destination: WritingField(node: .inserted(creation: creation, path: []), name: "content"),
            itemID: node.label + "-item", creation: creation, preservedItemFields: [:])
    }
    for (key, attribute) in attributes {
        let previous = preserved[key] ?? node.fields[key]
        guard node.fields["type"]?.string == conversionAttributeOwner(key) || previous == nil || previous == attribute else { throw EditorError.invalidChange }
    }
    let name = target.type == "code" ? "code" : "content"
    guard name == source.name && root == source.node || node.fields[name] == nil else { throw EditorError.invalidChange }
    return WritingSchemaConversion(node: root, type: target.type, attributes: attributes, source: source,
        destination: WritingField(node: root, name: name), itemID: nil, creation: nil, preservedItemFields: preserved)
}
