import Foundation
import Testing
@testable import BlockEditorCore

private let importBold: JSONValue = .object(["type": .string("bold")])
private let importReference: JSONValue = .object(["type": .string("entity-ref"), "entityType": .string("task"),
    "entityId": .string("task-original"), "label": .string("Mira"), "consumer": .object(["id": .string("opaque-ref")])])
private func importSession(_ actor: String, version: Int = 4) throws -> WritingSession {
    try WritingSession(documentID: "external-import", actorID: actor, epoch: "external-import-\(version)",
        document: Document(blocks: [Block.paragraph(id: "p", text: "AB")]), protocolVersion: version)
}

@Test(arguments: [4, 5]) func externalNormalizationPreservesRichReferenceAndPeerUndo(version: Int) throws {
    let a = try importSession("a", version: version), b = try importSession("b", version: version)
    let unsafe = JSONValue.object(["type": .string("link"), "href": .string("javascript:alert(1)")])
    let unknown = JSONValue.object(["type": .string("external-color"), "value": .string("red")])
    let external = WritingClipboard(parts: [.inline([textNode("東京😀", marks: [importBold, unsafe, unknown]), importReference])])
    let untouched = external
    let before = try a.save()
    let range = try a.selectedText(at: TextAddress("p"), range: 1..<1)
    #expect(throws: (any Error).self) { try a.pasteInline(external, replacing: range) }
    #expect(try a.save() == before)
    let imported = try external.normalizeForImport()
    #expect(external == untouched && imported.clipboard.parts == [.inline([textNode("東京😀", marks: [importBold]), importReference])])
    #expect(try a.save() == before)
    try b.replaceText(at: TextAddress("p"), range: 2..<2, with: "R")
    try a.receive(b.changes())
    _ = try a.pasteInline(imported.clipboard, replacing: range, policy: imported.effectivePastePolicy)
    #expect(a.document.blocks[0].text == "A東京😀MiraBR")
    #expect(a.document.blocks[0].fields["content"]?.array?.contains(importReference) == true)
    #expect(a.changes().changes.filter { $0.id.actor == "a" }.count == 1)
    try b.receive(a.changes()); try b.receive(a.changes()); #expect(a.document == b.document)
    let restored = try WritingSession.restore(a.save(), actorID: "a")
    try restored.undo(); #expect(restored.document.blocks[0].text == "ABR" && !restored.canUndo)
    try restored.redo(); #expect(restored.document == a.document)
}

