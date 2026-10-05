import Foundation

public enum ModernPasteMode: String, Codable, Sendable { case rich, flattenedColumns, plainText }
/// A text replacement or an explicit collection boundary with optional mixed
/// replacement. No target is inferred from the host's current selection.
public struct ModernPasteTarget: Codable, Equatable, Sendable {
    public let range: ModernTextRange?
    public let boundary: ModernBlockBoundary?
    public let selection: ModernDeleteTarget?
    public init(range: ModernTextRange) { self.range = range; boundary = nil; selection = nil }
    public init(boundary: ModernBlockBoundary, selection: ModernDeleteTarget? = nil) {
        range = nil; self.boundary = boundary; self.selection = selection
    }
}
/// Exact retained plan re-derived in the author's causal cohort, including
/// inactive history. The original rich payload survives explicit fallback.
public struct ModernPaste: Codable, Equatable, Sendable {
    public let target: ModernPasteTarget
    public let clipboard: ModernClipboard
    public let mode: ModernPasteMode
    public let newIDs: [String]
    public let birthKinds: [String]
    public let operations: [WritingOperation]
}
struct ModernPastePlan {
    let command: ModernPaste
    let nodes: [NodeID]
    let caret: WritingPosition?
    let plainCaret: Bool
}

func modernPasteIsOnlyCommand(_ operations: [ModernOperation]) -> Bool {
    var count = 0
    for operation in operations {
        switch operation { case .paste: count += 1; case .retainParagraphRole: break; default: return false }
    }
    return count == 1
}
func modernPasteFrontiers(_ target: ModernPasteTarget) -> [[ChangeID]] {
    [target.range?.observed, target.boundary?.observed, target.selection?.nodes?.observed].compactMap { $0 }
        + (target.selection?.ranges.map(\.observed) ?? [])
}
func modernPasteRanges(_ target: ModernPasteTarget) -> [ModernTextRange] {
    [target.range].compactMap { $0 } + (target.selection?.ranges ?? [])
}
func validateModernPasteRangeProof(_ range: ModernTextRange, history: [ModernChange]) throws {
    let observed = Set(history.map(\.id))
    for position in [range.start, range.end] {
        if case .inserted(let creation, _) = position.field.node { guard observed.contains(creation.change) else { throw EditorError.invalidChange } }
        if let anchor = position.anchor {
            guard anchor.element.change.counter == 0 || observed.contains(anchor.element.change),
                  modernRelatedFields(anchor.origin, position.field, changes: history) else { throw EditorError.invalidChange }
            if case .inserted(let creation, _) = anchor.origin.node { guard observed.contains(creation.change) else { throw EditorError.invalidChange } }
        }
    }
}
func validateModernPasteShape(_ paste: ModernPaste, change: ChangeID) throws {
    let target = paste.target
    guard (target.range != nil) != (target.boundary != nil), target.range == nil || target.selection == nil,
          paste.newIDs.count <= 100_000,
          paste.newIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 10_000 }),
          !paste.operations.isEmpty, paste.operations.count <= 100_000,
          (target.selection?.ranges.count ?? 0) <= 10_000 else { throw EditorError.invalidChange }
    try paste.clipboard.validate()
    for observed in modernPasteFrontiers(target) { try validateObservedFrontier(observed, before: change) }
    if let boundary = target.boundary {
        if let owner = boundary.collection.owner { try modernStructuralIdentityShape(owner) }
        if let after = boundary.after { try modernColumnPlacementShape(after) }
    }
    if let nodes = target.selection?.nodes {
        guard !nodes.nodes.isEmpty, nodes.nodes.count <= 10_000, Set(nodes.nodes).count == nodes.nodes.count else { throw EditorError.invalidChange }
        for node in nodes.nodes { try modernStructuralIdentityShape(node) }
    }
    var elements = Set<ElementID>(), birthIndex = 0
    func field(_ field: WritingField) throws {
        guard ["title", "content", "summary", "caption", "code", "expression"].contains(field.name) else { throw EditorError.invalidChange }
        if case .document = field.node { guard field.name == "title" else { throw EditorError.invalidChange } }
        else { try modernStructuralIdentityShape(field.node) }
    }
    func key(_ key: WritingAtomKey) throws {
        try field(key.origin)
        guard key.element.index >= 0, key.element.index <= 2_147_483_647, key.element.change <= change,
              key.element.change.counter <= 9_007_199_254_740_991,
              key.element.change.counter == 0 ? key.element.change.actor.isEmpty : validToken(key.element.change.actor) else { throw EditorError.invalidChange }
    }
    func keys(_ keys: [WritingAtomKey]) throws {
        guard keys.count <= 100_000, Set(keys).count == keys.count else { throw EditorError.invalidChange }
        for value in keys { try key(value) }
    }
    for range in [target.range].compactMap({ $0 }) + (target.selection?.ranges ?? []) {
        for position in [range.start, range.end] { try field(position.field); if let anchor = position.anchor { try key(anchor) } }
    }
    for operation in paste.operations {
        switch operation {
        case .structure(.insertNode(let value, let node, let collection, let placement, let after)):
            try inspectModernPayload(value)
            guard placement.change == change, placement.index >= 0, placement.index <= 2_147_483_647,
                  node == .inserted(creation: placement, path: []), elements.insert(placement).inserted else { throw EditorError.invalidChange }
            if let owner = collection.owner { try modernStructuralIdentityShape(owner) }
            if let after { try modernColumnPlacementShape(after) }
            guard birthIndex < paste.birthKinds.count, let kind = NodeKind(rawValue: paste.birthKinds[birthIndex]),
                  kind != .document, kind != .column else { throw EditorError.invalidChange }
            try ModernClipboard(parts: [.node(value: value, kind: kind.rawValue)]).validate()
            birthIndex += 1
        case .structure(.deleteNodes(let nodes)):
            guard !nodes.isEmpty, nodes.count <= 100_000, Set(nodes).count == nodes.count else { throw EditorError.invalidChange }
            for node in nodes { try modernStructuralIdentityShape(node) }
        case .structure(.moveNode(let node, let collection, let placement, let after)):
            try modernStructuralIdentityShape(node)
            guard placement.change == change, placement.index >= 0, placement.index <= 2_147_483_647, elements.insert(placement).inserted else { throw EditorError.invalidChange }
            if let owner = collection.owner { try modernStructuralIdentityShape(owner) }
            if let after { try modernColumnPlacementShape(after) }
        case .text(let mutation):
            switch mutation {
            case .insert(let atom):
                try key(atom.key); try inspectModernPayload(atom.node)
                guard atom.key.element.change == change, elements.insert(atom.key.element).inserted else { throw EditorError.invalidChange }
                try Validation.inline(.array([atom.node]), modern: true)
                guard atom.node["type"] == .string("text") ? atom.node["text"]?.string?.unicodeScalars.count == 1 : !plainText([atom.node]).isEmpty else { throw EditorError.invalidChange }
                if let anchor = atom.edge.anchor { try key(anchor) }
                switch atom.route {
                case .field(let origin): guard origin == atom.key.origin, atom.edge == .start else { throw EditorError.invalidChange }
                case .follow(let anchor): guard atom.edge.anchor == anchor else { throw EditorError.invalidChange }; try key(anchor)
                }
            case .delete(let span): guard !span.isEmpty else { throw EditorError.invalidChange }; try keys(span)
            case .transfer(let span, let destination, let edge):
                guard !span.isEmpty else { throw EditorError.invalidChange }; try keys(span); try field(destination); if let anchor = edge.anchor { try key(anchor) }
            case .join(let source, let destination, let edge): try field(source); try field(destination); if let anchor = edge.anchor { try key(anchor) }
            case .spliceBoundary(let source, let destination, let edge, let before, let members):
                try field(source); try field(destination); if let anchor = edge.anchor { try key(anchor) }
                if let before { try modernStructuralIdentityShape(before) }; for node in members { try modernStructuralIdentityShape(node) }
            case .rangeSpliceBoundary(let value):
                try field(value.source); try field(value.destination); try keys(value.endpointKeys)
                if let anchor = value.edge.anchor { try key(anchor) }
                try modernColumnPlacementShape(value.sourcePlacement); try modernColumnPlacementShape(value.endpointPlacement)
                guard value.destinationPlacement.change == change else { throw EditorError.invalidChange }
                for node in value.members { try modernStructuralIdentityShape(node) }
                if let before = value.before { try modernStructuralIdentityShape(before) }
            case .importBoundary(let value):
                try field(value.source); try keys(value.sourceKeys); if let anchor = value.edge.anchor { try key(anchor) }
                try modernColumnPlacementShape(value.sourcePlacement)
                if let after = value.after { try modernColumnPlacementShape(after) }
                if let owner = value.collection.owner { try modernStructuralIdentityShape(owner) }
                if let before = value.before { try modernStructuralIdentityShape(before) }
                for node in value.members { try modernStructuralIdentityShape(node) }
            default: throw EditorError.invalidChange
            }
        default: throw EditorError.invalidChange
        }
    }
    guard birthIndex == paste.birthKinds.count else { throw EditorError.invalidChange }
}

