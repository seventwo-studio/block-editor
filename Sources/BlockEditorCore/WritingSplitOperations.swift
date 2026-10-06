import Foundation

/// One retained cut: keep observed prefix ownership and route the observed tail
/// without copying atoms. Session-specific admission validates these inputs.
func writingSplitOperations(value: JSONValue, identity: NodeID, collection: NodeCollection, creation: ElementID,
                            after: NodePlacementID, source: WritingField, destination: WritingField,
                            edge: WritingEdge, before: NodeID?, selected: [WritingAtomKey],
                            prefix: [WritingAtomKey], suffix: [WritingAtomKey]) -> [WritingOperation] {
    var operations: [WritingOperation] = [
        .structure(.insertNode(value: value, identity: identity, collection: collection, placement: creation, after: after)),
        .text(.splitBoundary(source: source, destination: destination, edge: edge, before: before))]
    if !selected.isEmpty { operations.append(.text(.delete(keys: selected))) }
    if !prefix.isEmpty { operations.append(.text(.transfer(keys: prefix, destination: source, edge: .start))) }
    if !suffix.isEmpty { operations.append(.text(.transfer(keys: suffix, destination: destination, edge: .start))) }
    return operations
}
