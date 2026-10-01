import BlockEditorCore
import Foundation
import Testing

@Test(arguments: [1, 2]) func legacyStoppedAuthorReorderedUndoRedoKeepsWinningAvailability(version: Int) throws {
    let document = try Document(blocks: [.paragraph(id: "p", text: "a")])
    let original = try EditorSession(documentID: "legacy-order", actorID: "a", document: document, collaborationVersion: version)
    try original.replaceText(at: TextAddress("p"), range: 1..<1, with: "X")
    let accepted = try original.save(), stopped = try EditorSession.restore(accepted, actorID: "a")
    try stopped.undo(); let undo = stopped.changes().changes.last!
    try stopped.redo(); let redo = stopped.changes().changes.last!
    let resumed = try EditorSession.restore(accepted, actorID: "a")
    func packet(_ changes: [Change]) -> ChangeBatch { ChangeBatch(documentID: resumed.documentID, baseline: resumed.baseline, changes: changes, version: version) }
    try resumed.receive(packet([redo])); try resumed.receive(packet([undo]))
    #expect(try resumed.document.blocks[0].text == "aX")
    #expect(resumed.canUndo && !resumed.canRedo)
    let reopened = try EditorSession.restore(resumed.save(), actorID: "a")
    #expect(reopened.canUndo && !reopened.canRedo)
    try reopened.undo(); #expect(try reopened.document == document)
}
