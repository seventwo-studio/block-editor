import Foundation

/// Retained cut proof. Replay compares it with the captured and authored cohorts;
/// callers cannot introduce arbitrary transfers or collection writes.
public struct ModernBlockSplit: Codable, Equatable, Sendable {
    public let range: ModernTextRange
    public let creation: ElementID
    public let source: WritingField
    public let value: JSONValue
    public let item: Bool
    public let collection: NodeCollection
    public let after: NodePlacementID
    public let before: NodeID?
    public let edge: WritingEdge
    public let selected: [WritingAtomKey]
    public let prefix: [WritingAtomKey]
    public let suffix: [WritingAtomKey]
    public var identity: NodeID { .inserted(creation: creation, path: []) }
    public var destination: WritingField { WritingField(node: identity, name: "content") }
    var writingOperations: [WritingOperation] {
        writingSplitOperations(value: value, identity: identity, collection: collection, creation: creation, after: after,
            source: source, destination: destination, edge: edge, before: before, selected: selected, prefix: prefix, suffix: suffix)
    }
    var birth: Mutation { .insertNode(value: value, identity: identity, collection: collection, placement: creation, after: after) }
}
public struct ModernBlockJoin: Codable, Equatable, Sendable {
    public let selection: ModernNodeSelection
    public let edge: WritingEdge
    var source: WritingField { WritingField(node: selection.nodes[1], name: "content") }
    var destination: WritingField { WritingField(node: selection.nodes[0], name: "content") }
}

func validateModernSplitShape(_ split: ModernBlockSplit, change: ChangeID) throws {
    guard split.creation.change == change, split.creation.index >= 0, split.creation.index <= 2_147_483_647,
          split.range.start.field == split.range.end.field, split.source.name == "content",
          ["content", "code"].contains(split.range.start.field.name), split.range.observed.count <= 100_000,
          split.value["id"]?.string?.isEmpty == false else { throw EditorError.invalidChange }
    try modernStructuralIdentityShape(split.source.node)
    try modernStructuralIdentityShape(split.range.start.field.node)
    if let owner = split.collection.owner { try modernStructuralIdentityShape(owner) }
    try modernColumnPlacementShape(split.after)
    if let before = split.before { try modernStructuralIdentityShape(before) }
    try validateNode(split.value, kind: split.item ? .item : .block, modern: true)
    guard split.item || split.value["type"] == .string("paragraph") else { throw EditorError.invalidChange }
    let all = split.selected + split.prefix + split.suffix
    guard all.count <= 100_000, Set(all).count == all.count else { throw EditorError.invalidChange }
}

