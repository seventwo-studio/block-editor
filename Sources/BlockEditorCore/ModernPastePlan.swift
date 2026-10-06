import Foundation

func modernPasteParts(_ clipboard: ModernClipboard, mode: ModernPasteMode, plainField: Bool, range: Bool = false) throws -> [WritingClipboardPart] {
    switch mode {
    case .rich: return clipboard.parts
    case .plainText:
        if plainField { return try ModernClipboard.plain(clipboard.plainText).parts }
        var parts = try ModernClipboard.multiline(clipboard.plainText).parts
        if range {
            if case .node(let value, _)? = parts.first { parts[0] = .inline(value["content"]?.array ?? []) }
            if parts.count > 1, case .node(let value, _)? = parts.last { parts[parts.count - 1] = .inline(value["content"]?.array ?? []) }
        }
        return parts
    case .flattenedColumns:
        return clipboard.parts.flatMap { part in
            guard case .node(let value, "block") = part, value["type"] == .string("columns") else { return [part] }
            return (value["columns"]?.array ?? []).flatMap { column in
                (column["children"]?.array ?? []).map { WritingClipboardPart.node(value: $0, kind: "block") }
            }
        }
    }
}
func modernPasteLogicalNodes(_ shape: StructuralState) throws -> [NodeID] {
    var result: [NodeID] = [], pending = Array(try shape.visibleOrder(in: .root).reversed())
    while let node = pending.popLast() {
        result.append(node)
        let fields = StructuralState.collectionFields(shape.nodes[node]!.kind, shape.nodes[node]!.fields, modern: true)
        for name in ["columns", "items", "children", "rows", "cells"].reversed() where fields[name] != nil {
            pending.append(contentsOf: try shape.visibleOrder(in: NodeCollection(owner: node, field: name)).reversed())
        }
    }
    return result
}
private func modernPasteNodes(_ selection: ModernNodeSelection, in shape: StructuralState) throws {
    let nodes = selection.nodes, selected = Set(nodes)
    guard !nodes.isEmpty, nodes.count <= 10_000, selected.count == nodes.count,
          try modernPasteLogicalNodes(shape).filter({ selected.contains($0) }) == nodes else { throw EditorError.invalidPath }
    for node in nodes {
        _ = try shape.address(of: node)
        guard shape.nodes[node]?.kind == .block,
              selected.isDisjoint(with: Set(try shape.descendants(of: node)).subtracting([node])) else { throw EditorError.invalidPath }
    }
}
private struct ModernPasteRangeSelection {
    let source: WritingField
    let endpoint: WritingField
    let keys: [WritingAtomKey]
    let deleted: [NodeID]
    let prefix: [WritingAtomKey]
    let suffix: [WritingAtomKey]
    let edge: WritingEdge
    let caret: WritingPosition
    let startsAtZero: Bool
    let sourceRouted: [WritingAtomKey]
    let endpointRouted: [WritingAtomKey]
}
private func modernPasteSelected(_ range: ModernTextRange, captured: (WritingProjection, StructuralState), authored: (WritingProjection, StructuralState)) throws -> ModernPasteRangeSelection {
    var first = range.start, last = range.end
    let fields = retainedWritingFields(captured.1)
    var ordered = try modernPasteLogicalNodes(captured.1).flatMap { node in
        ["content", "summary", "caption", "code", "expression"].map { WritingField(node: node, name: $0) }.filter { fields[$0] != nil }
    }
    if case .document = first.field.node {
        guard first.field == last.field, first.field.name == "title" else { throw EditorError.invalidPath }; ordered = [first.field]
    } else if case .document = last.field.node { throw EditorError.invalidPath }
    func resolved(_ position: WritingPosition, in replay: (WritingProjection, StructuralState)) throws -> (WritingField, Int) {
        guard replay.0.hasField(position.field), position.anchor.map({ replay.0.retainedKeys.contains($0) }) ?? true else { throw EditorError.invalidChange }
        let value = try resolveWritingPosition(position, projection: replay.0, structure: replay.1) { _ in nil }
        let field = try position.anchor.map { try replay.0.field(of: $0) } ?? replay.0.destination(of: position.field)
        return (field, value.offset)
    }
    var a = try resolved(first, in: captured), b = try resolved(last, in: captured)
    guard let ai = ordered.firstIndex(of: a.0), let bi = ordered.firstIndex(of: b.0) else { throw EditorError.invalidPath }
    if ai > bi || (ai == bi && a.1 > b.1) { swap(&first, &last); swap(&a, &b) }
    let lower = ordered.firstIndex(of: a.0)!, upper = ordered.firstIndex(of: b.0)!
    let source = try resolved(first, in: authored).0, endpoint = try resolved(last, in: authored).0
    var keys: [WritingAtomKey] = [], prefix: [WritingAtomKey] = [], suffix: [WritingAtomKey] = []
    for (index, field) in ordered.enumerated() where (lower...upper).contains(index) {
        let start = index == lower ? a.1 : 0, end = index == upper ? b.1 : captured.0.text(in: field).utf16.count
        var cursor = 0, boundaries: Set<Int> = [0]
        for key in captured.0.visibleKeys(in: field) {
            let offset = cursor; cursor += plainText([try captured.0.value(of: key)]).utf16.count; boundaries.insert(cursor)
            if offset < start { if try authored.0.field(of: key) == source { prefix.append(key) } }
            else if offset < end { keys.append(key) }
            else if index == upper, try authored.0.field(of: key) == endpoint { suffix.append(key) }
        }
        guard boundaries.contains(start), boundaries.contains(end) else { throw EditorError.invalidRange }
    }
    var removed = Set<NodeID>()
    if a.0.node != b.0.node {
        let order = try modernPasteLogicalNodes(captured.1)
        guard let start = order.firstIndex(of: a.0.node), let end = order.firstIndex(of: b.0.node), start < end else { throw EditorError.invalidRange }
        for node in order[(start + 1)..<end] where !removed.contains(node) {
            let descendants = Set(try captured.1.descendants(of: node))
            if !descendants.contains(b.0.node), captured.1.nodes[node]?.kind == .block { removed.formUnion(descendants) }
        }
    }
    let edge = prefix.last.map(WritingEdge.after) ?? keys.first.map(WritingEdge.before) ?? suffix.first.map(WritingEdge.before) ?? .start
    let caret = WritingPosition(documentID: first.documentID, epoch: first.epoch, field: source,
        anchor: edge.anchor, affinity: { if case .before = edge { return .before }; return .after }())
    return ModernPasteRangeSelection(source: source, endpoint: endpoint, keys: keys, deleted: removed.sorted { $0.key < $1.key },
        prefix: prefix, suffix: suffix, edge: edge, caret: caret, startsAtZero: a.1 == 0,
        sourceRouted: captured.0.visibleKeys(in: a.0).filter { !prefix.contains($0) },
        endpointRouted: captured.0.visibleKeys(in: b.0))
}

