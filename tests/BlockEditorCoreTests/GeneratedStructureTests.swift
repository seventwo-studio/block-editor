import BlockEditorCore
import Foundation
import Testing

private struct StructureRandom {
    var state: UInt64
    mutating func index(_ count: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(count))
    }
    mutating func shuffle<T>(_ values: [T]) -> [T] {
        var values = values
        for index in values.indices.reversed() where index > 0 { values.swapAt(index, self.index(index + 1)) }
        return values
    }
}

private enum StructureCollection: String, CaseIterable, Sendable {
    case root, toggleChildren, listItems, tableRows, tableCells

    var field: String {
        switch self {
        case .root: return "blocks"
        case .toggleChildren: return "children"
        case .listItems: return "items"
        case .tableRows: return "rows"
        case .tableCells: return "cells"
        }
    }
    var textField: String { self == .root ? "summary" : "content" }

    func payload(_ id: String) -> JSONValue {
        let host: JSONValue = .object(["preserve": .bool(true), "origin": .string(id),
            "opaque": .array([.number(7), .object(["id": .string("not-a-document-id"), "text": .string("é")])])])
        let content: JSONValue = .array([
            textNode("café 👩🏽‍💻 é 日本語 ", marks: [.object(["type": .string("italic")])]),
            .object(["type": .string("entity-ref"), "entityId": .string("entity-\(id)"),
                "entityType": .string("note"), "label": .string("Ref"), "host": host])])
        let leaf: JSONValue = .object(["id": .string("leaf-\(id)"), "content": content, "host": host])
        switch self {
        case .root:
            var child = leaf.object!; child["type"] = .string("paragraph")
            return .object(["id": .string(id), "type": .string("toggle"), "summary": content,
                "children": .array([.object(child)]), "host": host])
        case .toggleChildren:
            return .object(["id": .string(id), "type": .string("paragraph"), "content": content, "host": host])
        case .listItems:
            return .object(["id": .string(id), "content": content, "checked": .bool(true),
                "children": .array([leaf]), "host": host])
        case .tableRows:
            var cell = leaf.object!; cell["header"] = .bool(true)
            return .object(["id": .string(id), "cells": .array([.object(cell)]), "host": host])
        case .tableCells:
            return .object(["id": .string(id), "content": content, "header": .bool(true), "host": host])
        }
    }

    func baseline() throws -> Document {
        if self == .root {
            return try Document(blocks: (0..<6).map { try Block(fields: payload("member-\($0)").object!) })
        }
        return try Document(blocks: (0..<3).map { index in
            let members = (0..<2).map { payload("member-\(index)-\($0)") }
            var fields: [String: JSONValue] = ["id": .string("container-\(index)"), "host": .object(["keep": .bool(true)])]
            switch self {
            case .root: break
            case .toggleChildren:
                fields["type"] = .string("toggle"); fields["summary"] = .array([textNode("container")]); fields[field] = .array(members)
            case .listItems:
                fields["type"] = .string("list"); fields["style"] = .string("todo"); fields[field] = .array(members)
            case .tableRows:
                fields["type"] = .string("table"); fields[field] = .array(members)
            case .tableCells:
                fields["type"] = .string("table")
                fields["rows"] = .array([.object(["id": .string("row"), "cells": .array(members), "host": .object(["keep": .bool(true)])])])
            }
            return try Block(fields: fields)
        })
    }

    func collections(_ session: EditorSession) throws -> [NodeCollection] {
        if self == .root { return [.root] }
        return try (0..<3).map { index in
            let path = self == .tableCells ? ["rows", "row"] : []
            return NodeCollection(owner: try session.node(at: NodeAddress("container-\(index)", path: path)), field: field)
        }
    }

    func textNodeID(_ session: EditorSession, _ identity: NodeID) throws -> NodeID {
        if self != .tableRows { return identity }
        return try #require(session.nodes(in: NodeCollection(owner: identity, field: "cells")).first)
    }
}

private func nodeValue(_ session: EditorSession, _ identity: NodeID) throws -> JSONValue {
    let address = try session.address(of: identity)
    let block = try #require(session.document.blocks.first { $0.id == address.blockID })
    return try #require(block.value(at: address.path))
}

