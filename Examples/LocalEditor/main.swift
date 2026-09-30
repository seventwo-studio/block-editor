import BlockEditorCore
import Foundation

let document = try Document(blocks: [.paragraph(id: "welcome", text: "Local document")])
let editor = try EditorSession(documentID: "local-example", actorID: "local-writer", document: document)
try editor.replaceText(at: TextAddress("welcome"), range: 14..<14, with: " — offline")
let file = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/block-editor-local.json")
try editor.save().write(to: file, options: .atomic)
let reopened = try EditorSession.restore(Data(contentsOf: file), actorID: "reopened-writer")
guard try reopened.document == editor.document else { fatalError("Save/reopen mismatch") }
print(try String(decoding: reopened.document.json(), as: UTF8.self))