/// Derive the admitted cut from original capture atoms and the author's live
/// placements. Later peer atoms keep their existing follow routes.
func planModernSplit(range: ModernTextRange, creation: ElementID, label: String,
                     captured: (WritingProjection, StructuralState), authored: (WritingProjection, StructuralState)) throws -> ModernBlockSplit {
    guard range.start.field == range.end.field else { throw EditorError.invalidRange }
    let first = try resolveWritingPosition(range.start, projection: captured.0, structure: captured.1) { _ in nil }
    let last = try resolveWritingPosition(range.end, projection: captured.0, structure: captured.1) { _ in nil }
    guard first.address == last.address else { throw EditorError.invalidRange }
    let capturedField = try range.start.anchor.map { try captured.0.field(of: $0) } ?? captured.0.destination(of: range.start.field)
    let source = try range.start.anchor.map { try authored.0.field(of: $0) } ?? authored.0.destination(of: range.start.field)
    let end = try range.end.anchor.map { try authored.0.field(of: $0) } ?? authored.0.destination(of: range.end.field)
    guard source == end, source.name == "content", let original = authored.1.nodes[source.node],
          original.kind == .item || (original.kind == .block && ["paragraph", "heading", "quote", "callout"].contains(original.fields["type"]?.string ?? "")) else { throw EditorError.invalidPath }
    _ = try authored.1.address(of: source.node)
    let lower = min(first.offset, last.offset), upper = max(first.offset, last.offset)
    var cursor = 0, prefix: [WritingAtomKey] = [], selected: [WritingAtomKey] = [], suffix: [WritingAtomKey] = []
    var boundaries: Set<Int> = [0]
    for key in captured.0.visibleKeys(in: capturedField) {
        let start = cursor; cursor += plainText([try captured.0.value(of: key)]).utf16.count; boundaries.insert(cursor)
        let sameField = try authored.0.field(of: key) == source
        if start < lower { if sameField { prefix.append(key) } }
        else if start < upper { guard sameField else { throw EditorError.invalidRange }; selected.append(key) }
        else if sameField { suffix.append(key) }
    }
    guard boundaries.contains(lower), boundaries.contains(upper) else { throw EditorError.invalidRange }
    let placements = try authored.1.effectivePlacements()
    guard let parent = placements[source.node] else { throw EditorError.invalidPath }
    let siblings = try authored.1.visibleOrder(in: parent.collection)
    guard let index = siblings.firstIndex(of: source.node), !label.isEmpty,
          !siblings.contains(where: { authored.1.nodes[$0]?.label == label }) else { throw EditorError.invalidChange }
    var fields: [String: JSONValue]
    if original.kind == .item {
        fields = original.fields; fields["id"] = .string(label); fields["content"] = .array([])
        if original.collections.contains("children") { fields["children"] = .array([]) }
        var owner = parent.collection.owner
        while let candidate = owner, authored.1.nodes[candidate]?.kind == .item { owner = placements[candidate]?.collection.owner }
        if owner.flatMap({ authored.1.nodes[$0]?.fields["style"] }) == .string("todo") { fields["checked"] = .bool(false) }
    } else { fields = ["id": .string(label), "type": .string("paragraph"), "content": .array([])] }
    let edge: WritingEdge = prefix.last.map(WritingEdge.after) ?? (selected.first ?? suffix.first).map(WritingEdge.before) ?? .start
    return ModernBlockSplit(range: range, creation: creation, source: source, value: .object(fields), item: original.kind == .item,
        collection: parent.collection, after: parent.id, before: index + 1 < siblings.count ? siblings[index + 1] : nil,
        edge: edge, selected: selected, prefix: prefix, suffix: suffix)
}

func validateModernJoin(_ join: ModernBlockJoin, structure: StructuralState, projection: WritingProjection) throws {
    let nodes = join.selection.nodes
    guard nodes.count == 2, nodes[0] != nodes[1],
          let left = structure.nodes[nodes[0]], let right = structure.nodes[nodes[1]],
          left.kind == .block, right.kind == .block, left.fields["type"] == .string("paragraph"), right.fields["type"] == .string("paragraph"),
          right.collections.isEmpty, Set(right.fields.keys).isSubset(of: ["id", "type", "content"]) else { throw EditorError.invalidPath }
    _ = try structure.address(of: nodes[0]); _ = try structure.address(of: nodes[1])
    let placements = try structure.effectivePlacements()
    guard let parent = placements[nodes[0]], placements[nodes[1]]?.collection == parent.collection else { throw EditorError.invalidPath }
    let siblings = try structure.visibleOrder(in: parent.collection)
    guard let index = siblings.firstIndex(of: nodes[0]), index + 1 < siblings.count, siblings[index + 1] == nodes[1],
          join.edge == (projection.visibleKeys(in: join.destination).last.map(WritingEdge.after) ?? .start) else { throw EditorError.invalidPath }
}

