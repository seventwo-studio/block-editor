import Foundation

/// Local, atom/origin-anchored input state. Native hosts capture their actual
/// selection before authoring; none is an explicit absence of a document target.
public final class ModernLocalSelection: Codable, Equatable, Sendable {
    public let documentID: String
    public let epoch: String
    public let observed: [ChangeID]
    public let focus: ModernFocusIntent?
    public let selection: ModernSelectionIntent?
    public static func == (lhs: ModernLocalSelection, rhs: ModernLocalSelection) -> Bool {
        lhs.documentID == rhs.documentID && lhs.epoch == rhs.epoch && lhs.observed == rhs.observed && lhs.focus == rhs.focus && lhs.selection == rhs.selection
    }
    public init(documentID: String, epoch: String, observed: [ChangeID], focus: ModernFocusIntent?, selection: ModernSelectionIntent?) {
        self.documentID = documentID; self.epoch = epoch; self.observed = observed; self.focus = focus; self.selection = selection
    }
}
struct ModernHistorySelectionOverride { let value: ModernLocalSelection? }
struct ModernHistorySelectionRecord: Codable, Equatable {
    let edits: [ChangeID]
    let before: ModernLocalSelection?
    let after: ModernLocalSelection?
}
private struct ModernHistorySelectionArchive: Codable, Equatable {
    let version: Int
    let documentID: String
    let epoch: String
    let actorID: String
    let current: ModernLocalSelection?
    let records: [ModernHistorySelectionRecord]
}

