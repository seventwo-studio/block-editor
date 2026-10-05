import Foundation

/// Resolve retained atoms and field heads through the shared writing projection.
/// Session admission owns scope/anchor proof and the retired-birth boundary.
func resolveWritingPosition(_ original: WritingPosition, projection: WritingProjection, structure: StructuralState,
                            retiredBoundary: (WritingField) throws -> (WritingField, WritingEdge)?) throws -> ResolvedWritingPosition {
    var position = original, retiredHeads = Set<WritingField>()
    while true {
        if let anchor = position.anchor, anchor.element.index < 0 { throw EditorError.invalidChange }
        let field = try position.anchor.map { try projection.field(of: $0) } ?? projection.destination(of: position.field)
        do { if structure.nodes[field.node]?.kind != .document { _ = try structure.address(of: field.node) } }
        catch {
            guard position.anchor == nil, position.affinity == .after, position.intraAtomOffset == nil,
                  retiredHeads.insert(position.field).inserted,
                  let (source, edge) = try retiredBoundary(position.field) else { throw error }
            let affinity: TextAffinity
            switch edge { case .before: affinity = .before; case .after, .start: affinity = .after }
            position = WritingPosition(documentID: original.documentID, epoch: original.epoch,
                field: source, anchor: edge.anchor, affinity: affinity)
            continue
        }
        guard let anchor = position.anchor else {
            guard position.intraAtomOffset == nil else { throw EditorError.invalidRange }
            let offset = position.affinity == .before ? projection.text(in: field).utf16.count : try projection.startOffset(of: position.field)
            return ResolvedWritingPosition(address: field.node.textAddress(field.name), offset: offset)
        }
        var offset = try projection.offset(of: anchor, affinity: position.affinity)
        if let interior = position.intraAtomOffset {
            let value = try projection.value(of: anchor), label = plainText([value])
            var cursor = 0, scalarBoundary = false
            for scalar in label.unicodeScalars { cursor += scalar.value > 0xffff ? 2 : 1; if cursor == interior { scalarBoundary = true; break }; if cursor > interior { break } }
            guard value["type"] != .string("text"), interior > 0, interior < label.utf16.count, scalarBoundary else { throw EditorError.invalidRange }
            offset = try projection.offset(of: anchor, affinity: .before) + (projection.visibleKeys(in: field).contains(anchor) ? interior : 0)
        }
        return ResolvedWritingPosition(address: field.node.textAddress(field.name), offset: offset)
    }
}
