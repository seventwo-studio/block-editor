import BlockEditorCore
import Foundation

/// Original blocks available for an explicit host repair; this is not a merged preview.
public struct RecoveryBlock: Identifiable, Sendable {
    public let id: NodeID
    public let label: String

    public static func candidates(in recovery: MergeRecovery) -> [RecoveryBlock] {
        var blocks: [NodeID: JSONValue] = [:]
        func register(_ value: JSONValue, identity: NodeID) {
            var pending: [(JSONValue, NodeID)] = [(value, identity)]
            while let (value, identity) = pending.popLast() {
                blocks[identity] = value
                guard value["type"]?.string == "toggle" else { continue }
                for child in value["children"]?.array ?? [] {
                    guard let label = child["id"]?.string else { continue }
                    let childID: NodeID
                    switch identity {
                    case .baseline(let blockID, let path): childID = .baseline(blockID: blockID, path: path + ["children", label])
                    case .inserted(let creation, let path): childID = .inserted(creation: creation, path: path + ["children", label])
                    }
                    pending.append((child, childID))
                }
            }
        }
        for block in recovery.batch.baseline.blocks {
            register(.object(block.fields), identity: .baseline(blockID: block.id, path: []))
        }
        for change in recovery.batch.changes.sorted(by: { $0.id < $1.id }) {
            guard case .edit(let mutations) = change.body else { continue }
            for mutation in mutations {
                guard case .insertNode(let value, let identity, let collection, _, _) = mutation else { continue }
                if collection == .root || (collection.field == "children" && collection.owner.flatMap { blocks[$0] }?["type"]?.string == "toggle") {
                    register(value, identity: identity)
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return blocks.map { identity, value in
            let field = value["type"]?.string == "toggle" ? "summary" : "content"
            let original = plainText(value[field]?.array ?? [])
            let title = original.isEmpty ? (value["id"]?.string ?? "Untitled") : String(original.prefix(60))
            let choice = RecoveryBlock(id: identity, label: "Original \(value["type"]?.string ?? "block"): \(title)")
            return (choice, (try? encoder.encode(identity)) ?? Data())
        }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }
}
