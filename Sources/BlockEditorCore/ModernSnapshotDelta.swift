import Foundation

/// Presentation transport only, after the complete shared snapshot is admitted.
/// Replacement paths preserve opaque values, scalar spelling and signed zero.
enum ModernSnapshotDelta {
    static func changes(from old: JSONValue, to new: JSONValue, limit: Int = 128) -> [JSONValue]? {
        var changes: [JSONValue] = []
        func replace(_ value: JSONValue, at path: [JSONValue]) {
            changes.append(.object(["path": .array(path), "value": value]))
        }
        func visit(_ old: JSONValue, _ new: JSONValue, _ path: [JSONValue]) {
            guard changes.count <= limit else { return }
            switch (old, new) {
            case (.null, .null): return
            case (.bool(let a), .bool(let b)) where a == b: return
            case (.number(let a), .number(let b)) where a.bitPattern == b.bitPattern: return
            case (.string(let a), .string(let b)) where a.utf8.elementsEqual(b.utf8): return
            case (.array(let a), .array(let b)) where a.count == b.count && path.count < 100:
                for index in a.indices {
                    visit(a[index], b[index], path + [.number(Double(index))])
                    if changes.count > limit { return }
                }
            case (.object(let a), .object(let b)) where a.count == b.count && path.count < 100:
                // Dictionary lookup uses canonical Unicode equality. Check the
                // stored spelling too before emitting any child replacements.
                // Unchanged objects need no sorted key arrays; only the final
                // changed paths require stable transport ordering.
                for name in a.keys {
                    guard let index = b.index(forKey: name), name.utf8.elementsEqual(b[index].key.utf8) else {
                        replace(new, at: path); return
                    }
                }
                for (name, value) in a {
                    visit(value, b[name]!, path + [.string(name)])
                    if changes.count > limit { return }
                }
            default: replace(new, at: path)
            }
        }
        visit(old, new, [])
        guard changes.count <= limit else { return nil }
        if changes.count > 1 {
            changes.sort { left, right in
                let a = left["path"]!.array!, b = right["path"]!.array!
                for (x, y) in zip(a, b) {
                    switch (x, y) {
                    case (.string(let x), .string(let y)):
                        if !x.utf8.elementsEqual(y.utf8) { return x.utf8.lexicographicallyPrecedes(y.utf8) }
                    case (.number(let x), .number(let y)):
                        if x != y { return x < y }
                    default: return x.string != nil
                    }
                }
                return a.count < b.count
            }
        }
        return changes
    }
    static func equal(_ old: JSONValue, _ new: JSONValue) -> Bool {
        changes(from: old, to: new, limit: 0)?.isEmpty == true
    }
}
