#if canImport(SwiftUI)
import BlockEditorCore
import Foundation
import Testing
@testable import BlockEditorApple

@MainActor @Test(arguments: [4, 5, 6])
func writingPlatformSubmitEchoPreservesDeferredPeerAndAuthorUndo(version: Int) throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"),
        "entityId": .string("task"), "label": .string("TASK"), "consumer": .string("keep")])
    let italic: JSONValue = .object(["type": .string("italic")])
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "consumer": .string("keep"),
        "content": .array([textNode("café 東京😀", marks: [italic]), reference])])
    let document = try Document(blocks: [block, .paragraph(id: "other", text: "untouched")])
    let a = try WritingSession(documentID: "platform-echo", actorID: "apple", epoch: "v\(version)", document: document, protocolVersion: version)
    let b = try WritingSession.restore(a.save(), actorID: "peer")
    let model = try WritingEditorModel(session: a)
    let draft = WritingPlatformDraft(model: model, address: TextAddress("p"))
    defer { draft.close() }
    draft.begin(); draft.change("café 東京😀TASKa")
    try b.replaceText(at: TextAddress("p"), range: "café 東京😀TASK".utf16.count..<"café 東京😀TASK".utf16.count, with: "R")
    try a.receive(b.changes())
    let deferred = try JSONSerialization.jsonObject(with: a.exportDeferredChanges()) as? [Any]
    #expect(a.isComposing && deferred?.count == 1)
    draft.finish()
    let merged = try a.save()
    let mergedText = try a.text(at: TextAddress("p"))
    #expect(mergedText == "café 東京😀TASKRa")
    draft.change("café 東京😀TASKa"); draft.finish()
    #expect(try a.save() == merged)
    #expect(draft.draft == "café 東京😀TASKRa" && model.error == nil)
    #expect(a.document.blocks[0].fields["content"]?.array?.contains(reference) == true)
    #expect(a.document.blocks[1] == document.blocks[1])
    model.perform { try $0.undo() }
    #expect(try a.text(at: TextAddress("p")) == "café 東京😀TASKR")
    model.perform { try $0.redo() }
    #expect(try a.text(at: TextAddress("p")) == "café 東京😀TASKRa")
    let reopened = try WritingSession.restore(a.save(), actorID: "apple")
    try reopened.undo()
    #expect(try reopened.text(at: TextAddress("p")) == "café 東京😀TASKR")
    try b.receive(a.changes()); #expect(a.document == b.document)
    // A new native editing lifecycle can intentionally return to an older value.
    draft.begin(); draft.change("café 東京😀TASKa"); draft.finish()
    #expect(try a.text(at: TextAddress("p")) == "café 東京😀TASKa")
}
@MainActor @Test
func writingPlatformCommittedDictationAndDuplicateFinish() throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "before")])
    let session = try WritingSession(documentID: "platform-dictation", actorID: "apple", epoch: "v6", document: document, protocolVersion: 6)
    let model = try WritingEditorModel(session: session)
    let draft = WritingPlatformDraft(model: model, address: TextAddress("p"))
    draft.change("café 東京😀")
    let committed = try session.save()
    draft.change("café 東京😀"); draft.finish(); draft.close()
    #expect(try session.save() == committed)
    #expect(model.error == nil && !session.isComposing)
    try session.undo()
    #expect(try session.text(at: TextAddress("p")) == "before")
    try session.redo()
    #expect(try session.text(at: TextAddress("p")) == "café 東京😀")
}
#endif
