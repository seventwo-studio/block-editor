#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
import SwiftUI
import Testing
@testable import BlockEditorApple
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Test func nativeCompositionFollowsMovedNodeWhenItsOldPathIsReused() throws {
    let paragraph = try Block(fields: ["id": .string("p"), "type": .string("paragraph"),
        "content": .array([textNode("Hello", marks: [.object(["type": .string("bold")])])])])
    let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"),
        "summary": .array([]), "children": .array([.object(paragraph.fields)])])
    let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"),
        "summary": .array([]), "children": .array([])])
    let document = try Document(blocks: [left, right])
    let a = try EditorSession(documentID: "native-nested", actorID: "a", document: document, collaborationVersion: 2)
    let b = try EditorSession(documentID: "native-nested", actorID: "b", document: document, collaborationVersion: 2)
    let live = TextAddress("left", path: ["children", "p", "content"])
    let identity = try b.node(at: NodeAddress("left", path: ["children", "p"]))
    let stable = try b.textAddress(of: identity)
    let model = try EditorModel(session: a)
    #if os(macOS)
    let coordinator = MacTextInput.Coordinator(model: model, address: live, selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    coordinator.connect(view)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #else
    let coordinator = UIKitTextInput.Coordinator(model: model, address: live, selection: .constant(NSRange(location: 0, length: 0)))
    let view = ComposingUIKitTextView()
    coordinator.connect(view)
    view.selectedRange = NSRange(location: 0, length: 0)
    view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    #endif
    defer { coordinator.close() }
    try b.moveNode(identity, into: NodeCollection(owner: b.node(at: NodeAddress("right")), field: "children"))
    let replacement = try b.insertNode(.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields),
        into: NodeCollection(owner: b.node(at: NodeAddress("left")), field: "children"))
    try b.replaceText(at: stable, range: 0..<0, with: "R")
    try a.receive(b.changes())
    #expect(a.syncState.received.isEmpty)
    view.unmarkText()
    #expect(coordinator.input.text == "R漢Hello")
    #expect(try a.text(at: a.textAddress(of: replacement)) == "REPLACEMENT")
    #expect(try a.address(of: identity) == NodeAddress("right", path: ["children", "p"]))
    let rendered = nativeAttributedText(coordinator.input)
    #expect(rendered.string == "R漢Hello")
    #if os(macOS)
    #expect(view.string == "R漢Hello")
    let font = rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? NSFont
    #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    #else
    #expect(view.text == "R漢Hello")
    let font = rendered.attribute(.font, at: rendered.length - 1, effectiveRange: nil) as? UIFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    #endif
    try a.undo()
    #expect(coordinator.input.text == "RHello")
    #expect(try a.text(at: a.textAddress(of: replacement)) == "REPLACEMENT")
    #expect(model.error == nil)
    try b.receive(a.changes())
    #expect(try a.document == b.document)
}
#endif
