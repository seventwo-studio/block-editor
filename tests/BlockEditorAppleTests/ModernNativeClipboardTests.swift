#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI
import Testing
@testable import BlockEditorApple

@MainActor private final class ClipboardTestAccess: ModernClipboardAccess {
    let native: ModernNativeClipboard
    var succeeds = true
    var onPublish: (() throws -> Void)?
    init(_ board: NSPasteboard) { native = ModernNativeClipboard(pasteboard: board) }
    func read() throws -> ModernClipboardPayload? { try native.read() }
    func publish(_ clipboard: ModernClipboard) throws -> Bool {
        try onPublish?()
        return try succeeds && native.publish(clipboard)
    }
}
@MainActor private struct ClipboardTestCanvas: View {
    let model: ModernEditorModel
    let access: ClipboardTestAccess
    var body: some View {
        VStack {
            ForEach(model.document.blocks) { block in
                if let field = try? model.session.field(node: model.session.node(at: NodeAddress(block.id))) {
                    ModernTextInput(model: model, field: field, label: block.id, clipboard: access)
                }
            }
        }.frame(width: 500)
    }
}
@MainActor @Suite struct ModernNativeClipboardTests {
    private func pair() throws -> (ModernSession, ModernSession, ModernEditorModel) {
        let p = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "host": .string("keep"),
            "content": .array([.object(["type": .string("text"), "text": .string("ABC"), "marks": .array([.object(["type": .string("bold")])])]),
                .object(["type": .string("entity-ref"), "entityType": .string("note"), "entityId": .string("external"), "label": .string("REF")])])])
        let doc = try ModernDocument(documentID: "clipboard", title: "Title", blocks: [p, .paragraph(id: "q", text: "Other")])
        let a = try ModernSession(documentID: "clipboard", actorID: "a", epoch: "clipboard", document: doc)
        return (a, try ModernSession(documentID: "clipboard", actorID: "b", epoch: "clipboard", document: doc), ModernEditorModel(session: a))
    }
    private func window(_ model: ModernEditorModel, _ access: ClipboardTestAccess) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: ClipboardTestCanvas(model: model, access: access))
        window.contentView?.layoutSubtreeIfNeeded(); return window
    }
    private func view(_ label: String, _ root: NSView?) throws -> NSTextView {
        func collect(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(collect) }
        return try #require(root.map(collect)?.first { $0.accessibilityLabel() == label })
    }
    @Test func actualNativeCopyCutPasteKeepsRichAtomsPeerTextAndSharedUndo() async throws {
        let (a, b, model) = try pair(), board = NSPasteboard.withUniqueName(), access = ClipboardTestAccess(board)
        defer { board.releaseGlobally() }
        let window = window(model, access); defer { window.close() }
        let p = try view("p", window.contentView), q = try view("q", window.contentView)
        #expect(window.makeFirstResponder(p)); p.setSelectedRange(NSRange(location: 0, length: 3))
        let before = try a.save(); model.isEditable = false
        p.copy(nil)
        #expect(try a.save() == before && !a.canUndo && model.error == nil)
        let rich = try #require(try access.read()).decode()
        #expect(rich.plainText == "ABC")
        #expect(rich.parts == [.inline(["A", "B", "C"].map { .object(["type": .string("text"), "text": .string($0), "marks": .array([.object(["type": .string("bold")])])]) })])
        model.isEditable = true
        access.onPublish = {
            let field = try b.field(node: b.node(at: NodeAddress("p")))
            try b.replaceText(in: field, range: 2..<2, with: "R"); try model.receive(b.changes())
        }
        p.cut(nil); access.onPublish = nil
        #expect(a.document.blocks[0].text == "RREF" && model.clipboard.retained.isEmpty)
        #expect(a.document.blocks[0].fields["host"] == .string("keep"))
        #expect(board.string(forType: .string) == "ABC")
        try model.undo(); try await Task.sleep(for: .milliseconds(30))
        #expect(a.document.blocks[0].text == "ABRCREF")
        #expect(window.makeFirstResponder(q)); q.setSelectedRange(NSRange(location: 5, length: 0)); q.paste(nil)
        #expect(a.document.blocks[1].text == "OtherABC" && model.error == nil)
        #expect(a.document.blocks[1].fields["content"] == .array([
            .object(["type": .string("text"), "text": .string("Other"), "marks": .array([])]),
            .object(["type": .string("text"), "text": .string("ABC"), "marks": .array([.object(["type": .string("bold")])])])]))
        try model.undo(); #expect(a.document.blocks[1].text == "Other" && a.document.blocks[0].text == "ABRCREF")
    }
    @Test func failedPublicationKeepsTypingGroupAndDocumentSwitchCannotConsumeOldTicket() async throws {
        let (a, _, model) = try pair(), board = NSPasteboard.withUniqueName(), access = ClipboardTestAccess(board)
        defer { board.releaseGlobally() }
        let window = window(model, access); defer { window.close() }
        let p = try view("p", window.contentView)
        #expect(window.makeFirstResponder(p)); p.setSelectedRange(NSRange(location: 3, length: 0)); p.insertText("1", replacementRange: NSRange(location: 3, length: 0))
        access.succeeds = false
        let failedTarget = ModernDeleteTarget(ranges: [try a.captureTextRange(in: a.field(node: a.node(at: NodeAddress("p"))), start: 0, end: 1)])
        _ = try model.clipboard.cut(failedTarget, to: access)
        #expect(a.document.blocks[0].text == "ABC1REF" && model.clipboard.retained.count == 1)
        p.setSelectedRange(NSRange(location: 4, length: 0)); p.insertText("2", replacementRange: NSRange(location: 4, length: 0))
        try model.undo(); #expect(a.document.blocks[0].text == "ABCREF")
        let target = ModernDeleteTarget(ranges: [try a.captureTextRange(in: a.field(node: a.node(at: NodeAddress("p"))), start: 0, end: 3)])
        let prepared = try model.clipboard.prepareCut(target)
        let before = try a.save(); model.isActive = false; model.isActive = true
        #expect(model.clipboard.finishCut(prepared.id, published: true) == .retained(prepared.id, "Original clipboard invocation is inactive"))
        #expect(try a.save() == before)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModernHostStore(url: directory.appendingPathComponent("pair.json"), documentID: a.documentID, actorID: a.actorID)
        let checkpoint = try model.checkpoint(); try await store.save(checkpoint, replacing: nil)
        let restored = try #require(try await store.load()).restore()
        #expect(restored.retainedClipboard == model.clipboard.retained && restored.session.document == a.document)
        let reopened = ModernEditorModel(session: restored.session, retainedClipboard: restored.retainedClipboard)
        #expect(reopened.clipboard.finishCut(prepared.id, published: true) == .noop)
        #expect(reopened.clipboard.retained == restored.retainedClipboard)
    }
    @Test func malformedRichDoesNotFallBackAndExplicitRetryKeepsOriginalDestination() throws {
        let (a, _, model) = try pair(), board = NSPasteboard.withUniqueName(), access = ClipboardTestAccess(board)
        defer { board.releaseGlobally() }
        let window = window(model, access); defer { window.close() }
        let p = try view("p", window.contentView), q = try view("q", window.contentView)
        #expect(window.makeFirstResponder(p)); p.setSelectedRange(NSRange(location: 0, length: 0))
        let malformed = Data("{\"version\":2,\"version\":2}".utf8)
        board.setData(malformed, forType: NSPasteboard.PasteboardType(ModernNativeClipboard.identifier)); board.setString("DO NOT IMPORT", forType: .string)
        let before = try a.save(); p.paste(nil)
        #expect(try a.save() == before && model.clipboard.retained.first?.payload == .structured(malformed))
        let target = ModernPasteTarget(range: try a.captureTextRange(in: a.field(node: a.node(at: NodeAddress("p"))), start: 0, end: 0))
        a.allowedCommands = ["delete"]
        let result = try model.clipboard.paste(.text("Saved"), at: target)
        guard case .retained(let id, _) = result else { Issue.record("Paste should be retained"); return }
        #expect(window.makeFirstResponder(q)); q.setSelectedRange(NSRange(location: 5, length: 0)); a.allowedCommands = nil
        #expect(model.clipboard.retryPaste(id) == .applied)
        #expect(a.document.blocks[0].text == "SavedABCREF" && a.document.blocks[1].text == "Other")
        #expect(window.firstResponder === q && q.selectedRange().location == 5)
        let checkpoint = try model.checkpoint(), restored = try checkpoint.restore()
        #expect(restored.retainedClipboard.first?.payload == .structured(malformed))
    }
}
#endif