private struct ModernPasteBuilder {
    let change: ChangeID
    let documentID: String
    let epoch: String
    let suppliedIDs: [String]?
    let originalLabels: Set<String>
    var reserved: Set<String>
    var labels: [String] = []
    var index = 0
    var operations: [WritingOperation] = []
    var members: [NodeID] = []
    var birthKinds: [String] = []
    mutating func label() throws -> String {
        let value: String
        if let suppliedIDs {
            guard labels.count < suppliedIDs.count else { throw EditorError.invalidChange }; value = suppliedIDs[labels.count]
        } else {
            var serial = labels.count + 1
            var candidate = "paste-\(change.actor)-\(change.counter)-\(serial)"
            while reserved.contains(candidate) { serial += 1; candidate = "paste-\(change.actor)-\(change.counter)-\(serial)" }
            value = candidate
        }
        guard !value.isEmpty, value.utf16.count <= 10_000, !originalLabels.contains(value) else { throw EditorError.invalidChange }
        reserved.insert(value); labels.append(value); return value
    }
    mutating func fresh(_ value: JSONValue, kind: NodeKind) throws -> JSONValue {
        guard var fields = value.object else { throw EditorError.invalidPath }
        fields["id"] = .string(try label())
        for (name, childKind) in StructuralState.collectionFields(kind, fields, modern: true).sorted(by: { $0.key < $1.key }) {
            if let children = fields[name]?.array { fields[name] = .array(try children.map { try fresh($0, kind: childKind) }) }
        }
        return .object(fields)
    }
    mutating func insert(_ value: JSONValue, kind: NodeKind, collection: NodeCollection, after: NodePlacementID?) throws -> NodePlacementID {
        let placement = ElementID(change: change, index: index); index += 1
        let node = NodeID.inserted(creation: placement, path: [])
        operations.append(.structure(.insertNode(value: try fresh(value, kind: kind), identity: node, collection: collection, placement: placement, after: after)))
        members.append(node); birthKinds.append(kind.rawValue); return .edit(placement)
    }
    mutating func append(_ values: [JSONValue], field: WritingField, edge initial: WritingEdge) throws -> [WritingAtomKey] {
        let plain: Bool
        if case .document = field.node { plain = true } else { plain = ["code", "expression"].contains(field.name) }
        if plain {
            guard values.allSatisfy({ $0["type"] == .string("text") && ($0["marks"]?.array ?? []).isEmpty && Set($0.object?.keys ?? Dictionary<String, JSONValue>().keys).isSubset(of: ["type", "text", "marks"]) }) else { throw EditorError.invalidChange }
            if field.name == "title" { guard !BlockEditorCore.plainText(values).unicodeScalars.contains(where: { [10, 13, 0x2028, 0x2029].contains($0.value) }) else { throw EditorError.invalidChange } }
        }
        var keys: [WritingAtomKey] = [], edge = initial
        for value in values {
            let atoms: [JSONValue]
            if value["type"] == .string("text") {
                atoms = (value["text"]?.string ?? "").unicodeScalars.map { scalar in
                    var fields = value.object!; fields["text"] = .string(String(scalar)); return .object(fields)
                }
            } else { guard !plainText([value]).isEmpty else { throw EditorError.invalidChange }; atoms = [value] }
            for atom in atoms {
                let key = WritingAtomKey(origin: field, element: ElementID(change: change, index: index)); index += 1
                operations.append(.text(.insert(WritingAtomSeed(key: key, node: atom, edge: edge, route: edge.anchor.map(WritingRoute.follow) ?? .field(field)))))
                keys.append(key); edge = .after(key)
            }
        }
        return keys
    }
}