func validateModernPasteBoundary(_ boundary: ModernBlockBoundary, captured: StructuralState, authored: StructuralState) throws -> NodeKind {
    let kind = try captured.kind(in: boundary.collection)
    guard kind == (try authored.kind(in: boundary.collection)), kind != .document, kind != .column else { throw EditorError.invalidPath }
    if let owner = boundary.collection.owner { _ = try captured.address(of: owner); _ = try authored.address(of: owner) }
    if let after = boundary.after {
        guard let origin = captured.placements[after], origin.collection == boundary.collection,
              try captured.effectivePlacements()[origin.node]?.id == after,
              authored.placements[after]?.collection == boundary.collection else { throw EditorError.invalidPath }
        _ = try captured.address(of: origin.node)
    }
    return kind
}

extension ModernSession {
    public func capturePasteBoundary(in collection: NodeCollection = .root, after identity: NodeID? = nil) throws -> ModernBlockBoundary {
        let kind = try structure.kind(in: collection)
        guard kind != .document, kind != .column else { throw EditorError.invalidPath }
        if let owner = collection.owner { _ = try structure.address(of: owner) }
        var after: NodePlacementID?
        if let identity {
            guard try structure.visibleOrder(in: collection).contains(identity), let placement = try structure.effectivePlacements()[identity] else { throw EditorError.invalidPath }
            after = placement.id
        }
        return ModernBlockBoundary(documentID: documentID, epoch: epoch, collection: collection, after: after, observed: modernObserved)
    }
    public func paste(_ clipboard: ModernClipboard, at target: ModernPasteTarget, mode: ModernPasteMode = .rich,
                      newIDs: [String]? = nil, policy: WritingPastePolicy = WritingPastePolicy()) throws -> ModernStructuralResult {
        try authoringAllowed(command: "paste")
        try clipboard.validate()
        try validatePasteCaptures(target)
        let currentField = try target.range.map { range in
            _ = try self.resolve(range.start)
            return try range.start.anchor.map { try self.modernCurrentReplay.0.field(of: $0) } ?? self.modernCurrentReplay.0.destination(of: range.start.field)
        }
        let imported = try modernPasteParts(clipboard, mode: mode, plainField: currentField.map(plainField) ?? false, range: target.range != nil)
        if !imported.isEmpty { try ModernClipboard(parts: imported).validateForPaste(policy: policy) }
        let id = try nextID()
        let plan = try planModernPaste(target: target, clipboard: clipboard, mode: mode, newIDs: newIDs, change: id,
            documentID: documentID, epoch: epoch, captured: { observed in
                try self.modernCapturedWritingReplay(observed)
            }, authored: (modernCurrentReplay.0, structure))
        for (operation, kind) in zip(plan.command.operations.filter { if case .structure(.insertNode) = $0 { return true }; return false }, plan.command.birthKinds) {
            if case .structure(.insertNode(let value, _, _, _, _)) = operation {
                try ModernClipboard(parts: [.node(value: value, kind: kind)]).validateForPaste(policy: policy)
            }
        }
        endTypingGroup()
        func result(_ replay: (WritingProjection, ModernDocument, StructuralState), _ observed: [ChangeID]) throws -> ModernStructuralResult {
            if let caret = plan.caret {
                _ = try resolveWritingPosition(caret, projection: replay.0, structure: replay.2) { _ in nil }
                return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
            }
            if plan.nodes.isEmpty {
                let boundary = target.boundary
                let collection = boundary.map { (try? replay.2.kind(in: $0.collection)) != nil ? $0.collection : .root } ?? .root
                return ModernStructuralResult(focus: .insertion(ModernBlockBoundary(documentID: self.documentID, epoch: self.epoch,
                    collection: collection, after: boundary?.after, observed: observed)), selection: nil)
            }
            let selected = ModernNodeSelection(documentID: self.documentID, epoch: self.epoch, nodes: plan.nodes, observed: observed)
            if let field = try self.editableFields(in: plan.nodes, structure: replay.2).first {
                return ModernStructuralResult(focus: .text(self.edgePosition(field, projection: replay.0, end: false)), selection: .nodes(selected))
            }
            return ModernStructuralResult(focus: .nodes(selected), selection: .nodes(selected))
        }
        if plan.command.operations.isEmpty { return try result(modernCurrentReplay, modernObserved) }
        try validateModernPasteShape(plan.command, change: id)
        return try performReturning(id, [.paste(plan.command)], result: result)
    }
}