extension ModernSession {
    /// Captured invocation state may precede a delayed provider result. The
    /// override affects only this action's local history, not accepted content
    /// or the host's active selection before publication.
    public func withHistorySelection<Result>(_ before: ModernLocalSelection?, perform: () throws -> Result) throws -> Result {
        guard modernHistorySelectionOverride == nil else { throw EditorError.invalidChange }
        if let before { try validateLocalSelection(before) }
        modernHistorySelectionOverride = ModernHistorySelectionOverride(value: before)
        defer { modernHistorySelectionOverride = nil }
        return try perform()
    }
    func historySelection(_ range: ModernTextRange) -> ModernLocalSelection {
        ModernLocalSelection(documentID: documentID, epoch: epoch, observed: range.observed,
            focus: .text(range.end), selection: .text(WritingTextRange(start: range.start, end: range.end)))
    }
    func historySelection(_ nodes: ModernNodeSelection, caret: WritingPosition? = nil) -> ModernLocalSelection {
        ModernLocalSelection(documentID: documentID, epoch: epoch, observed: modernObserved,
            focus: caret.map(ModernFocusIntent.text) ?? .nodes(nodes), selection: .nodes(nodes))
    }
    func historySelection(_ boundary: ModernBlockBoundary) -> ModernLocalSelection {
        ModernLocalSelection(documentID: documentID, epoch: epoch, observed: boundary.observed, focus: .insertion(boundary), selection: nil)
    }
    func historySelection(_ target: ModernDeleteTarget) -> ModernLocalSelection {
        if target.nodes == nil, target.ranges.count == 1 { return historySelection(target.ranges[0]) }
        if target.ranges.isEmpty, let nodes = target.nodes { return historySelection(nodes) }
        return ModernLocalSelection(documentID: documentID, epoch: epoch, observed: modernObserved,
            focus: target.ranges.last.map { .text($0.end) } ?? target.nodes.map(ModernFocusIntent.nodes), selection: .mixed(target))
    }
    /// Selection/focus changes end ordinary typing grouping, but applying the
    /// already-current command result does not split an adjacent input group.
    public func setLocalSelection(_ value: ModernLocalSelection?) throws {
        _ = try checkedHistorySelectionArchive(modernHistorySelections, current: value)
        if let value { try validateLocalSelection(value) }
        if !sameLocalSelection(value, modernLocalSelectionStorage) { endTypingGroup() }
        modernLocalSelectionStorage = value
    }
    public func captureLocalSelection(focus: ModernFocusIntent?, selection: ModernSelectionIntent?) throws -> ModernLocalSelection {
        let value = ModernLocalSelection(documentID: documentID, epoch: epoch, observed: modernObserved, focus: focus, selection: selection)
        try validateLocalSelection(value); return value
    }
    public func captureLocalNodes(_ nodes: [NodeID]) throws -> ModernNodeSelection {
        try validateLocalNodes(nodes, in: structure)
        return ModernNodeSelection(documentID: documentID, epoch: epoch, nodes: nodes, observed: modernObserved)
    }
    private func validateLocalNodes(_ nodes: [NodeID], in shape: StructuralState) throws {
        guard !nodes.isEmpty, nodes.count <= 10_000, Set(nodes).count == nodes.count else { throw EditorError.invalidPath }
        for node in nodes {
            _ = try shape.address(of: node)
            guard let kind = shape.nodes[node]?.kind, kind != .document, kind != .column else { throw EditorError.invalidPath }
            let descendants = Set(try shape.descendants(of: node))
            guard !nodes.contains(where: { $0 != node && descendants.contains($0) }) else { throw EditorError.invalidPath }
        }
        guard try logicalNodes(shape).filter({ nodes.contains($0) }) == nodes else { throw EditorError.invalidPath }
    }
    /// Peer receive returns no focus transfer. Hosts may resolve their local
    /// anchors here and apply them only while their input still owns focus.
    public func resolvedLocalSelection() throws -> ModernLocalSelection? {
        try modernResolveLocalSelection(modernLocalSelectionStorage, in: modernCurrentReplay, observed: modernObserved)
    }
    /// Persist beside modernSave in the host's same durable transaction. Keeping
    /// local selection data separate preserves accepted-history admission limits.
    public func exportHistorySelection() throws -> Data {
        try checkedHistorySelectionArchive(modernHistorySelections, current: modernLocalSelectionStorage)
    }
    public func restoreHistorySelection(_ data: Data) throws {
        guard modernHistorySelections.isEmpty, modernLocalSelectionStorage == nil else { throw EditorError.invalidChange }
        guard data.count <= 16_000_000 else { throw EditorError.recoveryCapacityExceeded }
        let wire = try modernWireValue(data)
        let value = try JSONDecoder().decode(ModernHistorySelectionArchive.self, from: canonicalEncoder().encode(wire))
        guard try modernWireValue(canonicalEncoder().encode(value)) == wire, value.version == 1,
              value.documentID == documentID, value.epoch == epoch, value.actorID == actorID,
              value.records.count <= 100_000 else { throw EditorError.invalidChange }
        let known = Set(modernHistoryGroups.flatMap { $0 })
        var records: [ChangeID: ModernHistorySelectionRecord] = [:], recorded = Set<ChangeID>()
        for record in value.records {
            guard !record.edits.isEmpty, record.edits.count <= 100_000,
                  record.edits == record.edits.sorted(), Set(record.edits).count == record.edits.count,
                  record.edits.contains(where: { known.contains($0) }), record.before != nil || record.after != nil else { throw EditorError.invalidChange }
            for id in record.edits {
                guard recorded.insert(id).inserted, id.actor == actorID,
                      case .edit? = modernHistoryChange(id)?.body else { throw EditorError.invalidChange }
            }
            let bounds = try modernHistoryBounds(record.edits)
            if let before = record.before { try validateLocalSelection(before, boundedBy: bounds.before) }
            if let after = record.after { try validateLocalSelection(after, boundedBy: bounds.after) }
            records[record.edits[0]] = record
        }
        if let current = value.current { try validateLocalSelection(current) }
        _ = try checkedHistorySelectionArchive(records, current: value.current)
        modernHistorySelections = records; modernLocalSelectionStorage = value.current
    }
    func checkedHistorySelectionArchive(_ records: [ChangeID: ModernHistorySelectionRecord], current: ModernLocalSelection?) throws -> Data {
        let archive = ModernHistorySelectionArchive(version: 1, documentID: documentID, epoch: epoch, actorID: actorID,
            current: current, records: records.values.sorted { $0.edits[0] < $1.edits[0] })
        let data = try canonicalEncoder().encode(archive)
        guard data.count <= 16_000_000 else { throw EditorError.recoveryCapacityExceeded }
        return data
    }
    func planHistorySelection<Result>(_ id: ChangeID, priorGroup: [ChangeID]?, outcome: Result,
        observed: [ChangeID], defaultBefore: ModernLocalSelection?) throws -> (records: [ChangeID: ModernHistorySelectionRecord], current: ModernLocalSelection?) {
        let before: ModernLocalSelection?
        if let override = modernHistorySelectionOverride { before = override.value }
        else { before = modernLocalSelectionStorage ?? defaultBefore }
        let after: ModernLocalSelection?
        if let result = outcome as? ModernStructuralResult {
            after = ModernLocalSelection(documentID: documentID, epoch: epoch, observed: observed, focus: result.focus, selection: result.selection)
        } else if let position = outcome as? WritingPosition {
            after = ModernLocalSelection(documentID: documentID, epoch: epoch, observed: observed, focus: .text(position), selection: .text(WritingTextRange(start: position, end: position)))
        } else { after = before }
        var records = modernHistorySelections
        if let priorGroup, let record = historySelectionRecord(for: priorGroup) {
            records[record.edits[0]] = ModernHistorySelectionRecord(edits: record.edits + [id], before: record.before, after: after)
        } else if before != nil || after != nil {
            records[id] = ModernHistorySelectionRecord(edits: [id], before: before, after: after)
        }
        // A new author edit clears Redo; release its obsolete local records before
        // checking capacity. A partially active original group retains its proof.
        let retained = Set(modernHistoryGroups.prefix(modernHistoryUndoCount).flatMap { $0 } + [id])
        records = records.filter { $0.value.edits.contains(where: { retained.contains($0) }) }
        _ = try checkedHistorySelectionArchive(records, current: after)
        return (records, after)
    }
    func historySelectionRecord(for group: [ChangeID]) -> ModernHistorySelectionRecord? {
        guard !group.isEmpty else { return nil }
        return modernHistorySelections.values.first { record in group.allSatisfy { record.edits.contains($0) } }
    }
    func pruneHistorySelection() {
        let known = Set(modernHistoryGroups.flatMap { $0 })
        modernHistorySelections = modernHistorySelections.filter { $0.value.edits.contains(where: { known.contains($0) }) }
    }
    private func validateLocalSelection(_ value: ModernLocalSelection, boundedBy bound: Set<ChangeID>? = nil) throws {
        try validateTargetScope(value.documentID, value.epoch)
        let cohort = try modernHistoryCohort(value.observed)
        if let bound { guard cohort.isSubset(of: bound) else { throw EditorError.invalidChange } }
        let replay = try modernHistoryReplay(value.observed)
        func position(_ p: WritingPosition) throws { _ = try modernResolve(p, in: replay, observed: value.observed) }
        func contained(_ observed: [ChangeID]) throws {
            guard try modernHistoryCohort(observed).isSubset(of: cohort) else { throw EditorError.invalidChange }
        }
        func nodes(_ selected: ModernNodeSelection) throws {
            try validateTargetScope(selected.documentID, selected.epoch); try contained(selected.observed)
            let capture = try modernHistoryReplay(selected.observed)
            try validateLocalNodes(selected.nodes, in: capture.2)
            for node in selected.nodes { _ = try replay.2.address(of: node) }
        }
        func mixed(_ target: ModernDeleteTarget) throws {
            guard target.nodes != nil || !target.ranges.isEmpty, target.ranges.count <= 10_000 else { throw EditorError.invalidPath }
            if let selected = target.nodes { try nodes(selected) }
            for range in target.ranges {
                try contained(range.observed)
                let captured = try modernHistoryReplay(range.observed)
                _ = try modernResolve(range.start, in: captured, observed: range.observed)
                _ = try modernResolve(range.end, in: captured, observed: range.observed)
                try position(range.start); try position(range.end)
            }
        }
        if let focus = value.focus {
            switch focus {
            case .text(let caret): try position(caret)
            case .nodes(let selected): try nodes(selected)
            case .insertion(let boundary):
                try validateTargetScope(boundary.documentID, boundary.epoch); try contained(boundary.observed)
                let captured = try modernHistoryReplay(boundary.observed).2
                try modernLocalCollection(boundary.collection, structure: captured)
                try modernLocalCollection(boundary.collection, structure: replay.2)
                if let owner = boundary.collection.owner { _ = try captured.address(of: owner); _ = try replay.2.address(of: owner) }
                if let after = boundary.after {
                    guard let placed = captured.placements[after], placed.collection == boundary.collection,
                          try captured.effectivePlacements()[placed.node]?.id == after else { throw EditorError.invalidPath }
                    _ = try captured.address(of: placed.node)
                    guard replay.2.placements[after]?.collection == boundary.collection else { throw EditorError.invalidPath }
                }
            }
        }
        if let selection = value.selection {
            switch selection {
            case .text(let range): try position(range.start); try position(range.end)
            case .nodes(let selected): try nodes(selected)
            case .mixed(let target): try mixed(target)
            }
        }
    }
    func modernResolveLocalSelection(_ value: ModernLocalSelection?, in replay: (WritingProjection, ModernDocument, StructuralState),
        observed: [ChangeID], history: [ChangeID: ModernChange]? = nil) throws -> ModernLocalSelection? {
        guard let value else { return nil }
        let shape = replay.2
        func position(_ p: WritingPosition) -> WritingPosition? {
            (try? modernResolve(p, in: replay, history: history)) == nil ? nil : p
        }
        func nodes(_ selected: ModernNodeSelection) throws -> ModernNodeSelection? {
            let surviving = Set(selected.nodes.filter { (try? shape.address(of: $0)) != nil })
            let order = try logicalNodes(shape).filter { surviving.contains($0) }
            var roots: [NodeID] = [], descendants = Set<NodeID>()
            for node in order where !descendants.contains(node) { roots.append(node); descendants.formUnion(try shape.descendants(of: node)) }
            return roots.isEmpty ? nil : ModernNodeSelection(documentID: documentID, epoch: epoch, nodes: roots, observed: observed)
        }
        func range(_ selected: WritingTextRange) -> WritingTextRange? {
            let start = position(selected.start), end = position(selected.end)
            if let start, let end { return WritingTextRange(start: start, end: end) }
            if let caret = start ?? end { return WritingTextRange(start: caret, end: caret) }
            return nil
        }
        var focus: ModernFocusIntent?, selection: ModernSelectionIntent?
        if let source = value.focus {
            switch source {
            case .text(let caret): focus = position(caret).map(ModernFocusIntent.text)
            case .nodes(let selected): focus = try nodes(selected).map(ModernFocusIntent.nodes)
            case .insertion(let boundary):
                if (try? modernLocalCollection(boundary.collection, structure: shape)) != nil,
                   boundary.collection.owner.map({ (try? shape.address(of: $0)) != nil }) ?? true {
                    focus = .insertion(boundary)
                }
            }
        }
        if let source = value.selection {
            switch source {
            case .text(let selected): selection = range(selected).map(ModernSelectionIntent.text)
            case .nodes(let selected): selection = try nodes(selected).map(ModernSelectionIntent.nodes)
            case .mixed(let target):
                let selected = try target.nodes.flatMap(nodes)
                let ranges = target.ranges.compactMap { r -> ModernTextRange? in
                    range(WritingTextRange(start: r.start, end: r.end)).map { ModernTextRange(start: $0.start, end: $0.end, observed: observed) }
                }
                if selected != nil || !ranges.isEmpty { selection = .mixed(ModernDeleteTarget(nodes: selected, ranges: ranges)) }
            }
        }
        if focus == nil, value.focus != nil {
            if case .text(let range) = selection { focus = .text(range.end) }
            else if case .nodes(let nodes) = selection { focus = .nodes(nodes) }
            else if case .mixed(let target) = selection {
                if let last = target.ranges.last { focus = .text(last.end) }
                else if let nodes = target.nodes { focus = .nodes(nodes) }
            }
            if focus == nil {
                let fallback = try historySelectionFallback(value, replay: replay)
                focus = fallback.focus; selection = fallback.selection
            }
        }
        // No focus was an explicit local absence, including menus/external
        // controls. A surviving selection must not fabricate a focus transfer.
        return ModernLocalSelection(documentID: documentID, epoch: epoch, observed: observed, focus: focus, selection: selection)
    }
    private func historySelectionFallback(_ value: ModernLocalSelection, replay: (WritingProjection, ModernDocument, StructuralState)) throws -> ModernStructuralResult {
        let captured = try modernHistoryReplay(value.observed).2
        let order = try logicalNodes(captured)
        let origin: NodeID?
        switch value.focus {
        case .text(let caret): origin = caret.field.node
        case .nodes(let nodes): origin = nodes.nodes.first
        case .insertion(let boundary): origin = boundary.collection.owner ?? boundary.after.flatMap { captured.placements[$0]?.node }
        case nil: origin = nil
        }
        let index = origin.flatMap { order.firstIndex(of: $0) } ?? 0
        for node in order.dropFirst(index + (origin == nil ? 0 : 1)) where (try? replay.2.address(of: node)) != nil {
            if let field = try editableFields(in: [node], structure: replay.2).first {
                let caret = edgePosition(field, projection: replay.0, end: false)
                return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
            }
        }
        for node in order.prefix(index).reversed() where (try? replay.2.address(of: node)) != nil {
            if let field = try editableFields(in: [node], structure: replay.2).last {
                let caret = edgePosition(field, projection: replay.0, end: true)
                return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
            }
        }
        if replay.1.blocks.isEmpty {
            return ModernStructuralResult(focus: .insertion(ModernBlockBoundary(documentID: documentID, epoch: epoch, collection: .root, after: nil, observed: modernObserved)), selection: nil)
        }
        let caret = edgePosition(titleField, projection: replay.0, end: true)
        return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
    }
}

