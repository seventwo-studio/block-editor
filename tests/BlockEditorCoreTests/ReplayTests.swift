import BlockEditorCore
import Foundation
import Testing

@Test func incrementalLocalEditsMatchFullReplayAfterEveryAction() throws {
    let baseline = try Document(blocks: [.paragraph(id: "p", text: "Hello 😀")])
    let a = try EditorSession(documentID: "d", actorID: "a", document: baseline)
    let b = try EditorSession(documentID: "d", actorID: "b", document: baseline)
    func check() throws {
        let replayed = try EditorSession.restore(a.save(), actorID: "observer")
        #expect(try replayed.document == a.document)
        #expect(replayed.syncState == a.syncState)
    }
    for round in 0..<50 {
        let text = try a.text(at: TextAddress("p"))
        try a.replaceText(at: TextAddress("p"), range: text.utf16.count..<text.utf16.count, with: "\(round)世界")
        try check()
        try a.format(at: TextAddress("p"), range: 0..<2, markType: "bold", mark: round % 2 == 0 ? .object(["type": .string("bold")]) : nil)
        try check()
        try a.insert(.paragraph(id: "block-\(round)", text: "Nested history"), after: "p")
        try check()
        try a.move(blockID: "block-\(round)", after: nil)
        try check()
        if round % 2 == 0 { try a.delete(blockID: "block-\(round)"); try check() }
        if round % 3 == 0 { try a.undo(); try check(); try a.redo(); try check() }
        if round % 4 == 0 {
            try b.replaceText(at: TextAddress("p"), range: 0..<0, with: "remote")
            try a.receive(b.changes()); try b.receive(a.changes())
        }
        try check()
    }
}
