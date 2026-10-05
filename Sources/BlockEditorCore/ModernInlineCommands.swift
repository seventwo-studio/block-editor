import Foundation

public enum ModernSemanticState: Codable, Equatable, Sendable { case inherited, role(String), mixed }
public enum ModernSemanticKind: String, Codable, Sendable {
    case ink, fill
    var markType: String { self == .ink ? "semantic-color" : "semantic-background" }
    var field: String { self == .ink ? "semanticColor" : "semanticBackground" }
}
/// A captured text range or whole-block selection, with optional block-subtree
/// caret. Empty text ranges return local intent without creating typing marks.
public struct ModernSemanticTarget: Codable, Equatable, Sendable {
    public let range: ModernTextRange?
    public let nodes: ModernNodeSelection?
    public let caret: WritingPosition?
    public init(range: ModernTextRange? = nil, nodes: ModernNodeSelection? = nil, caret: WritingPosition? = nil) {
        self.range = range; self.nodes = nodes; self.caret = caret
    }
}
func validateModernSemanticRole(_ role: String?) throws {
    if let role { do { try Validation.semanticRole(.string(role)) } catch { throw EditorError.invalidChange } }
}
func validateModernSemanticNode(_ node: NodeID, in structure: StructuralState) throws {
    _ = try structure.address(of: node)
    guard let value = structure.nodes[node], value.kind == .block,
          ["paragraph", "heading", "quote", "callout", "toggle", "list", "table", "image", "code", "math", "divider", "embed", "columns"].contains(value.fields["type"]?.string ?? "") else { throw EditorError.invalidPath }
}
func applyModernSemanticDefault(node: NodeID, kind: ModernSemanticKind, role: String?, enabled: Bool, raw: inout Materialized) throws {
    guard raw.structure!.nodes[node] != nil else { throw EditorError.invalidChange }
    if enabled {
        raw.structure!.nodes[node]!.fields[kind.field] = role.map(JSONValue.string)
        raw.structure!.touched.insert(node)
    }
}
func validateModernLinkURL(_ href: String) throws {
    guard !href.isEmpty, href.utf16.count <= 10_000,
          href.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
          let url = URLComponents(string: href), let scheme = url.scheme?.lowercased() else { throw EditorError.invalidChange }
    if ["http", "https"].contains(scheme) { guard let host = url.host, !host.isEmpty else { throw EditorError.invalidChange } }
    else { guard scheme == "mailto", !url.path.isEmpty else { throw EditorError.invalidChange } }
    try validateModernMark(type: "link", mark: .object(["type": .string("link"), "href": .string(href)]))
}

