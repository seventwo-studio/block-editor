import Foundation

/// Presentation transport only, after the complete shared snapshot is admitted.
/// Replacement paths preserve opaque values, scalar spelling and signed zero.
enum ModernSnapshotDelta {
    static func changes(from old: ModernDocument, to new: ModernDocument, limit: Int = 128) -> [JSONValue]? {
        guard let roots = old.comparisonRoots(with: new), old.blocks.count == new.blocks.count else {
            return changes(from: .object(old.fields), to: .object(new.fields), limit: limit)
        }
        var output: [JSONValue] = []
        func append(_ before: JSONValue, _ after: JSONValue, _ path: [JSONValue]) -> Bool {
            guard let values = changes(from: before, to: after, limit: limit - output.count, path: path) else { return false }
            output.append(contentsOf: values); return true
        }
        guard append(old.fields["appearance"]!, new.fields["appearance"]!, [.string("appearance")]) else { return nil }
        for index in roots.sorted() {
            guard old.blocks.indices.contains(index), append(.object(old.blocks[index].fields), .object(new.blocks[index].fields),
                [.string("blocks"), .number(Double(index))]) else { return nil }
        }
        guard append(old.fields["title"]!, new.fields["title"]!, [.string("title")]) else { return nil }
        return output
    }
    static func changes(from old: JSONValue, to new: JSONValue, limit: Int = 128, path: [JSONValue] = []) -> [JSONValue]? {
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
                let left = a.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                let right = b.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                guard zip(left, right).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { replace(new, at: path); return }
                for name in left {
                    visit(a[name]!, b[name]!, path + [.string(name)])
                    if changes.count > limit { return }
                }
            default: replace(new, at: path)
            }
        }
        visit(old, new, path)
        return changes.count <= limit ? changes : nil
    }
    static func equal(_ old: JSONValue, _ new: JSONValue) -> Bool {
        changes(from: old, to: new, limit: 0)?.isEmpty == true
    }
}