private func expectPrefixMarks(_ nodes: [JSONValue], required: Set<String>, forbidden: Set<String> = []) {
    var remaining = 4 // The independently known "café" prefix.
    for node in nodes where remaining > 0 {
        #expect(node["type"] == .string("text"))
        let marks = Set(node["marks"]?.array?.compactMap { $0["type"]?.string } ?? [])
        #expect(required.isSubset(of: marks))
        #expect(marks.isDisjoint(with: forbidden))
        remaining -= min(remaining, node["text"]?.string?.utf16.count ?? 0)
    }
    #expect(remaining == 0)
}

@Test(arguments: [1, 7, 42, 255, 65_537, 20_260_930, 999_983, 4_294_967_295] as [UInt64], StructureCollection.allCases)
private func generatedStructuralCollectionsOfflineEditsAndHistoryConverge(seed: UInt64, kind: StructureCollection) throws {
    var random = StructureRandom(state: seed)
    let baseline = try kind.baseline()
    var replicas = try (0..<3).map { try EditorSession(documentID: "generated-\(kind.rawValue)-\(seed)", actorID: "actor-\($0)", document: baseline, collaborationVersion: 2) }
    let collections = try kind.collections(replicas[0])
    var trace: [String] = []
    func settle(_ replicas: [EditorSession], random: inout StructureRandom) throws {
        let all = replicas.flatMap { $0.changes().changes }, expectedReceipts = Set(all.map(\.id))
        for session in replicas {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: random.shuffle(all), version: 2))
            #expect(session.mergeRecovery == nil)
        }
        for session in replicas {
            #expect(try session.document == replicas[0].document, "seed \(seed), \(kind)")
            #expect(session.syncState.received == expectedReceipts)
            let restored = try EditorSession.restore(session.save(), actorID: session.actorID)
            #expect(try restored.document == session.document)
            #expect(restored.syncState == session.syncState)
        }
    }

    // All authors concurrently place the same identity at different parents or root anchors.
    let contested = try #require(replicas[0].nodes(in: collections[0]).first)
    for index in replicas.indices {
        let target = collections[index % collections.count]
        let siblings = try replicas[index].nodes(in: target).filter { $0 != contested }
        let before = try nodeValue(replicas[index], contested)
        try replicas[index].moveNode(contested, into: target, after: siblings.isEmpty ? nil : siblings[index % siblings.count])
        #expect(try nodeValue(replicas[index], contested) == before)
    }
    try settle(replicas, random: &random)
    let partitionReceipts = replicas[0].syncState.received
    for round in 0..<18 {
        for index in replicas.indices {
            let session = replicas[index], collection = collections[random.index(collections.count)]
            let members = try session.nodes(in: collection)
            let node = members.isEmpty ? nil : members[random.index(members.count)]
            let operation = (round + index) % 7
            trace.append("round \(round), actor \(index), operation \(operation), node \(String(describing: node))")
            do {
                switch operation {
                case 0:
                    let payload = kind.payload("insert-\(index)-\(round)")
                    let inserted = try session.insertNode(payload, into: collection, after: members.last)
                    #expect(try nodeValue(session, inserted) == payload)
                case 1:
                    if let node {
                        let target = collections[random.index(collections.count)]
                        let siblings = try session.nodes(in: target).filter { $0 != node }
                        let before = try nodeValue(session, node)
                        try session.moveNode(node, into: target, after: siblings.last)
                        #expect(try nodeValue(session, node) == before)
                    }
                case 2:
                    if let node {
                        let textID = try kind.textNodeID(session, node), address = try session.textAddress(of: textID, field: kind.textField)
                        let before = try session.text(at: address), prefix = "\(index)אב😀"
                        try session.replaceText(at: address, range: 0..<0, with: prefix)
                        #expect(try session.text(at: address) == prefix + before)
                    }
                case 3:
                    if let node {
                        let textID = try kind.textNodeID(session, node), address = try session.textAddress(of: textID, field: kind.textField)
                        let before = try session.text(at: address)
                        try session.format(at: address, range: 0..<before.utf16.count, markType: "bold", mark: .object(["type": .string("bold")]))
                        #expect(try session.text(at: address) == before)
                    }
                case 4: if let node { try session.deleteNode(node) }
                case 5: try session.undo()
                default: try session.redo()
                }
                let restored = try EditorSession.restore(session.save(), actorID: session.actorID)
                #expect(try restored.document == session.document)
                #expect(restored.syncState == session.syncState)
                #expect(restored.canUndo == session.canUndo)
                #expect(restored.canRedo == session.canRedo)
                if round % 4 == 0 { replicas[index] = restored }
                // Actor zero remains partitioned, including restarts, until round nine.
                let target = round < 9 ? 1 + random.index(2) : random.index(3)
                if target != index && (round >= 9 || index != 0) {
                    let batch = replicas[index].changes(since: replicas[target].syncState)
                    let partial = Array(random.shuffle(batch.changes).prefix(max(1, batch.changes.count / 2)))
                    try replicas[target].receive(ChangeBatch(documentID: batch.documentID, baseline: baseline, changes: partial + partial, version: 2))
                }
                if round == 8 && index == 2 {
                    #expect(replicas[0].syncState.received.subtracting(partitionReceipts).allSatisfy { $0.actor == "actor-0" })
                }
            } catch {
                Issue.record("seed \(seed), collection \(kind.rawValue): \(error); trace \(trace.suffix(12))")
                throw error
            }
        }
    }
    try settle(replicas, random: &random)

    // An independent oracle checks author undo, Unicode, marks, references and opaque content.
    let before = try replicas[0].document, payload = kind.payload("sentinel")
    let sentinel = try replicas[0].insertNode(payload, into: collections[0])
    try settle(replicas, random: &random)
    let textID = try kind.textNodeID(replicas[0], sentinel)
    let address = try replicas[0].textAddress(of: textID, field: kind.textField)
    let originalText = try replicas[0].text(at: address), originalValue = try nodeValue(replicas[0], sentinel)
    try replicas[0].format(at: address, range: 0..<4, markType: "bold", mark: .object(["type": .string("bold")]))
    try replicas[1].format(at: address, range: 0..<4, markType: "code", mark: .object(["type": .string("code")]))
    try settle(replicas, random: &random)
    let withFormats = try replicas[0].document
    expectPrefixMarks(try nodeValue(replicas[0], textID)[kind.textField]?.array ?? [], required: ["italic", "bold", "code"])
    for index in replicas.indices {
        let end = try replicas[index].text(at: address).utf16.count
        try replicas[index].replaceText(at: address, range: end..<end, with: "<author-\(index)>", marks: [])
    }
    try settle(replicas, random: &random)
    let withSentinels = try replicas[0].document
    var activeAuthors = Set(replicas.indices)
    for index in random.shuffle(Array(replicas.indices)) {
        try replicas[index].undo(); try settle(replicas, random: &random); activeAuthors.remove(index)
        let text = try replicas[0].text(at: address)
        #expect(text.hasPrefix(originalText))
        for other in replicas.indices { #expect(text.contains("<author-\(other)>") == activeAuthors.contains(other)) }
        #expect(text.utf16.count == originalText.utf16.count + activeAuthors.count * "<author-0>".utf16.count)
    }
    #expect(try replicas[0].document == withFormats)
    for index in random.shuffle(Array(replicas.indices)) { try replicas[index].redo() }
    try settle(replicas, random: &random)
    #expect(try replicas[0].document == withSentinels)
    for replica in replicas { try replica.undo() }
    try settle(replicas, random: &random)
    try replicas[0].undo(); try settle(replicas, random: &random)
    let remotelyFormatted = try nodeValue(replicas[0], textID)[kind.textField]?.array ?? []
    expectPrefixMarks(remotelyFormatted, required: ["italic", "code"], forbidden: ["bold"])
    #expect(remotelyFormatted.contains { $0["marks"]?.array?.contains(.object(["type": .string("code")])) == true })
    #expect(!remotelyFormatted.contains { $0["marks"]?.array?.contains(.object(["type": .string("bold")])) == true })
    try replicas[1].undo(); try settle(replicas, random: &random)
    #expect(try nodeValue(replicas[0], sentinel) == originalValue)
    #expect(originalValue == payload)
    try replicas[0].undo(); try settle(replicas, random: &random)
    #expect(try replicas[0].document == before)
}
