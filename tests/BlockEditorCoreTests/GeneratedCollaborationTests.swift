import BlockEditorCore
import Foundation
import Testing

private struct Generator {
    var state: UInt64
    mutating func index(_ count: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(count))
    }
    mutating func shuffled<T>(_ values: [T]) -> [T] {
        var result = values
        for end in result.indices.reversed() where end > 0 {
            result.swapAt(end, index(end + 1))
        }
        return result
    }
}

/// UTF-16 boundaries retain whole atomic references and never split a scalar.
private func boundaries(_ nodes: [JSONValue]) -> [Int] {
    var result = [0]
    for node in nodes {
        let parts = node["type"]?.string == "text"
            ? (node["text"]?.string ?? "").unicodeScalars.map { String($0) }
            : [plainText([node])]
        for part in parts { result.append(result.last! + part.utf16.count) }
    }
    return Array(Set(result)).sorted()
}

@Test func concurrentFormattingPreservesRemoteInsertionAndIndependentMarks() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "ABC")])
    let a = try EditorSession(documentID: "marks", actorID: "a", document: baseline)
    let b = try EditorSession(documentID: "marks", actorID: "b", document: baseline)
    let address = TextAddress("p")
    let bold: JSONValue = .object(["type": .string("bold")])
    let italic: JSONValue = .object(["type": .string("italic")])
    try a.format(at: address, range: 0..<3, markType: "bold", mark: bold)
    try b.replaceText(at: address, range: 1..<1, with: "😀")
    try b.format(at: address, range: 0..<5, markType: "italic", mark: italic)
    // Formatting references the new atom before the packet introducing it arrives.
    for change in b.changes().changes.reversed() {
        try a.receive(ChangeBatch(documentID: "marks", baseline: baseline, changes: [change, change]))
    }
    try b.receive(a.changes())
    let expected = [textNode("A", marks: [bold, italic]), textNode("😀", marks: [italic]), textNode("BC", marks: [bold, italic])]
    #expect(try a.document.blocks[0].fields["content"] == .array(expected))
    #expect(try a.document == b.document)
    try a.undo(); try b.receive(a.changes())
    #expect(try b.document.blocks[0].fields["content"] == .array([textNode("A😀BC", marks: [italic])]))
    try a.redo(); try b.receive(a.changes())
    #expect(try b.document.blocks[0].fields["content"] == .array(expected))
    try b.undo(); try a.receive(b.changes())
    #expect(try a.document.blocks[0].fields["content"] == .array([
        textNode("A", marks: [bold]), textNode("😀"), textNode("BC", marks: [bold]),
    ]))
}