func modernRelatedFields(_ first: WritingField, _ second: WritingField, changes: [ModernChange]) -> Bool {
    if first == second { return true }
    var graph: [WritingField: Set<WritingField>] = [:]
    for change in changes {
        guard case .edit(let operations) = change.body else { continue }
        for operation in operations {
            if case .paste(let paste) = operation {
                for nested in paste.operations {
                    var pairs: [(WritingField, WritingField)] = []
                    switch nested {
                    case .text(.transfer(let keys, let destination, _)): pairs = keys.map { ($0.origin, destination) }
                    case .text(.join(let source, let destination, _)), .text(.spliceBoundary(let source, let destination, _, _, _)): pairs = [(source, destination)]
                    case .text(.rangeSpliceBoundary(let splice)): pairs = [(splice.source, splice.destination)]
                    default: break
                    }
                    for pair in pairs { graph[pair.0, default: []].insert(pair.1); graph[pair.1, default: []].insert(pair.0) }
                }
                continue
            }
            let pair: (WritingField, WritingField)
            switch operation {
            case .schemaConvert(let conversion): pair = (conversion.source, conversion.destination)
            case .enterListItem(let enter):
                guard let conversion = enter.operations.compactMap({ if case .schemaConvert(let value) = $0 { return value }; return nil }).first else { continue }
                pair = (conversion.source, conversion.destination)
            case .splitBlock(let split): pair = (split.source, split.destination)
            case .mergeBlocks(let join) where join.selection.nodes.count == 2: pair = (join.source, join.destination)
            default: continue
            }
            graph[pair.0, default: []].insert(pair.1); graph[pair.1, default: []].insert(pair.0)
        }
    }
    var pending = [first], seen = Set<WritingField>()
    while let field = pending.popLast() {
        if field == second { return true }
        if seen.insert(field).inserted { pending.append(contentsOf: graph[field] ?? []) }
    }
    return false
}

extension ModernSession {
    public func splitBlock(in range: ModernTextRange, newBlockID: String) throws -> ModernStructuralResult {
        try authoringAllowed(command: "splitBlock")
        let captured = try modernCapturedReplay(range.observed)
        let first = try modernResolve(range.start, in: captured, observed: range.observed)
        let last = try modernResolve(range.end, in: captured, observed: range.observed)
        if first.address == last.address, first.offset == last.offset {
            let caret = try modernCapturedCaret(range), source = caret.field
            if structure.nodes[source.node]?.kind == .item,
               modernCurrentReplay.0.nodes(in: source).allSatisfy({ $0["type"] == .string("text") && ($0["text"]?.string ?? "").isEmpty }) {
                let id = try nextID()
                let enter = try planModernEmptyEnter(range: range, newBlockID: newBlockID, change: id,
                    captured: (captured.0, captured.2), authored: (modernCurrentReplay.0, structure))
                endTypingGroup()
                return try performReturning(id, [.enterListItem(enter)], historyBefore: historySelection(range)) { _, _ in
                    ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
                }
            }
        }
        let id = try nextID(), creation = ElementID(change: id, index: 0)
        let split = try planModernSplit(range: range, creation: creation, label: newBlockID,
            captured: (captured.0, captured.2), authored: (modernCurrentReplay.0, structure))
        endTypingGroup()
        return try performReturning(id, [.splitBlock(split)], historyBefore: historySelection(range)) { _, _ in
            let caret = WritingPosition(documentID: self.documentID, epoch: self.epoch, field: split.destination,
                anchor: split.suffix.first, affinity: split.suffix.isEmpty ? .after : .before)
            return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
        }
    }
    public func mergeBlocks(_ selection: ModernNodeSelection) throws -> ModernStructuralResult {
        try authoringAllowed(command: "mergeBlocks"); try validateTargetScope(selection.documentID, selection.epoch)
        try validateSelectedNodes(selection.nodes, in: modernCapturedStructure(selection.observed))
        guard selection.nodes.count == 2 else { throw EditorError.invalidPath }
        let destination = WritingField(node: selection.nodes[0], name: "content")
        let anchor = modernCurrentReplay.0.visibleKeys(in: destination).last
        let join = ModernBlockJoin(selection: selection, edge: anchor.map(WritingEdge.after) ?? .start)
        try validateModernJoin(join, structure: structure, projection: modernCurrentReplay.0)
        endTypingGroup()
        return try performReturning(nextID(), [.mergeBlocks(join)], historyBefore: historySelection(selection)) { _, _ in
            let caret = WritingPosition(documentID: self.documentID, epoch: self.epoch, field: destination, anchor: anchor, affinity: .after)
            return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
        }
    }
}
