import Foundation
import BlockEditorCore

// Copy into an isolated dependency consumer; never imports a source checkout.
let json = #"""
{"format":"seventwo.block-editor.document","formatVersion":1,"documentID":"native-installed-columns","title":"Installed 😀é","appearance":{"fontFamily":"serif","fontSize":"large","pageWidth":"wide"},"consumer":{"retain":["opaque",{"rows":[{"id":"not-an-editor-row"}]}]},"blocks":[{"id":"layout","type":"columns","splitBasisPoints":7000,"opaque":"layout","columns":[{"id":"left","opaque":"left","children":[{"id":"p","type":"paragraph","content":[{"type":"text","text":"Left 😀"},{"type":"entity-ref","entityType":"note","entityId":"original-reference","label":"Doc","opaque":{"keep":1}}]}]},{"id":"right","opaque":"right","children":[{"id":"q","type":"paragraph","content":[{"type":"text","text":"Right"}]}]}]}]}
"""#
let original = Data(json.utf8)
let expected = Data(json.replacingOccurrences(of: "Left 😀\"", with: "Left 😀!\"").utf8)
func exact(_ document: ModernDocument, _ bytes: Data) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let literal = try JSONDecoder().decode(JSONValue.self, from: bytes)
    guard try encoder.encode(JSONValue.object(document.fields)) == encoder.encode(literal) else {
        throw NSError(domain: "InstalledDocumentMismatch", code: 1)
    }
}
let document = try ModernDocument(json: original)
let session = try ModernSession(documentID: document.documentID, actorID: "installed", epoch: "installed-epoch", document: document)
try exact(session.document, original)
let address = NodeAddress("layout", path: ["columns", "left", "children", "p"])
let node = try session.node(at: address), field = try session.field(node: node)
guard try session.text(in: field) == "Left 😀Doc" else { throw NSError(domain: "InstalledTextMismatch", code: 1) }
try session.replaceText(in: session.captureTextRange(in: field, start: 7, end: 7), with: "!")
try exact(session.document, expected)
let reopened = try ModernSession.restore(session.save(), actorID: "installed")
guard try reopened.node(at: address) == node else { throw NSError(domain: "InstalledIdentityMismatch", code: 1) }
try exact(reopened.document, expected)
try reopened.undo(); try exact(reopened.document, original)
try reopened.redo(); try exact(reopened.document, expected)
let incompatible = json.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2")
do {
    _ = try ModernDocument(json: Data(incompatible.utf8))
    throw NSError(domain: "IncompatibleDocumentAccepted", code: 1)
} catch EditorError.unsupportedVersion { }
print("Native installed API smoke passed: exact Unicode/title/appearance, two columns, opaque metadata, atomic reference, stable identity, edit/save/reopen/Undo/Redo and incompatible format rejection")