extension ModernSession {
    public func setSemanticColor(_ target: ModernSemanticTarget, kind: ModernSemanticKind, role: String?) throws -> ModernStructuralResult {
        try authoringAllowed(command: "setSemanticColor"); try validateModernSemanticRole(role)
        guard (target.range != nil) != (target.nodes != nil), target.range == nil || target.caret == nil else { throw EditorError.invalidChange }
        if let range = target.range {
            let mark = role.map { JSONValue.object(["type": .string(kind.markType), "value": .string($0)]) }
            let operations = try modernMarkOperations(in: range, type: kind.markType, mark: mark)
            endTypingGroup()
            if operations.isEmpty { return modernRangeResult(range) }
            return try performReturning(nextID(), operations) { _, _ in self.modernRangeResult(range) }
        }
        let selection = try modernSemanticNodes(target)
        let operations = selection.nodes.compactMap { node -> ModernOperation? in
            structure.nodes[node]!.fields[kind.field] == role.map(JSONValue.string) ? nil : .setSemanticDefault(node: node, kind: kind, role: role)
        }
        endTypingGroup()
        if operations.isEmpty { return moveResult(selection.nodes, caret: target.caret, observed: modernObserved) }
        return try performReturning(nextID(), operations) { _, observed in self.moveResult(selection.nodes, caret: target.caret, observed: observed) }
    }
    public func semanticState(_ target: ModernSemanticTarget, kind: ModernSemanticKind) throws -> ModernSemanticState {
        guard (target.range != nil) != (target.nodes != nil), target.range == nil || target.caret == nil else { throw EditorError.invalidChange }
        let roles: [String?]
        if let range = target.range {
            let selected = try modernCapturedSelection(range)
            let field = try selected.position.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: selected.position.field)
            guard !plainField(field) else { throw EditorError.invalidChange }
            let inherited = try modernInheritedRole(field.node, kind: kind)
            let keys = try modernVisibleMarkKeys(selected.keys)
            if keys.isEmpty {
                let marks = try selected.position.anchor.map { key -> [JSONValue] in
                    let value = try modernCurrentReplay.0.value(of: key)
                    return value["type"] == .string("text") ? value["marks"]?.array ?? [] : []
                } ?? []
                roles = [marks.first(where: { $0["type"] == .string(kind.markType) })?["value"]?.string ?? inherited]
            } else {
                roles = try keys.map { key in
                    let value = try modernCurrentReplay.0.value(of: key)
                    let marks = value["type"] == .string("text") ? value["marks"]?.array ?? [] : []
                    let destination = try modernCurrentReplay.0.field(of: key)
                    let actualDefault = try modernInheritedRole(destination.node, kind: kind)
                    return marks.first(where: { $0["type"] == .string(kind.markType) })?["value"]?.string ?? actualDefault
                }
            }
        } else {
            roles = try modernSemanticNodes(target).nodes.map { structure.nodes[$0]!.fields[kind.field]?.string }
        }
        let values = Set(roles)
        if values.count > 1 { return .mixed }
        return roles.first.flatMap { $0 }.map(ModernSemanticState.role) ?? .inherited
    }
    private func modernInheritedRole(_ node: NodeID, kind: ModernSemanticKind) throws -> String? {
        let placements = try structure.effectivePlacements()
        var current: NodeID? = node, seen = Set<NodeID>()
        while let value = current {
            guard seen.insert(value).inserted, let entry = structure.nodes[value] else { throw EditorError.invalidPath }
            if entry.kind == .block { return entry.fields[kind.field]?.string }
            current = placements[value]?.collection.owner
        }
        return nil
    }
    private func modernSemanticNodes(_ target: ModernSemanticTarget) throws -> ModernNodeSelection {
        let selection = target.nodes!, captured = try validateSelection(selection)
        for node in selection.nodes {
            try validateModernSemanticNode(node, in: captured); try validateModernSemanticNode(node, in: structure)
        }
        if let caret = target.caret {
            let replay = try modernCapturedReplay(selection.observed)
            let original = try modernResolve(caret, in: replay, observed: selection.observed), current = try resolve(caret)
            let originalNodes = try Set(selection.nodes.flatMap { try captured.descendants(of: $0) })
            let currentNodes = try Set(selection.nodes.flatMap { try structure.descendants(of: $0) })
            guard let origin = original.address.identity, let actual = current.address.identity,
                  originalNodes.contains(origin), currentNodes.contains(actual) else { throw EditorError.invalidPath }
        }
        return selection
    }
    public func setLink(in range: ModernTextRange, href: String?, label: String? = nil) throws -> ModernStructuralResult {
        try authoringAllowed(command: "setLink")
        if let href { try validateModernLinkURL(href) }
        let mark = href.map { JSONValue.object(["type": .string("link"), "href": .string($0)]) }
        if let label {
            guard href != nil, !label.isEmpty, label.utf16.count <= 100_000 else { throw EditorError.invalidChange }
            _ = try modernCapturedCaret(range)
            let selected = try modernCapturedSelection(range)
            let field = try selected.position.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: selected.position.field)
            guard !plainField(field) else { throw EditorError.invalidChange }
            let id = try nextID()
            let linkIndex = selected.marks.firstIndex { $0["type"] == .string("link") }
            var marks = selected.marks.filter { $0["type"] != .string("link") }
            // Replace the captured link slot without reordering other marks.
            marks.insert(mark!, at: min(linkIndex ?? marks.count, marks.count))
            var operations: [ModernOperation] = [], edge = selected.edge, last: WritingAtomKey?
            for (index, scalar) in label.unicodeScalars.enumerated() {
                let key = WritingAtomKey(origin: field, element: ElementID(change: id, index: index))
                operations.append(.text(.insert(WritingAtomSeed(key: key, node: textNode(String(scalar), marks: marks), edge: edge,
                    route: edge.anchor.map(WritingRoute.follow) ?? .field(field)))))
                edge = .after(key); last = key
            }
            let caret = WritingPosition(documentID: documentID, epoch: epoch, field: field, anchor: last!, affinity: .after)
            endTypingGroup()
            return try performReturning(id, operations) { _, _ in
                ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
            }
        }
        let operations = try modernMarkOperations(in: range, type: "link", mark: mark)
        endTypingGroup()
        if operations.isEmpty { return modernRangeResult(range) }
        return try performReturning(nextID(), operations) { _, _ in self.modernRangeResult(range) }
    }
    func modernRangeResult(_ range: ModernTextRange) -> ModernStructuralResult {
        ModernStructuralResult(focus: .text(range.end), selection: .text(WritingTextRange(start: range.start, end: range.end)))
    }
    private func modernVisibleMarkKeys(_ keys: [WritingAtomKey]) throws -> [WritingAtomKey] {
        var visible: [WritingField: Set<WritingAtomKey>] = [:], result: [WritingAtomKey] = []
        for key in keys {
            let field = try modernCurrentReplay.0.field(of: key)
            if visible[field] == nil { visible[field] = Set(modernCurrentReplay.0.visibleKeys(in: field)) }
            guard visible[field]!.contains(key) else { continue }
            guard !plainField(field) else { throw EditorError.invalidChange }
            _ = try structure.address(of: field.node)
            result.append(key)
        }
        return result
    }
    func modernMarkOperations(in range: ModernTextRange, type: String, mark: JSONValue?) throws -> [ModernOperation] {
        try validateModernMark(type: type, mark: mark)
        let selected = try modernCapturedSelection(range)
        let field = try selected.position.anchor.map { try modernCurrentReplay.0.field(of: $0) } ?? modernCurrentReplay.0.destination(of: selected.position.field)
        guard !plainField(field) else { throw EditorError.invalidChange }
        let selectedVisible = try modernVisibleMarkKeys(selected.keys)
        let changed = try selectedVisible.filter { key in
            let value = try modernCurrentReplay.0.value(of: key)
            guard value["type"] == .string("text") else { return false }
            let marks = value["marks"]?.array ?? []
            return marks.first(where: { $0["type"] == .string(type) }) != mark
        }
        return changed.isEmpty ? [] : [.text(.format(keys: changed, type: type, mark: mark))]
    }
}