private func sameLocalSelection(_ lhs: ModernLocalSelection?, _ rhs: ModernLocalSelection?) -> Bool {
    guard let lhs, let rhs else { return lhs == rhs }
    guard lhs.documentID == rhs.documentID, lhs.epoch == rhs.epoch else { return false }
    func nodes(_ a: ModernNodeSelection, _ b: ModernNodeSelection) -> Bool { a.documentID == b.documentID && a.epoch == b.epoch && a.nodes == b.nodes }
    func focus(_ a: ModernFocusIntent?, _ b: ModernFocusIntent?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case (.text(let a),.text(let b)): return a == b
        case (.nodes(let a),.nodes(let b)): return nodes(a,b)
        case (.insertion(let a),.insertion(let b)): return a.documentID == b.documentID && a.epoch == b.epoch && a.collection == b.collection && a.after == b.after
        default: return false
        }
    }
    func selected(_ a: ModernSelectionIntent?, _ b: ModernSelectionIntent?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case (.text(let a),.text(let b)): return a == b
        case (.nodes(let a),.nodes(let b)): return nodes(a,b)
        case (.mixed(let a),.mixed(let b)):
            let sameNodes: Bool
            if let aa = a.nodes, let bb = b.nodes { sameNodes = nodes(aa,bb) } else { sameNodes = a.nodes == b.nodes }
            return sameNodes && a.ranges.map { WritingTextRange(start: $0.start, end: $0.end) } == b.ranges.map { WritingTextRange(start: $0.start, end: $0.end) }
        default: return false
        }
    }
    return focus(lhs.focus,rhs.focus) && selected(lhs.selection,rhs.selection)
}

private func modernLocalCollection(_ collection: NodeCollection, structure: StructuralState) throws {
    let kind = try structure.kind(in: collection)
    guard kind != .document, kind != .column else { throw EditorError.invalidPath }
    if let owner = collection.owner { _ = try structure.address(of: owner) }
}