@Test func externalNormalizationFallbackKeepsVisibleNestedOrderAndAllowedRichNodes() throws {
    let item: JSONValue = .object(["id": .string("same"), "content": .array([textNode("one", marks: [importBold])]),
        "children": .array([.object(["id": .string("same"), "content": .array([importReference])])])])
    let value: JSONValue = .object(["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([item])])
    let imported = try WritingClipboard(parts: [.node(value: value, kind: "block")]).normalizeForImport(
        policy: WritingPastePolicy(allowedBlockTypes: [], allowedMarkTypes: ["bold"]))
    #expect(imported.effectivePastePolicy.allowedBlockTypes == ["paragraph"])
    let part = try #require(imported.clipboard.parts.first)
    guard case .node(let paragraph, let kind) = part else { Issue.record("Expected paragraph fallback"); return }
    #expect(kind == "block" && paragraph["type"] == .string("paragraph"))
    #expect(paragraph["content"] == .array([textNode("one", marks: [importBold]), textNode("\n"), importReference]))
    #expect(paragraph["items"] == nil)
    let row: JSONValue = .object(["id": .string("row"), "cells": .array([
        .object(["id": .string("c1"), "content": .array([textNode("A")])]),
        .object(["id": .string("c2"), "content": .array([textNode("B")])])])])
    let table: JSONValue = .object(["id": .string("table"), "type": .string("table"), "rows": .array([row])])
    let normalized = try WritingClipboard(parts: [.node(value: table, kind: "block")]).normalizeForImport(policy: WritingPastePolicy(allowedBlockTypes: []))
    guard case .node(let p, _) = normalized.clipboard.parts[0] else { Issue.record("Expected table text fallback"); return }
    #expect(p["content"]?.array.map(plainText) == "A\tB")
}

@Test func externalNormalizationDoesNotRelaxLiveHostPolicy() throws {
    let a = try importSession("a")
    a.allowedBlockTypes = []
    let before = try a.save()
    let imported = try WritingClipboard(parts: [.node(value: .object(["id": .string("h"), "type": .string("heading"),
        "level": .number(2), "content": .array([textNode("Title")])]), kind: "block")]).normalizeForImport(
            policy: WritingPastePolicy(allowedBlockTypes: ["heading"]), hostBlockTypes: a.allowedBlockTypes)
    #expect(imported.suggestedHostBlockTypes == ["paragraph"] && a.allowedBlockTypes == [])
    #expect(throws: (any Error).self) { try a.pasteCollection(imported.clipboard, into: .root, policy: imported.effectivePastePolicy) }
    #expect(try a.save() == before)
    a.allowedBlockTypes = imported.suggestedHostBlockTypes
    _ = try a.pasteCollection(imported.clipboard, into: .root, after: a.node(at: NodeAddress("p")), policy: imported.effectivePastePolicy)
    #expect(a.document.blocks.map(\.type) == ["paragraph", "paragraph"])
    #expect(a.document.blocks[1].text == "Title" && a.changes().changes.count == 1)
    try a.undo(); #expect(a.document.blocks.count == 1)
}

@Test func externalNormalizationRequiresExplicitSafeAssetMetadata() throws {
    func image(_ src: String) -> WritingClipboard {
        WritingClipboard(parts: [.node(value: .object(["id": .string("img"), "type": .string("image"), "src": .string(src),
            "alt": .string("Photo"), "caption": .array([importReference])]), kind: "block")])
    }
    for (source, allowed) in [("https://example.test/image.png", false), ("javascript:alert(1)", true)] {
        let imported = try image(source).normalizeForImport(policy: WritingPastePolicy(allowAssetMetadata: allowed))
        guard case .node(let node, _) = imported.clipboard.parts[0] else { Issue.record("Expected node"); return }
        #expect(node["type"] == .string("paragraph") && node["src"] == nil)
        #expect(node["content"]?.array.map(plainText) == "Photo\nMira")
    }
    let accepted = try image("asset:owned").normalizeForImport(policy: WritingPastePolicy(allowAssetMetadata: true))
    guard case .node(let node, _) = accepted.clipboard.parts[0] else { Issue.record("Expected image"); return }
    #expect(node["type"] == .string("image") && node["src"] == .string("asset:owned"))
    #expect(node["caption"] == .array([importReference]))
}

@Test func externalNormalizationFreshensSchemaLabelsWithoutChangingOpaqueReferenceData() throws {
    let item: JSONValue = .object(["id": .string("duplicate"), "content": .array([importReference]),
        "consumer": .object(["id": .string("keep")])])
    let input = WritingClipboard(parts: [.node(value: .object(["id": .string("l"), "type": .string("list"),
        "style": .string("unordered"), "items": .array([item, item])]), kind: "block")])
    let result = try input.normalizeForImport()
    guard case .node(let list, _) = result.clipboard.parts[0] else { Issue.record("Expected list"); return }
    let items = try #require(list["items"]?.array)
    #expect(items.count == 2 && items[0]["id"] != items[1]["id"])
    #expect(items.allSatisfy { $0["consumer"] == item["consumer"] && $0["content"] == .array([importReference]) })
    let unsafe = WritingClipboard(parts: [.inline([textNode("X", marks: [.object(["type": .string("link"), "href": .string("https://example.test/\npath")])])])])
    #expect(try unsafe.normalizeForImport().clipboard.parts == [.inline([textNode("X")])])
}

@Test func externalNormalizationRejectsVersionDepthAndUnknownKindWithoutMutatingSource() throws {
    let wrong = WritingClipboard(parts: [.inline([textNode("keep")])], version: 2)
    #expect(throws: EditorError.unsupportedVersion(2)) { try wrong.normalizeForImport() }
    var deep = JSONValue.string("keep")
    for _ in 0..<101 { deep = .array([deep]) }
    let external = WritingClipboard(parts: [.node(value: .object(["id": .string("p"), "type": .string("paragraph"),
        "content": .array([]), "opaque": deep]), kind: "block")])
    #expect(throws: EditorError.invalidRange) { try external.normalizeForImport() }
    #expect(external.parts == [.node(value: .object(["id": .string("p"), "type": .string("paragraph"), "content": .array([]), "opaque": deep]), kind: "block")])
    #expect(throws: EditorError.invalidPath) { try WritingClipboard(parts: [.node(value: .object([:]), kind: "foreign")]).normalizeForImport() }
    let malformedReference = JSONValue.object(["type": .string("entity-ref"), "label": .string("Visible")])
    #expect(try WritingClipboard(parts: [.inline([malformedReference])]).normalizeForImport().clipboard.parts == [.inline([textNode("Visible")])])
}

@Test func externalNormalizationDoesNotCommitOrReleaseComposition() throws {
    let a = try importSession("a")
    let before = try a.save(), receipt = a.syncState
    a.isComposing = true
    let imported = try WritingClipboard(parts: [.inline([textNode("foreign", marks: [.object(["type": .string("unknown")])])])]).normalizeForImport()
    #expect(imported.clipboard.parts == [.inline([textNode("foreign")])])
    #expect(a.isComposing && a.syncState == receipt)
    #expect(try a.save() == before)
    let range = try a.selectedText(at: TextAddress("p"), range: 0..<2)
    #expect(throws: (any Error).self) { try a.pasteInline(imported.clipboard, replacing: range, policy: imported.effectivePastePolicy) }
    #expect(try a.save() == before)
    a.isComposing = false
}

@Test func externalNormalizationResultPolicyArraysHaveDeterministicWireOrder() throws {
    let external = WritingClipboard(parts: [.node(value: .object(["id": .string("import"), "type": .string("list"),
        "style": .string("unordered"), "items": .array([.object(["id": .string("item"), "content": .array([textNode("Title")])])])]), kind: "block")])
    let result = try external.normalizeForImport(policy: WritingPastePolicy(allowedBlockTypes: ["quote", "heading"],
        allowedMarkTypes: ["italic", "bold"]), hostBlockTypes: ["toggle", "callout"])
    let expected = #"{"clipboard":{"parts":[{"node":{"kind":"block","value":{"content":[{"marks":[],"text":"Title","type":"text"}],"id":"clipboard-import-1","type":"paragraph"}}}],"version":1},"effectivePastePolicy":{"allowAssetMetadata":false,"allowedBlockTypes":["heading","paragraph","quote"],"allowedMarkTypes":["bold","italic"]},"suggestedHostBlockTypes":["callout","paragraph","toggle"]}"#
    let encoded = try canonicalEncoder().encode(result)
    #expect(String(decoding: encoded, as: UTF8.self) == expected)
    #expect(try JSONDecoder().decode(WritingImportResult.self, from: encoded) == result)
}

@Test func externalUnknownWholeNodeFallbackKeepsRecognizedVisibleFieldsOnly() throws {
    let external: JSONValue = .object(["id": .string("external"), "type": .string("foreign-widget"),
        "title": .string("Title"), "description": .string("Description"),
        "items": .array([.object(["id": .string("item"), "content": .array([importReference])])]),
        "opaque": .object(["text": .string("hidden metadata"), "children": .array([textNode("not a schema child")])])])
    let result = try WritingClipboard(parts: [.node(value: external, kind: "block")]).normalizeForImport()
    let expected: JSONValue = .object(["id": .string("clipboard-import-1"), "type": .string("paragraph"),
        "content": .array([textNode("Title"), textNode("\n"), textNode("Description"), textNode("\n"), importReference])])
    #expect(result.clipboard.parts == [.node(value: expected, kind: "block")])
}
