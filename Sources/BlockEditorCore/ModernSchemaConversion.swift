import Foundation

/// Immutable field births outlive schema changes, retired list items and Undo.
func retainModernFieldBirths(in structure: StructuralState, births: inout [WritingField: WritingFieldBirth]) {
    for (field, birth) in retainedWritingFields(structure) where births[field] == nil { births[field] = birth }
}
func modernCollectionBirths(_ structure: StructuralState) -> [NodeCollection: NodeKind] {
    var result: [NodeCollection: NodeKind] = [:]
    for (identity, node) in structure.nodes {
        for (name, kind) in StructuralState.collectionFields(node.kind, node.fields, modern: true) {
            result[NodeCollection(owner: identity, field: name)] = kind
        }
    }
    return result
}

/// Validate intrinsic shape before resolving predecessors or author activity.
func validateModernSchemaShape(_ conversion: WritingSchemaConversion, change: ChangeID) throws {
    try modernStructuralIdentityShape(conversion.node)
    try modernStructuralIdentityShape(conversion.source.node)
    try modernStructuralIdentityShape(conversion.destination.node)
    guard ["content", "code"].contains(conversion.source.name), conversion.source != conversion.destination,
          conversion.preservedItemFields.keys.allSatisfy({ !["id", "type", "content", "code", "summary", "caption", "expression", "items", "rows"].contains($0) }) else { throw EditorError.invalidChange }
    switch conversion.type {
    case "list":
        guard let creation = conversion.creation, creation.change == change, creation.index == 0,
              let label = conversion.itemID, !label.isEmpty, conversion.source.node == conversion.node,
              conversion.destination == WritingField(node: .inserted(creation: creation, path: []), name: "content"),
              conversion.preservedItemFields.isEmpty, Set(conversion.attributes.keys) == ["style"],
              ["ordered", "unordered", "todo"].contains(conversion.attributes["style"]?.string ?? "") else { throw EditorError.invalidChange }
    case "code", "paragraph", "heading", "quote", "callout":
        guard conversion.creation == nil, conversion.itemID == nil,
              conversion.destination == WritingField(node: conversion.node, name: conversion.type == "code" ? "code" : "content") else { throw EditorError.invalidChange }
        if conversion.type == "code" { guard conversion.attributes.isEmpty else { throw EditorError.invalidChange } }
        else {
            try validateWritingConversionAttributes(type: conversion.type, attributes: conversion.attributes)
            let required: Set<String> = conversion.type == "heading" ? ["level"] : conversion.type == "callout" ? ["variant"] : []
            guard Set(conversion.attributes.keys) == required else { throw EditorError.invalidChange }
        }
    default: throw EditorError.invalidChange
    }
}

/// A remote conversion must reproduce the lossless plan in its author's causal
/// view. Concurrent incompatible unions are retained by shared projection.
func validateModernSchemaConversion(_ conversion: WritingSchemaConversion, change: ChangeID,
                                    structure: StructuralState, projection: WritingProjection) throws {
    try validateModernSchemaShape(conversion, change: change)
    guard projection.hasField(conversion.source), try projection.destination(of: conversion.source) == conversion.source else { throw EditorError.invalidChange }
    _ = try structure.address(of: conversion.source.node)
    // A code block may already own an opaque content extension. List creation
    // clears the root content slot, so that shape is not a lossless conversion.
    if conversion.type == "list", conversion.source.name != "content" {
        guard structure.nodes[conversion.node]?.fields["content"] == nil else { throw EditorError.invalidChange }
    }
    let target = WritingBlockTarget(type: conversion.type, level: conversion.attributes["level"].flatMap { value in
        if case .number(let number) = value { return Int(number) }; return nil
    }, style: conversion.attributes["style"]?.string, variant: conversion.attributes["variant"]?.string)
    let expected = try planWritingSchemaConversion(source: conversion.source, target: target, id: change, structure: structure, projection: projection)
    guard conversion == expected else { throw EditorError.invalidChange }
}

/// Admission already proved the cut against its author's current view. Replay
/// can then retain a peer item birth in an owner whose list conversion was undone.
func applyModernSplitBirth(_ split: ModernBlockSplit, enabled: Bool, raw: inout Materialized,
                           collectionBirths: [NodeCollection: NodeKind]) throws {
    let original = raw.structure!.nodes
    let validating = writingRetainedCollectionShape(raw, mutations: [split.birth], collectionBirths: collectionBirths)
    let adjusted = validating.structure!.nodes.filter { original[$0.key]?.fields != $0.value.fields || original[$0.key]?.kind != $0.value.kind }
    raw.structure = validating.structure
    try apply([split.birth], enabled: enabled, to: &raw)
    for owner in adjusted.keys { raw.structure!.nodes[owner] = original[owner] }
}
