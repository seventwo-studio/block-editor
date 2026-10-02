import Foundation
import Testing
@testable import BlockEditorCore

private func clipboardSession(_ actor: String, _ blocks: [Block]) throws -> WritingSession {
    try WritingSession(documentID: "clipboard", actorID: actor, epoch: "clipboard-v4", document: Document(blocks: blocks), protocolVersion: 4)
}

@Test func clipboardMixedCopyUsesVisibleOrderAfterRemoteMove() throws {
    let blocks = [try Block.paragraph(id: "first", text: "ABC"),
        try Block(fields: ["id": .string("middle"), "type": .string("quote"), "content": .array([textNode("middle")])]),
        try Block.paragraph(id: "last", text: "XYZ")]
    let a = try clipboardSession("a", blocks), b = try clipboardSession("b", blocks)
    let middle = try a.node(at: NodeAddress("middle"))
    let selection = try WritingSelection(nodes: [middle], text: [
        a.selectedText(at: TextAddress("last"), range: 0..<2),
        a.selectedText(at: TextAddress("first"), range: 1..<3)])
    let expected = WritingClipboard(parts: [.inline([textNode("B"), textNode("C")]),
        .node(value: .object(blocks[1].fields), kind: "block"), .inline([textNode("X"), textNode("Y")])])
    #expect(try a.copyClipboard(selection) == expected)
    try b.move(WritingSelection(nodes: [middle]), into: .root, after: b.node(at: NodeAddress("last")))
    try a.receive(b.changes())
    let changed = try a.copyClipboard(selection)
    #expect(changed.parts == [expected.parts[0], expected.parts[2], expected.parts[1]])
    #expect(try a.copy(selection).nodes == [.object(blocks[1].fields)])
}

@Test func clipboardRichPastePreservesReferencePayloadAndPeerUndoAcrossReopen() throws {
    let blocks = [try Block.paragraph(id: "p", text: "ABC")]
    let a = try clipboardSession("a", blocks), b = try clipboardSession("b", blocks)
    let range = try a.selectedText(at: TextAddress("p"), range: 1..<2)
    try b.replaceText(at: TextAddress("p"), range: 3..<3, with: " peer")
    try a.receive(b.changes())
    let reference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"),
        "entityId": .string("external-id"), "label": .string("Task"), "consumer": .object(["id": .string("opaque")])])
    let bold: JSONValue = .object(["type": .string("bold")])
    let clipboard = WritingClipboard(parts: [.inline([textNode("東京😀", marks: [bold]), reference])])
    let count = a.changes().changes.count
    let caret = try a.pasteInline(clipboard, replacing: range)
    #expect(a.document.blocks[0].text == "A東京😀TaskC peer")
    #expect(try a.resolve(caret).offset == "A東京😀Task".utf16.count)
    #expect(a.changes().changes.count == count + 1)
    #expect(a.document.blocks[0].fields["content"]?.array?.contains(reference) == true)
    #expect(a.document.blocks[0].fields["content"]?.array?.contains(where: { $0["marks"] == .array([bold]) && $0["text"] == .string("東京😀") }) == true)
    try b.receive(a.changes()); try b.receive(a.changes())
    #expect(a.document == b.document)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks[0].text == "ABC peer")
    #expect(!reopened.canUndo && reopened.canRedo)
    try reopened.redo()
    #expect(reopened.document == a.document)
}

@Test func clipboardCollectionFreshensOnlySchemaIDsAndUndoesOnceWithRemoteChildren() throws {
    let table = try Block(fields: ["id": .string("table"), "type": .string("table"),
        "consumer": .object(["id": .string("consumer-id")]),
        "rows": .array([.object(["id": .string("row"), "cells": .array([.object([
            "id": .string("cell"), "header": .bool(true), "content": .array([.object([
                "type": .string("mention"), "entityType": .string("user"), "entityId": .string("user-id"), "label": .string("User")])])])])])])])
    let blocks = [try Block.paragraph(id: "p", text: "before"), table]
    let a = try clipboardSession("a", blocks), b = try clipboardSession("b", blocks)
    let copied = try a.copyClipboard(WritingSelection(nodes: [a.node(at: NodeAddress("table"))]))
    let result = try a.pasteCollection(copied, into: .root, after: a.node(at: NodeAddress("table")))
    #expect(result.nodes.count == 1 && a.changes().changes.count == 1)
    let inserted = a.document.blocks[2]
    #expect(inserted.id != "table")
    #expect(inserted.fields["consumer"] == table.fields["consumer"])
    let row = try #require(inserted.fields["rows"]?.array?.first)
    let cell = try #require(row["cells"]?.array?.first)
    #expect(row["id"] != .string("row") && cell["id"] != .string("cell"))
    #expect(cell["content"]?.array?.first?["entityId"] == .string("user-id"))
    try b.receive(a.changes())
    try b.replaceText(at: TextAddress(inserted.id, path: ["rows", row["id"]!.string!, "cells", cell["id"]!.string!, "content"]), range: 4..<4, with: " peer")
    try a.receive(b.changes())
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.undo()
    #expect(reopened.document.blocks.count == 3)
    #expect(reopened.document.blocks[2].fields["consumer"] == table.fields["consumer"])
    #expect(reopened.document.blocks[2].fields["rows"]?.array?.first?["cells"]?.array?.first?["content"]?.array.map(plainText) == " peer")
    #expect(!reopened.canUndo && reopened.canRedo)
}