@Test(arguments: [1, 7, 42, 255, 65_537, 202_609_30, 999_983, 4_294_967_295] as [UInt64])
func generatedOfflineTextAndFormattingConverge(seed: UInt64) throws {
    var random = Generator(state: seed)
    let reference: JSONValue = .object([
        "type": .string("mention"), "entityId": .string("author"),
        "entityType": .string("user"), "label": .string("Mira 😀"),
    ])
    let nodes: [JSONValue] = [textNode("A😀e\u{301}世界", marks: [.object(["type": .string("italic")])]), reference, textNode("tail")]
    let baseline = try Document(blocks: [
        Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array(nodes)]),
        Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("unordered"),
                       "items": .array([.object(["id": .string("item"), "content": .array(nodes)])])]),
    ])
    let addresses = [TextAddress("p"), TextAddress("list", path: ["items", "item", "content"])]
    var replicas = try (0..<4).map { try EditorSession(documentID: "generated", actorID: "actor-\($0)", document: baseline) }
    let tokens = ["😀", "e\u{301}", "世界", "👩🏽‍💻", "אב", "\n", "x"]

    func nodesIn(_ session: EditorSession, _ address: TextAddress) throws -> [JSONValue] {
        try #require(session.document.blocks.first { $0.id == address.blockID }?.value(at: address.path)?.array)
    }
    // Some packets deliberately arrive before their causal predecessors. Receipt
    // sets must leave the gaps available for subsequent synchronization.
    func deliver(_ source: EditorSession, _ target: EditorSession, random: inout Generator) throws {
        let batch = source.changes(since: target.syncState)
        let shuffled = random.shuffled(batch.changes)
        let subset = Array(shuffled.prefix(max(1, shuffled.count / 2)))
        try target.receive(ChangeBatch(documentID: batch.documentID, baseline: batch.baseline, changes: subset + subset))
    }
    func settle(_ replicas: [EditorSession], random: inout Generator) throws {
        let changes = replicas.flatMap { $0.changes().changes }
        for replica in replicas {
            try replica.receive(ChangeBatch(documentID: "generated", baseline: baseline, changes: random.shuffled(changes)))
        }
        for replica in replicas.dropFirst() {
            #expect(try replica.document == replicas[0].document)
            #expect(replica.syncState == replicas[0].syncState)
            #expect(replica.changes(since: replicas[0].syncState).changes.isEmpty)
        }
    }

    for round in 0..<18 {
        for index in replicas.indices {
            let session = replicas[index], address = addresses[random.index(addresses.count)]
            let beforeNodes = try nodesIn(session, address)
            let before = plainText(beforeNodes), offsets = boundaries(beforeNodes)
            let first = random.index(offsets.count)
            let second = random.index(offsets.count)
            let low = offsets[min(first, second)], high = offsets[max(first, second)]
            switch (round + index) % 7 {
            case 0, 1, 2:
                let start = (round + index) % 7 == 0 ? high : low
                let inserted = (round + index) % 7 == 2 ? "" : tokens[random.index(tokens.count)]
                try session.replaceText(at: address, range: start..<high, with: inserted)
                let units = Array(before.utf16)
                let expected = String(decoding: units[..<start], as: UTF16.self) + inserted + String(decoding: units[high...], as: UTF16.self)
                #expect(try session.text(at: address) == expected, "seed \(seed), round \(round), actor \(index)")
            case 3, 4:
                let type = ["bold", "italic", "strikethrough"][random.index(3)]
                let mark: JSONValue? = (round + index) % 7 == 3 ? .object(["type": .string(type)]) : nil
                try session.format(at: address, range: low..<high, markType: type, mark: mark)
                #expect(try session.text(at: address) == before)
                let references = try nodesIn(session, address).filter { $0["type"]?.string != "text" }
                #expect(references == beforeNodes.filter { $0["type"]?.string != "text" })
            case 5: try session.undo()
            default: try session.redo()
            }
            let restored = try EditorSession.restore(session.save(), actorID: session.actorID)
            #expect(try restored.document == session.document)
            #expect(restored.canUndo == session.canUndo)
            #expect(restored.canRedo == session.canRedo)
            if round % 3 == 1 { replicas[index] = restored }
            // Actor zero remains partitioned for half of the history, including restarts.
            if round >= 9 || index != 0 {
                let target = round < 9 ? 1 + random.index(3) : random.index(4)
                if target != index { try deliver(replicas[index], replicas[target], random: &random) }
            }
        }
    }
    try settle(replicas, random: &random)
    let beforeSentinels = try replicas[0].document
    let sentinels = replicas.indices.map { "<author-\($0)>" }
    for index in replicas.indices {
        let end = try replicas[index].text(at: addresses[0]).utf16.count
        try replicas[index].replaceText(at: addresses[0], range: end..<end, with: sentinels[index])
    }
    try settle(replicas, random: &random)
    let withSentinels = try replicas[0].document
    for index in replicas.indices {
        try replicas[index].undo()
        try settle(replicas, random: &random)
        let text = try replicas[0].text(at: addresses[0])
        for other in replicas.indices { #expect(text.contains(sentinels[other]) == (other > index)) }
    }
    #expect(try replicas[0].document == beforeSentinels)
    for replica in replicas { try replica.redo() }
    try settle(replicas, random: &random)
    #expect(try replicas[0].document == withSentinels)
}
