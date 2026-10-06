import Foundation

/// Shared metadata conversion. Admission remains owned by each session/epoch.
func validateWritingConversionAttributes(type: String, attributes: [String: JSONValue], strictValues: Bool = true) throws {
    let allowed: Set<String>
    switch type {
    case "paragraph", "quote": allowed = []
    case "heading": allowed = ["level"]
    case "callout": allowed = ["variant"]
    case "list": allowed = ["style"]
    default: throw EditorError.invalidChange
    }
    guard Set(attributes.keys).isSubset(of: allowed) else { throw EditorError.invalidChange }
    if strictValues, let level = attributes["level"], ![.number(1), .number(2), .number(3)].contains(level) { throw EditorError.invalidChange }
    if strictValues, let variant = attributes["variant"], !["info", "warning", "error", "success"].contains(variant.string ?? "") { throw EditorError.invalidChange }
    if let style = attributes["style"], !["ordered", "unordered", "todo"].contains(style.string ?? "") { throw EditorError.invalidChange }
}
func writingConvertedBlock(_ original: StructuralState.Node, type: String, attributes: [String: JSONValue],
                           modern: Bool = false, retiredList: Bool = false, active: Bool = true) throws -> StructuralState.Node {
    var value = original
    let previous = value.fields["type"]?.string ?? "", inline = ["paragraph", "heading", "quote", "callout"]
    guard value.kind == .block, (inline.contains(previous) && inline.contains(type)) || (previous == "list" && type == "list") || retiredList else { throw EditorError.invalidChange }
    try validateWritingConversionAttributes(type: type, attributes: attributes, strictValues: modern)
    if type == "list", attributes["style"] == nil { throw EditorError.invalidChange }
    if !retiredList { value.fields["type"] = .string(type) }
    for (key, attribute) in attributes {
        guard !active || previous == conversionAttributeOwner(key) || retiredList || value.fields[key] == nil || value.fields[key] == attribute else {
            throw EditorError.invalidDocument("Conversion attribute metadata requires reconciliation")
        }
        value.fields[key] = attribute
    }
    var shape = value.fields
    for collection in value.collections { shape[collection] = .array([]) }
    try validateNode(.object(shape), kind: .block, modern: modern)
    return value
}
