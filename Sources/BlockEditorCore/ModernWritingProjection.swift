import Foundation

/// Reuse the existing writing projection after modern admission. Modern grouped
/// toggles are supplied through activeOverride, so no duplicate synthetic IDs are
/// introduced into causal cut ordering. This does not invoke legacy admission.
func modernProjectionChanges(_ changes: [ModernChange]) -> [WritingChange] {
    changes.map { change in
        let operations: [WritingOperation]
        if case .edit(let edits) = change.body {
            operations = edits.flatMap { operation -> [WritingOperation] in
                switch operation {
                case .structure(let mutation): return [.structure(mutation)]
                case .text(let mutation): return [.text(mutation)]
                case .convertBlock(let node, let type, let attributes): return [.convertBlock(node: node, type: type, attributes: attributes)]
                case .splitBlock(let split): return split.writingOperations
                case .mergeBlocks(let join): return [.text(.join(source: join.source, destination: join.destination, edge: join.edge))]
                case .createColumns, .removeColumns, .resizeColumns, .setAppearance: return []
                }
            }
        } else { operations = [] }
        return WritingChange(id: change.id, body: .edit(operations), observed: change.observed)
    }
}
