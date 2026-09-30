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

@Test(arguments: [1, 7, 42, 255, 65_537, 20_260_930, 999_983, 4_294_967_295] as [UInt64])
func generatedNestedMovesOfflineEditsAndHistoryConverge(seed: UInt64) throws {
    var random = StructureRandom(state: seed)
    let baseline = try Document(blocks: (0..<3).map { index in
        try Block(fields: ["id": .string("container-\(index)"), "type": .string("toggle"), "summary": .array([textNode("container")]),
            "children": .array((0..<2).map { child in .object(["id": .string("child-\(index)-\(child)"), "type": .string("paragraph"),
                "content": .array([textNode("café 😀世界")]), "host": .object(["preserve": .bool(true)])]) })])
    })
    var replicas = try (0..<3).map { try EditorSession(documentID: "generated-v2", actorID: "actor-\($0)", document: baseline, collaborationVersion: 2) }
    let containers = try (0..<3).map { try replicas[0].node(at: NodeAddress("container-\($0)")) }
    let collections = containers.map { NodeCollection(owner: $0, field: "children") }
    func settle(_ replicas: [EditorSession], random: inout StructureRandom) throws {
        let all = replicas.flatMap { $0.changes().changes }
        for session in replicas {
            try session.receive(ChangeBatch(documentID: session.documentID, baseline: baseline, changes: random.shuffle(all), version: 2))
        }
        for session in replicas {
            #expect(try session.document == replicas[0].document, "seed \(seed)")
            #expect(session.syncState == replicas[0].syncState)
        }
    }
    for round in 0..<18 {
        for index in replicas.indices {
            let session = replicas[index], collection = collections[random.index(collections.count)]
            let members = try session.nodes(in: collection)
            let node = members.isEmpty ? nil : members[random.index(members.count)]
            switch (round + index) % 7 {
            case 0:
                let id = "insert-\(index)-\(round)"
                _ = try session.insertNode(.object(["id": .string(id), "type": .string("paragraph"),
                    "content": .array([textNode("offline 👩🏽‍💻")])]), into: collection, after: members.last)
            case 1:
                if let node {
                    let target = collections[random.index(collections.count)]
                    let siblings = try session.nodes(in: target).filter { $0 != node }
                    try session.moveNode(node, into: target, after: siblings.last)
                }
            case 2:
                if let node {
                    let address = try session.textAddress(of: node)
                    try session.replaceText(at: address, range: 0..<0, with: "\(index)אב😀")
                }
            case 3:
                if let node {
                    let address = try session.textAddress(of: node), length = try session.text(at: address).utf16.count
                    try session.format(at: address, range: 0..<length, markType: "bold", mark: .object(["type": .string("bold")]))
                }
            case 4: if let node { try session.deleteNode(node) }
            case 5: try session.undo()
            default: try session.redo()
            }
            let restored = try EditorSession.restore(session.save(), actorID: session.actorID)
            #expect(try restored.document == session.document, "seed \(seed), round \(round), actor \(index)")
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
        }
    }
    try settle(replicas, random: &random)
    let before = try replicas[0].document
    let sentinel = try replicas[0].insertNode(.object(["id": .string("sentinel"), "type": .string("paragraph"), "content": .array([textNode("base")])]), into: collections[0])
    try settle(replicas, random: &random)
    for index in replicas.indices {
        let address = try replicas[index].textAddress(of: sentinel), end = try replicas[index].text(at: address).utf16.count
        try replicas[index].replaceText(at: address, range: end..<end, with: "<author-\(index)>")
    }
    try settle(replicas, random: &random)
    let withSentinels = try replicas[0].document
    for index in replicas.indices {
        try replicas[index].undo(); try settle(replicas, random: &random)
        let text = try replicas[0].text(at: replicas[0].textAddress(of: sentinel))
        for other in replicas.indices { #expect(text.contains("<author-\(other)>") == (other > index)) }
    }
    for replica in replicas { try replica.redo() }
    try settle(replicas, random: &random)
    #expect(try replicas[0].document == withSentinels)
    for replica in replicas { try replica.undo() }
    try settle(replicas, random: &random)
    try replicas[0].undo(); try settle(replicas, random: &random)
    #expect(try replicas[0].document == before)
}
