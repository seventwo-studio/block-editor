import BlockEditorCore
import Foundation

let document = try Document(blocks: [.paragraph(id: "shared", text: "Hello")])
let alice = try EditorSession(documentID: "shared-example", actorID: "alice", document: document)
let bob = try EditorSession(documentID: "shared-example", actorID: "bob", document: document)
// No transport is attached while these edits occur.
try alice.replaceText(at: TextAddress("shared"), range: 5..<5, with: " Alice")
try bob.replaceText(at: TextAddress("shared"), range: 5..<5, with: " Bob")
let fromAlice = alice.changes(since: bob.syncState)
let fromBob = bob.changes(since: alice.syncState)
try alice.receive(fromBob); try bob.receive(fromAlice); try bob.receive(fromAlice)
guard try alice.document == bob.document else { fatalError("Reconnect did not converge") }
alice.receivePresence(Presence(actor: "bob", address: TextAddress("shared"), revision: 1))
try alice.undo()
try bob.receive(alice.changes(since: bob.syncState))
guard try alice.document == bob.document, try alice.document.blocks[0].text == "Hello Bob" else {
    fatalError("Local undo affected remote content")
}
print(try String(decoding: alice.document.json(), as: UTF8.self))
print("Offline edits converged; duplicate delivery was harmless; local undo retained Bob's text.")