func planModernPaste(target: ModernPasteTarget, clipboard: ModernClipboard, mode: ModernPasteMode, newIDs: [String]?, change: ChangeID,
                     documentID: String, epoch: String, captured: ([ChangeID]) throws -> (WritingProjection, StructuralState),
                     authored: (WritingProjection, StructuralState)) throws -> ModernPastePlan {
    guard (target.range != nil) != (target.boundary != nil), target.range == nil || target.selection == nil,
          (newIDs?.count ?? 0) <= 100_000, (target.selection?.ranges.count ?? 0) <= 10_000 else { throw EditorError.invalidChange }
    func scope(_ document: String, _ value: String) throws {
        guard document == documentID else { throw EditorError.differentDocument }; guard value == epoch else { throw ModernSessionError.incompatibleEpoch }
    }
    func checkedRange(_ range: ModernTextRange) throws -> ModernPasteRangeSelection {
        try scope(range.start.documentID, range.start.epoch); try scope(range.end.documentID, range.end.epoch)
        return try modernPasteSelected(range, captured: captured(range.observed), authored: authored)
    }
    let span = try target.range.map(checkedRange)
    var kind: NodeKind?, removed = Set<NodeID>(), selected = Set<WritingAtomKey>()
    if let boundary = target.boundary {
        try scope(boundary.documentID, boundary.epoch)
        kind = try validateModernPasteBoundary(boundary, captured: captured(boundary.observed).1, authored: authored.1)
        if let selection = target.selection {
            guard selection.nodes != nil || !selection.ranges.isEmpty else { throw EditorError.invalidPath }
            if let nodes = selection.nodes {
                try scope(nodes.documentID, nodes.epoch)
                let old = try captured(nodes.observed).1; try modernPasteNodes(nodes, in: old)
                for node in nodes.nodes { _ = try authored.1.address(of: node); removed.formUnion(try old.descendants(of: node)) }
            }
            for range in selection.ranges {
                guard range.start.field.name != "title", range.end.field.name != "title" else { throw EditorError.invalidPath }
                let value = try checkedRange(range); selected.formUnion(value.keys); removed.formUnion(value.deleted)
                guard selected.count <= 100_000, removed.count <= 100_000 else { throw EditorError.recoveryCapacityExceeded }
            }
        }
        if let owner = boundary.collection.owner { guard !removed.contains(owner) else { throw EditorError.invalidPath } }
    }
    return try buildModernPaste(target: target, clipboard: clipboard, mode: mode, newIDs: newIDs, change: change,
        documentID: documentID, epoch: epoch, span: span, boundaryKind: kind, removed: removed, selected: selected, authored: authored)
}

