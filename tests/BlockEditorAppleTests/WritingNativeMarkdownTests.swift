#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

/// Native callback proofs; installed clipboard/menu/device acceptance is separate.
@MainActor @Test(arguments: [4, 5, 6])
func writingNativeMarkdownIsExplicitAndKeepsOrdinaryPasteLiteral(version: Int) throws {
    let literal = try WritingNativeClipboard.decode(.text("# Heading"), protocolVersion: version)
    #expect(literal == WritingClipboard.plainText("# Heading"))
    let input = "café😀 **literal emphasis** [visible](https://example.com)"
    let parsed = try WritingNativeClipboard.decode(.markdown(input), protocolVersion: version)
    if version == 4 { #expect(parsed == WritingClipboard.plainText(input)) }
    else { #expect(try parsed == WritingClipboard.markdown(input)) }
    // The existing shared Markdown dialect leaves inline syntax literal.
    let session = try WritingSession(documentID: "native-markdown-explicit", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: "")]), protocolVersion: version)
    let model = try WritingEditorModel(session: session)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    let menu = view.pasteMarkdownMenuItem()
    #expect(menu.title == "Paste Markdown" && menu.keyEquivalent.isEmpty && menu.target === view)
    let callback = try #require(view.pasteSharedClipboard)
    #expect(callback(.text("# Heading")))
    #expect(session.document.blocks.map(\.text) == ["# Heading"] && session.document.blocks[0].type == "paragraph")
    #expect(session.protocolVersion == version && session.epoch == "v\(version)")
    view.isEditable = false; #expect(!view.pasteMarkdownMenuItem().isEnabled)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingNativeMarkdownFinalizesMarkedInputBeforePasteAndPreservesPeerRichUndo(version: Int) throws {
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("original-task"), "label": .string("TASK"), "host": .object(["id": .string("opaque-reference")])])
    let opaque: JSONValue = .object(["id": .string("original-owner"), "unknown": .array([.bool(true), .string("keep")])])
    let paragraph = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([textNode("AB", marks: [.object(["type": .string("italic")])]), reference]), "consumer": opaque])
    let document = try Document(blocks: [paragraph])
    let a = try WritingSession(documentID: "native-markdown-composition", actorID: "a", epoch: "v\(version)", document: document, protocolVersion: version)
    let b = try WritingSession(documentID: "native-markdown-composition", actorID: "b", epoch: "v\(version)", document: document, protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 1, length: 0))
    _ = try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "R"); try a.receive(b.changes())
    #expect(a.isComposing && a.document == document && view.hasMarkedText())
    let callback = try #require(view.pasteSharedClipboard)
    #expect(callback(.markdown("café😀")))
    #expect(model.error == nil && !a.isComposing && !view.hasMarkedText())
    #expect(a.document.blocks.map(\.text).joined() == "A東京café😀BRTASK")
    #expect(a.document.blocks[0].fields["consumer"] == opaque)
    let richContent: [JSONValue] = a.document.blocks.flatMap { $0.fields["content"]?.array ?? [] }
    let retainsReference = richContent.contains(reference)
    let retainsItalicPrefix = richContent.contains { value in
        value["text"]?.string?.contains("A") == true && value["marks"] == .array([.object(["type": .string("italic")])])
    }
    #expect(retainsReference)
    #expect(retainsItalicPrefix)
    try b.receive(a.changes()); #expect(a.document == b.document)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    #expect(reopened.protocolVersion == version && reopened.epoch == "v\(version)")
    try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["A東京BRTASK"])
    try reopened.redo(); #expect(reopened.document == a.document)
    try reopened.undo(); try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["ABRTASK"])
}

@MainActor @Test(arguments: [5, 6])
func writingNativeStructuralMarkdownUsesSharedNodesAndHostFallbackWithoutAssets(version: Int) throws {
    let a = try WritingSession(documentID: "native-markdown-blocks", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: "AB")]), protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(); coordinator.connect(view); defer { coordinator.close() }
    view.setSelectedRange(NSRange(location: 1, length: 0)); coordinator.input.selection = view.selectedRange()
    let callback = try #require(view.pasteSharedClipboard)
    let markdown = "# Heading\n\n- [x] Task\n\n```swift\nlet x = 1\n```\n\n| A | B |\n| --- | --- |\n| café😀 | R |"
    #expect(callback(.markdown(markdown)))
    #expect(a.document.blocks.map(\.type) == ["paragraph", "heading", "list", "code", "table", "paragraph"])
    #expect(a.document.blocks[1].text == "Heading" && a.document.blocks[1].fields["level"] == .number(1))
    #expect(a.document.blocks[2].fields["style"] == .string("todo"))
    #expect(a.document.blocks[2].fields["items"]?.array?.first?["checked"] == .bool(true))
    #expect(a.document.blocks[3].fields["code"] == .string("let x = 1"))
    #expect(a.document.blocks[4].fields["rows"]?.array?.count == 2)
    #expect(Set(a.document.blocks.map(\.id)).count == a.document.blocks.count)
    #expect(a.changes().changes.count == 1)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo(); #expect(reopened.document.blocks.map(\.text) == ["AB"])
    try reopened.redo(); #expect(reopened.document == a.document)
    try a.undo()
    model.allowedBlockTypes = ["paragraph"]
    model.pastePolicy = WritingPastePolicy(allowedBlockTypes: ["paragraph"])
    view.setSelectedRange(NSRange(location: 1, length: 0)); coordinator.input.selection = view.selectedRange()
    #expect(callback(.markdown("# Heading\n\n![café😀](https://example.com/image.png)")))
    #expect(a.document.blocks.allSatisfy { $0.type == "paragraph" })
    #expect(a.document.blocks.map(\.text).joined() == "AHeadingcafé😀B")
    #expect(a.allowedBlockTypes == ["paragraph"])
    #expect(model.pastePolicy.allowedBlockTypes == ["paragraph"] && !model.pastePolicy.allowAssetMetadata)
}

@MainActor @Test(arguments: [4, 5, 6])
func writingNativeMarkdownFailureAndRetiredCallbacksPreserveAcceptedHistory(version: Int) throws {
    let a = try WritingSession(documentID: "native-markdown-guards", actorID: "a", epoch: "v\(version)", document: Document(blocks: [.paragraph(id: "p", text: "A")]), protocolVersion: version)
    let model = try WritingEditorModel(session: a)
    let coordinator = WritingMacTextInput.Coordinator(model: model, address: TextAddress("p"))
    let view = WritingMacTextView(); coordinator.connect(view)
    let callback = try #require(view.pasteSharedClipboard), accepted = try a.save()
    model.allowedBlockTypes = ["heading"]
    #expect(!callback(.markdown(version == 4 ? "# Disallowed" : "Disallowed paragraph")))
    #expect(model.error != nil && a.protocolVersion == version && a.epoch == "v\(version)")
    #expect(try a.save() == accepted)
    model.allowedBlockTypes = nil
    #expect(!callback(.markdown(String(repeating: "x", count: 1_000_001))))
    #expect(try a.save() == accepted)
    #expect(!callback(.markdown(String(repeating: "x\n", count: 10_001))))
    #expect(try a.save() == accepted)
    if version == 4 {
        #expect(!callback(.markdown("one\n\ntwo")))
        #expect(try a.save() == accepted)
    }
    view.isEditable = false; #expect(!callback(.markdown("readonly"))); #expect(try a.save() == accepted)
    view.isEditable = true; coordinator.close()
    #expect(!callback(.markdown("retired"))); #expect(try a.save() == accepted)
}
#endif
