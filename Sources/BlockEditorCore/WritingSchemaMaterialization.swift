import Foundation

/// Materialize conversion after session-owned identity, causal and field proof.
/// Retained field births are immutable across active shape changes and Undo.
func applyWritingSchemaConversion(_ conversion: WritingSchemaConversion, change: ChangeID, enabled: Bool,
                                  raw: inout Materialized, births: inout [WritingField: WritingFieldBirth],
                                  collectionBirths: inout [NodeCollection: NodeKind], introduced: inout Set<ElementID>,
                                  modern: Bool = false) throws {
    guard conversion.source.node == conversion.node || conversion.type != "list",
          let original = raw.structure?.nodes[conversion.node], original.kind == .block,
          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(original.fields["type"]?.string ?? ""),
          ["paragraph", "heading", "quote", "callout", "list", "code"].contains(conversion.type) else { throw EditorError.invalidChange }
    if conversion.source.node != conversion.node {
        guard raw.structure?.nodes[conversion.source.node]?.kind == .item,
              raw.structure!.placements.values.contains(where: {
                  $0.node == conversion.source.node && $0.collection == NodeCollection(owner: conversion.node, field: "items")
              }) else { throw EditorError.invalidChange }
    }
    var value = original
    if conversion.type == "list" {
        guard let creation = conversion.creation, creation.change == change, creation.index >= 0, creation.index <= 2_147_483_647,
              original.fields["items"] == nil, introduced.insert(creation).inserted, let itemID = conversion.itemID, !itemID.isEmpty,
              conversion.destination == WritingField(node: .inserted(creation: creation, path: []), name: "content"),
              conversion.attributes.keys.allSatisfy({ $0 == "style" }) else { throw EditorError.invalidChange }
        if enabled, original.fields["type"] == .string("list") {
            throw EditorError.invalidDocument("Concurrent list conversions require reconciliation")
        }
        var item: [String: JSONValue] = ["id": .string(itemID), "content": .array([])]
        if conversion.attributes["style"] == .string("todo") { item["checked"] = .bool(false) }
        raw.structure?.register(.object(item), identity: conversion.destination.node, kind: .item, active: enabled)
        let placement = NodePlacementID.edit(creation)
        raw.structure?.placements[placement] = StructuralState.Placement(id: placement, after: nil,
            node: conversion.destination.node, collection: NodeCollection(owner: conversion.node, field: "items"), active: enabled)
        births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: .array([]), active: enabled)
        collectionBirths[NodeCollection(owner: conversion.node, field: "items")] = .item
        value.collections.insert("items")
    } else {
        guard conversion.creation == nil, conversion.itemID == nil,
              (conversion.source == conversion.destination || original.fields[conversion.destination.name] == nil || births[conversion.destination] != nil),
              conversion.destination == WritingField(node: conversion.node, name: conversion.type == "code" ? "code" : "content") else { throw EditorError.invalidChange }
        let allowed: Set<String> = conversion.type == "heading" ? ["level"] : conversion.type == "callout" ? ["variant"] : conversion.type == "code" ? ["language"] : []
        guard Set(conversion.attributes.keys).isSubset(of: allowed) else { throw EditorError.invalidChange }
        births[conversion.destination] = births[conversion.destination] ?? WritingFieldBirth(value: conversion.type == "code" ? .string("") : .array([]), active: true)
        value.collections.remove("items")
    }
    if conversion.source.node != conversion.node {
        guard let item = raw.structure?.nodes[conversion.source.node], item.kind == .item else { throw EditorError.invalidChange }
        guard item.fields.filter({ $0.key != "id" && $0.key != "content" }) == conversion.preservedItemFields.filter({ $0.key != "children" }) else {
            throw EditorError.invalidDocument("Converted item metadata requires reconciliation")
        }
        if item.collections.contains("children") {
            guard conversion.preservedItemFields["children"] == nil || conversion.preservedItemFields["children"] == .array([]) else { throw EditorError.invalidChange }
        }
    } else { guard conversion.preservedItemFields.isEmpty else { throw EditorError.invalidChange } }
    guard conversion.preservedItemFields.keys.allSatisfy({ !["id", "type", "content", "code", "summary", "caption", "expression", "items", "rows"].contains($0) }) else { throw EditorError.invalidChange }
    for (key, preserved) in conversion.preservedItemFields {
        guard original.fields[key] == nil || original.fields[key] == preserved else { throw EditorError.invalidChange }
        value.fields[key] = preserved
    }
    value.fields.removeValue(forKey: conversion.source.name)
    value.fields["type"] = .string(conversion.type)
    value.fields[conversion.destination.name] = conversion.type == "list" ? nil : conversion.type == "code" ? .string("") : .array([])
    for (key, attribute) in conversion.attributes {
        guard !enabled || original.fields["type"]?.string == conversionAttributeOwner(key) || value.fields[key] == nil || value.fields[key] == attribute else {
            throw EditorError.invalidDocument("Conversion attribute metadata requires reconciliation")
        }
        value.fields[key] = attribute
    }
    var shape = value.fields
    for collection in value.collections { shape[collection] = .array([]) }
    try validateNode(.object(shape), kind: .block, modern: modern)
    if enabled {
        raw.structure?.nodes[conversion.node] = value; raw.structure?.touched.insert(conversion.node)
        if conversion.source.node != conversion.node { raw.structure?.deleted.insert(conversion.source.node) }
    }
}