// Keep causal projection work outside the command builder's larger stack frame.
// Only bounded captured identities/atoms survive that phase, not replay snapshots.
private func buildModernPaste(target: ModernPasteTarget, clipboard: ModernClipboard, mode: ModernPasteMode, newIDs: [String]?, change: ChangeID,
                     documentID: String, epoch: String, span capturedSpan: ModernPasteRangeSelection?, boundaryKind: NodeKind?,
                     removed: Set<NodeID>, selected: Set<WritingAtomKey>, authored: (WritingProjection, StructuralState)) throws -> ModernPastePlan {
    try clipboard.validate()
    var isPlain = false
    if let range = target.range {
        let field = try range.start.anchor.map { try authored.0.field(of: $0) } ?? authored.0.destination(of: range.start.field)
        isPlain = ["title", "code", "expression"].contains(field.name)
    }
    var parts = try modernPasteParts(clipboard, mode: mode, plainField: isPlain, range: target.range != nil)
    if mode == .plainText, target.range?.start.field.name == "title" {
        let normalized = clipboard.plainText.unicodeScalars.map { [10, 13, 0x2028, 0x2029].contains($0.value) ? " " : String($0) }.joined()
        parts = [.inline([textNode(normalized)])]
    }
    // Packet validation admits permitted inert metadata independently of the
    // receiving host's local authoring policy. No active resolution occurs.
    if !parts.isEmpty { try ModernClipboard(parts: parts).validateForPaste(policy: WritingPastePolicy(allowAssetMetadata: true)) }
    var builder = ModernPasteBuilder(change: change, documentID: documentID, epoch: epoch, suppliedIDs: newIDs,
        originalLabels: Set(authored.1.nodes.values.map(\.label)), reserved: Set(authored.1.nodes.values.map(\.label)))
    var caret: WritingPosition?, plainCaret = false
    let hasContent = parts.contains { part in
        if case .inline(let values) = part { return !plainText(values).isEmpty }; return true
    }
    if !hasContent {
        guard newIDs == nil || newIDs == [] else { throw EditorError.invalidChange }
        caret = capturedSpan?.caret
        return ModernPastePlan(command: ModernPaste(target: target, clipboard: clipboard, mode: mode, newIDs: [], birthKinds: [], operations: []), nodes: [], caret: caret, plainCaret: false)
    }
    func values(_ parts: [WritingClipboardPart], kind: NodeKind) throws -> [JSONValue] {
        try parts.map { part in
            switch part {
            case .node(let value, let name):
                if name == kind.rawValue { return value }
                if mode == .plainText, name == "block", value["type"] == .string("paragraph"), kind == .item || kind == .cell {
                    return .object(["id": .string("clipboard"), "content": value["content"] ?? .array([])])
                }
                throw EditorError.invalidPath
            case .inline(let content):
                if kind == .block { return .object(["id": .string("clipboard"), "type": .string("paragraph"), "content": .array(content)]) }
                if kind == .item || kind == .cell { return .object(["id": .string("clipboard"), "content": .array(content)]) }
                throw EditorError.invalidPath
            }
        }
    }
    func checkLayouts(_ values: [JSONValue], kind: NodeKind, collection: NodeCollection) throws {
        func containsLayout(_ value: JSONValue, _ kind: NodeKind) -> Bool {
            if kind == .block && value["type"] == .string("columns") { return true }
            return StructuralState.collectionFields(kind, value.object ?? [:], modern: true).contains { name, childKind in
                (value[name]?.array ?? []).contains { containsLayout($0, childKind) }
            }
        }
        if values.contains(where: { containsLayout($0, kind) }) {
            // Layouts are root structures; explicit fallback imports children.
            guard collection == .root else { throw EditorError.invalidPath }
        }
    }
    if let boundary = target.boundary {
        guard let kind = boundaryKind else { throw EditorError.invalidPath }
        if !removed.isEmpty { builder.operations.append(.structure(.deleteNodes(identities: removed.sorted { $0.key < $1.key }))) }
        if !selected.isEmpty { builder.operations.append(.text(.delete(keys: selected.sorted()))) }
        let imported = try values(parts, kind: kind); try checkLayouts(imported, kind: kind, collection: boundary.collection)
        var after = boundary.after
        for value in imported { after = try builder.insert(value, kind: kind, collection: boundary.collection, after: after) }
        plainCaret = mode == .plainText
    } else if let span = capturedSpan {
        if !span.keys.isEmpty { builder.operations.append(.text(.delete(keys: span.keys))) }
        if !span.deleted.isEmpty { builder.operations.append(.structure(.deleteNodes(identities: span.deleted))) }
        let single = parts.count == 1 && { if case .inline = parts[0] { return true }; return false }()
        if single {
            guard case .inline(let inline) = parts[0] else { throw EditorError.invalidChange }
            let inserted = try builder.append(inline, field: span.source, edge: span.edge)
            let end = inserted.last.map(WritingEdge.after) ?? span.edge
            if span.source != span.endpoint {
                let a = authored.1.nodes[span.source.node], b = authored.1.nodes[span.endpoint.node]
                let placements = try authored.1.effectivePlacements()
                if a?.kind == .block, b?.kind == .block, a?.fields["type"] == .string("paragraph"), b?.fields["type"] == .string("paragraph"),
                   b?.collections.isEmpty == true, Set(b!.fields.keys).isSubset(of: ["id", "type", "content"]),
                   placements[span.source.node]?.collection == placements[span.endpoint.node]?.collection {
                    builder.operations.append(.text(.join(source: span.endpoint, destination: span.source, edge: end)))
                }
            }
            caret = WritingPosition(documentID: documentID, epoch: epoch, field: span.source, anchor: inserted.last ?? span.edge.anchor,
                affinity: inserted.isEmpty ? span.caret.affinity : .after)
        } else {
            guard !isPlain, let original = authored.1.nodes[span.source.node], let ending = authored.1.nodes[span.endpoint.node] else { throw EditorError.invalidPath }
            let placements = try authored.1.effectivePlacements()
            guard let parent = placements[span.source.node] else { throw EditorError.invalidPath }
            var leading: [JSONValue] = [], trailing: [JSONValue] = [], hasLeading = false
            if case .inline(let content)? = parts.first { leading = content; hasLeading = true; parts.removeFirst() }
            if case .inline(let content)? = parts.last { trailing = content; parts.removeLast() }
            var collection = parent.collection, after: NodePlacementID? = parent.id
            let sourceDescendants = Set(try authored.1.descendants(of: span.source.node))
            if span.source != span.endpoint, sourceDescendants.contains(span.endpoint.node) {
                let kind = parts.compactMap { part -> NodeKind? in if case .node(_, let name) = part { return NodeKind(rawValue: name) }; return nil }.first ?? original.kind
                if let field = StructuralState.collectionFields(original.kind, original.fields, modern: true).filter({ $0.value == kind }).keys.sorted().first {
                    collection = NodeCollection(owner: span.source.node, field: field); after = nil
                } else if !parts.isEmpty { throw EditorError.invalidPath }
            }
            let kind = try authored.1.kind(in: collection), imported = try values(parts, kind: kind)
            try checkLayouts(imported, kind: kind, collection: collection)
            let siblings = try authored.1.visibleOrder(in: collection)
            let before = siblings.firstIndex(of: span.source.node).flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
            let head = try builder.append(leading, field: span.source, edge: span.edge)
            if span.source == span.endpoint {
                guard original.kind == .item || original.kind == .cell || (original.kind == .block && ["paragraph", "heading", "quote", "callout"].contains(original.fields["type"]?.string ?? "")), span.source.name == "content" else { throw EditorError.invalidPath }
                let retainPrefix = !span.startsAtZero || hasLeading
                after = retainPrefix ? parent.id : parent.after
                for value in imported { after = try builder.insert(value, kind: kind, collection: collection, after: after) }
                var destination = span.source
                if retainPrefix {
                    let tail: JSONValue
                    if original.kind == .block {
                        if original.fields["type"] == .string("paragraph") { var fields = original.fields; fields["content"] = .array([]); tail = .object(fields) }
                        else { tail = .object(["id": .string("tail"), "type": .string("paragraph"), "content": .array([])]) }
                    } else {
                        var fields = original.fields; fields["content"] = .array([])
                        if original.collections.contains("children") { fields["children"] = .array([]) }; tail = .object(fields)
                    }
                    _ = try builder.insert(tail, kind: original.kind, collection: parent.collection, after: after)
                    destination = WritingField(node: builder.members.last!, name: "content")
                    builder.operations.append(.text(.spliceBoundary(source: span.source, destination: destination, edge: span.edge, before: before, members: builder.members)))
                    let prefix = span.prefix + head
                    if !prefix.isEmpty { builder.operations.append(.text(.transfer(keys: prefix, destination: span.source, edge: .start))) }
                }
                let tail = try builder.append(trailing, field: destination, edge: retainPrefix ? .start : span.edge)
                if retainPrefix, !span.suffix.isEmpty { builder.operations.append(.text(.transfer(keys: span.suffix, destination: destination, edge: tail.last.map(WritingEdge.after) ?? .start))) }
                caret = WritingPosition(documentID: documentID, epoch: epoch, field: destination, anchor: tail.last ?? span.suffix.first,
                    affinity: tail.isEmpty && !span.suffix.isEmpty ? .before : .after)
            } else if original.kind == .block, ending.kind == .block,
                      original.fields["type"] == .string("paragraph"), ending.fields["type"] == .string("paragraph"),
                      span.source.name == "content", span.endpoint.name == "content",
                      let endParent = placements[span.endpoint.node], endParent.collection == parent.collection {
                // A retained endpoint keeps its metadata and descendants. The
                // compound cut routes unseen source text without copying it.
                for value in imported { after = try builder.insert(value, kind: kind, collection: collection, after: after) }
                let placement = ElementID(change: change, index: builder.index); builder.index += 1
                builder.operations.append(.structure(.moveNode(identity: span.endpoint.node, collection: parent.collection, placement: placement, after: after)))
                builder.members.append(span.endpoint.node)
                if span.startsAtZero, !hasLeading, original.collections.isEmpty,
                   Set(original.fields.keys).isSubset(of: ["id", "type", "content"]) {
                    builder.operations.append(.structure(.deleteNodes(identities: [span.source.node])))
                }
                let tail = try builder.append(trailing, field: span.endpoint, edge: .start)
                let endIndex = siblings.firstIndex(of: span.endpoint.node)!
                let next = endIndex + 1 < siblings.count ? siblings[endIndex + 1] : nil
                builder.operations.append(.text(.rangeSpliceBoundary(WritingRangeSplice(source: span.source, destination: span.endpoint,
                    edge: span.edge, before: next, members: builder.members, sourcePlacement: parent.id,
                    endpointPlacement: endParent.id, destinationPlacement: placement, endpointKeys: span.endpointRouted))))
                let prefix = span.prefix + head
                if !prefix.isEmpty { builder.operations.append(.text(.transfer(keys: prefix, destination: span.source, edge: .start))) }
                if !span.sourceRouted.isEmpty { builder.operations.append(.text(.transfer(keys: span.sourceRouted, destination: span.endpoint, edge: tail.last.map(WritingEdge.after) ?? .start))) }
                if !span.endpointRouted.isEmpty {
                    builder.operations.append(.text(.transfer(keys: span.endpointRouted, destination: span.endpoint,
                        edge: span.sourceRouted.last.map(WritingEdge.after) ?? tail.last.map(WritingEdge.after) ?? .start)))
                }
                caret = WritingPosition(documentID: documentID, epoch: epoch, field: span.endpoint, anchor: tail.last ?? span.suffix.first,
                    affinity: tail.isEmpty && !span.suffix.isEmpty ? .before : .after)
            } else {
                // Preserve both hierarchy/metadata-bearing endpoint owners. A
                // retained import boundary orders new siblings without moving them.
                for value in imported { after = try builder.insert(value, kind: kind, collection: collection, after: after) }
                let tail = try builder.append(trailing, field: span.endpoint, edge: .start)
                if !tail.isEmpty, let first = authored.0.visibleKeys(in: span.endpoint).first {
                    builder.operations.append(.text(.transfer(keys: tail, destination: span.endpoint, edge: .before(first))))
                }
                if !builder.members.isEmpty {
                    builder.operations.append(.text(.importBoundary(WritingImportBoundary(source: span.source, edge: head.last.map(WritingEdge.after) ?? span.edge,
                        sourcePlacement: parent.id, collection: collection, after: collection == parent.collection ? parent.id : nil,
                        before: before, members: builder.members, sourceKeys: span.sourceRouted))))
                }
                if span.startsAtZero, !hasLeading, !sourceDescendants.contains(span.endpoint.node), original.kind == .block,
                   original.collections.isEmpty, Set(original.fields.keys).isSubset(of: ["id", "type", "content"]) {
                    builder.operations.append(.structure(.deleteNodes(identities: [span.source.node])))
                }
                caret = WritingPosition(documentID: documentID, epoch: epoch, field: span.endpoint, anchor: tail.last ?? span.suffix.first,
                    affinity: tail.isEmpty && !span.suffix.isEmpty ? .before : .after)
                _ = ending
            }
        }
    }
    if let newIDs { guard newIDs.count == builder.labels.count else { throw EditorError.invalidChange } }
    if plainCaret, let node = builder.members.last {
        let field = WritingField(node: node, name: "content")
        // The last imported field is born with the new node, so its caret can
        // use its field-end boundary without inventing an atom identity.
        caret = WritingPosition(documentID: documentID, epoch: epoch, field: field, affinity: .before)
    }
    return ModernPastePlan(command: ModernPaste(target: target, clipboard: clipboard, mode: mode, newIDs: builder.labels, birthKinds: builder.birthKinds, operations: builder.operations),
        nodes: builder.members, caret: caret, plainCaret: plainCaret)
}

func applyModernPaste(_ paste: ModernPaste, enabled: Bool, raw: inout Materialized, births: inout [WritingField: WritingFieldBirth],
                      collectionBirths: inout [NodeCollection: NodeKind]) throws {
    for operation in paste.operations {
        guard case .structure(let mutation) = operation else { continue }
        let original = raw.structure!.nodes
        let validating = writingRetainedCollectionShape(raw, mutations: [mutation], collectionBirths: collectionBirths)
        let adjusted = validating.structure!.nodes.filter { original[$0.key]?.fields != $0.value.fields || original[$0.key]?.kind != $0.value.kind }
        raw.structure = validating.structure
        try apply([mutation], enabled: enabled, to: &raw)
        for owner in adjusted.keys { raw.structure!.nodes[owner] = original[owner] }
        retainModernFieldBirths(in: raw.structure!, births: &births)
        collectionBirths.merge(modernCollectionBirths(raw.structure!)) { old, _ in old }
    }
}
