import Foundation

/// Shared baseline atom allocation for legacy and modern document origins.
func seedWritingAtoms(_ births: [WritingField: WritingFieldBirth]) -> (atoms: [WritingAtomSeed], hidden: Set<WritingAtomKey>) {
    var seeds: [WritingAtomSeed] = [], hidden = Set<WritingAtomKey>()
    for (field, birth) in births {
        var previous: WritingAtomKey?, index = 0
        let value = birth.value
        for payload in value.array ?? value.string.map({ [textNode($0)] }) ?? [] {
            let parts: [JSONValue]
            if payload["type"] == .string("text") {
                parts = (payload["text"]?.string ?? "").unicodeScalars.map {
                    var object = payload.object!; object["text"] = .string(String($0)); return .object(object)
                }
                if parts.isEmpty, value.array != nil {
                    let key = WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))
                    seeds.append(WritingAtomSeed(key: key, node: payload, edge: previous.map(WritingEdge.after) ?? .start, route: .field(field)))
                    if !birth.active { hidden.insert(key) }
                    previous = key; index += 1
                }
            } else { parts = [payload] }
            for part in parts {
                let key = WritingAtomKey(origin: field, element: ElementID(change: ChangeID(counter: 0, actor: ""), index: index))
                seeds.append(WritingAtomSeed(key: key, node: part, edge: previous.map(WritingEdge.after) ?? .start, route: .field(field)))
                if !birth.active { hidden.insert(key) }
                previous = key; index += 1
            }
        }
    }
    return (seeds, hidden)
}

/// Preserve untouched run JSON; only edited fields need atom-run compaction.
func projectedWritingValues(structure: inout StructuralState, projection: WritingProjection, seeds: [WritingAtomSeed], fields: Set<WritingField>, births: [WritingField: WritingFieldBirth], retainedOrigins: Bool, omitEmptyMarks: Bool = false) throws -> [NodeID: [String: JSONValue]] {
    var values: [NodeID: [String: JSONValue]] = [:]
    var baselineNodesByField: [WritingField: [JSONValue]] = [:]
    for seed in seeds { baselineNodesByField[seed.key.origin, default: []].append(seed.node) }
    for field in fields {
        let nodes = projection.nodes(in: field)
        if retainedOrigins, field.name == "code", !nodes.allSatisfy({
            $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty &&
            Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"])
        }) { throw EditorError.invalidDocument("Code conversion cannot flatten rich atoms") }
        if !nodes.isEmpty { structure.touched.insert(field.node) }
        // Preserve exact baseline JSON for untouched fields, including empty
        // text runs and host extensions that have no visible scalar atoms.
        let original = structure.nodes[field.node]!.fields[field.name]!
        let baselineNodes = baselineNodesByField[field] ?? []
        if nodes == baselineNodes, structure.nodes[field.node]!.birthActive,
           !retainedOrigins || original == births[field]?.value { continue }
        var runs: [JSONValue] = []
        let compactEmptyMarks = omitEmptyMarks && !baselineNodes.contains(where: { $0["marks"] == .array([]) })
        for rawNode in nodes {
            var node = rawNode
            // Modern edited runs omit empty marks unless the field explicitly
            // used that representation at birth. Untouched input JSON
            // above remains exact, and legacy projections retain their wire form.
            if compactEmptyMarks, node["marks"] == .array([]), var object = node.object {
                object.removeValue(forKey: "marks"); node = .object(object)
            }
            if node["type"] == .string("text"), var last = runs.last?.object, last["type"] == .string("text") {
                var lhs = last, rhs = node.object!
                lhs.removeValue(forKey: "text"); rhs.removeValue(forKey: "text")
                if lhs == rhs {
                    last["text"] = .string((last["text"]?.string ?? "") + (node["text"]?.string ?? ""))
                    runs[runs.count - 1] = .object(last); continue
                }
            }
            runs.append(node)
        }
        values[field.node, default: [:]][field.name] = original.string == nil ? .array(runs) : .string(plainText(runs))
    }
    return values
}