@Test func clipboardPoliciesRejectUnsafeOrRestrictedImportsWithoutChangingHistory() throws {
    let a = try clipboardSession("a", [Block.paragraph(id: "p", text: "keep")])
    let range = try a.selectedText(at: TextAddress("p"), range: 0..<4)
    let before = try a.save()
    for href in ["javascript:alert(1)", "data:text/html,x", "file:///secret", "https://", "https://example.test/\npath"] {
        let imported = WritingClipboard(parts: [.inline([textNode("bad", marks: [.object(["type": .string("link"), "href": .string(href)])])])])
        do { _ = try a.pasteInline(imported, replacing: range); Issue.record("Unsafe URL accepted") } catch { }
        #expect(try a.save() == before)
    }
    let rich = WritingClipboard(parts: [.inline([textNode("bold", marks: [.object(["type": .string("bold")])])])])
    do { _ = try a.pasteInline(rich, replacing: range, policy: WritingPastePolicy(allowedMarkTypes: [])); Issue.record("Restricted mark accepted") } catch { }
    #expect(try a.save() == before)
    let image = WritingClipboard(parts: [.node(value: .object(["id": .string("image"), "type": .string("image"), "src": .string("asset:owned")]), kind: "block")])
    do { _ = try a.pasteCollection(image, into: .root); Issue.record("Unapproved asset metadata accepted") } catch { }
    #expect(try a.save() == before)
    a.allowedBlockTypes = ["paragraph"]
    do { _ = try a.pasteCollection(image, into: .root, policy: WritingPastePolicy(allowAssetMetadata: true)); Issue.record("Restricted image accepted") } catch { }
    #expect(try a.save() == before)
    a.isComposing = true
    do { _ = try a.pasteInline(.plainText("blocked"), replacing: range); Issue.record("Composing paste accepted") } catch { }
    #expect(try a.save() == before)
}

@Test func clipboardPlainTextNormalizesLineEndingsInOneUndoAction() throws {
    let a = try clipboardSession("a", [Block.paragraph(id: "p", text: "AB")])
    let caret = try a.pasteInline(.plainText("東京\r\n😀\r"), replacing: a.selectedText(at: TextAddress("p"), range: 1..<1))
    #expect(a.document.blocks[0].text == "A東京\n😀\nB")
    #expect(try a.resolve(caret).offset == "A東京\n😀\n".utf16.count)
    try a.undo()
    #expect(a.document.blocks[0].text == "AB" && !a.canUndo)
}

@Test func clipboardMarkdownDividerRoundTripsWithFreshIdentityAndPolicy() throws {
    let a = try clipboardSession("a", [Block.paragraph(id: "p", text: "before")])
    let imported = try WritingClipboard.markdown("# Title\n\n---\n\n**東京😀**")
    let added = try a.pasteCollection(imported, into: .root, after: a.node(at: NodeAddress("p")))
    #expect(a.document.blocks.map(\.type) == ["paragraph", "heading", "divider", "paragraph"])
    // Existing Swift and React Markdown import deliberately preserve inline delimiters literally.
    #expect(a.document.blocks[3].text == "**東京😀**")
    #expect(a.changes().changes.count == 1)
    let divider = try a.copyClipboard(WritingSelection(nodes: [added.nodes[1]]))
    let copied = try a.pasteCollection(divider, into: .root, after: added.nodes[2])
    #expect(copied.nodes.count == 1)
    #expect(a.document.blocks[4].type == "divider")
    #expect(a.document.blocks[2].id != a.document.blocks[4].id)
    let before = try a.save()
    do {
        _ = try a.pasteCollection(divider, into: .root, policy: WritingPastePolicy(allowedBlockTypes: ["paragraph"]))
        Issue.record("Restricted divider was authored")
    } catch EditorError.restrictedBlock("divider") { }
    #expect(try a.save() == before)
    try a.undo()
    #expect(a.document.blocks.count == 4)
    let reopened = try WritingSession.restore(a.save(), actorID: "a")
    try reopened.redo()
    #expect(reopened.document.blocks.map(\.type) == ["paragraph", "heading", "divider", "paragraph", "divider"])
}
