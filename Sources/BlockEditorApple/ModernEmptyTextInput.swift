#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A native composition buffer at a captured empty-document boundary. No shared
/// placeholder is inserted until native marked text has committed.
@MainActor public struct ModernEmptyTextInput: View {
    private let model: ModernEditorModel
    @State private var hasText = false
    public init(model: ModernEditorModel) { self.model = model }
    public var body: some View {
        ModernEmptyPlatformInput(model: model, hasText: $hasText, editable: model.isEditable && model.isActive)
            .frame(minHeight: 44).overlay(alignment: .topLeading) {
                if !hasText { Text("Start writing…").foregroundStyle(.secondary).padding(4).allowsHitTesting(false) }
            }
    }
}
@MainActor private struct ModernEmptyPlatformInput {
    let model: ModernEditorModel
    @Binding var hasText: Bool
    let editable: Bool
    func makeCoordinator() -> ModernEmptyCoordinator { ModernEmptyCoordinator(model: model, changed: { hasText = $0 }) }
}
@MainActor private final class ModernEmptyCoordinator: NSObject {
    let model: ModernEditorModel
    let id = UUID()
    let boundary: ModernBlockBoundary?
    let changed: (Bool) -> Void
    var release: (() throws -> Void)?
    weak var originalWindow: AnyObject?
    var permitted: (() -> Bool)?
    var composing = false
    var accepted = false
    init(model: ModernEditorModel, changed: @escaping (Bool) -> Void) {
        self.model = model; self.changed = changed; boundary = try? model.session.captureBoundary()
    }
    func input(_ text: String, marked: Bool) {
        guard !accepted, let boundary else { return }
        changed(!text.isEmpty)
        do {
            if marked && !composing { release = try model.session.holdRemoteChanges(); composing = true; model.composition(id, active: true) }
            try model.clipboard.retainInput(text, at: .init(boundary: boundary), id: id, reason: marked ? "compositionActive" : "awaitingCommit")
            guard !marked else { return }
            composing = false; model.composition(id, active: false)
            guard !text.isEmpty, model.isActive, model.isEditable else {
                if text.isEmpty { try model.clipboard.forget(id) }
                let finish = release; release = nil; try finish?(); return
            }
            let result = model.clipboard.retryPaste(id, mode: .plainText)
            try finish(result)
            let finish = release; release = nil; try finish?()
        } catch { model.report(error) }
    }
    func paste() {
        guard !composing, let boundary, model.isActive, model.isEditable else { return }
        do { if let payload = try ModernNativeClipboard().read() { try finish(model.clipboard.paste(payload, at: .init(boundary: boundary))) } }
        catch { model.report(error) }
    }
    private func finish(_ result: ModernHostClipboardResult) throws {
        guard result == .applied else { return }; accepted = true
        if let intent = try model.session.resolvedLocalSelection()?.focus, let window = originalWindow, let permitted { model.requestFocus(intent, in: window, permitted: permitted) }
    }
    func close() { composing = false; model.composition(id, active: false); do { try release?(); release = nil } catch { model.report(error) } }
}
#if os(macOS)
@MainActor private final class ModernEmptyMacView: NSTextView {
    var changed: (() -> Void)?
    var pasteAction: (() -> Void)?
    private var depth = 0
    private func editing(_ work: () -> Void) { depth += 1; defer { depth -= 1; if depth == 0 { changed?() } }; work() }
    override func insertText(_ value: Any, replacementRange: NSRange) { editing { super.insertText(value, replacementRange: replacementRange) } }
    override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) { editing { super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange) } }
    override func unmarkText() { editing { super.unmarkText() } }
    override func doCommand(by selector: Selector) { editing { super.doCommand(by: selector) } }
    override func paste(_ sender: Any?) { if hasMarkedText() { super.paste(sender) } else { pasteAction?() } }
    override var undoManager: UndoManager? { nil }
}
extension ModernEmptyPlatformInput: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), view = ModernEmptyMacView(); scroll.documentView = view
        view.isRichText = false; view.allowsUndo = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width: 4, height: 4)
        view.setAccessibilityLabel("Start writing")
        view.changed = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            if let window = view.window {
                coordinator.originalWindow = window
                coordinator.permitted = { [weak view, weak window] in guard let window else { return false }; return window.firstResponder == nil || window.firstResponder === window || window.firstResponder === view }
            }
            coordinator.input(view.string, marked: view.hasMarkedText())
        }
        view.pasteAction = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, let window = view.window else { return }; coordinator.originalWindow = window
            coordinator.permitted = { [weak view, weak window] in guard let window else { return false }; return window.firstResponder == nil || window.firstResponder === window || window.firstResponder === view }
            coordinator.paste()
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ModernEmptyMacView else { return }; view.isEditable = editable && context.environment.isEnabled
        let size = model.document.appearance.fontSize == .small ? 15.0 : model.document.appearance.fontSize == .large ? 20.0 : 17.0
        let base = model.document.appearance.fontFamily == .monospace ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        view.font = model.document.appearance.fontFamily == .serif ? NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) : base
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: ModernEmptyCoordinator) { coordinator.close() }
}
#else
@MainActor private final class ModernEmptyUIKitView: UITextView {
    var changed: (() -> Void)?
    var pasteAction: (() -> Void)?
    private var depth = 0
    private func editing(_ work: () -> Void) { depth += 1; defer { depth -= 1; if depth == 0 { changed?() } }; work() }
    override func insertText(_ text: String) { editing { super.insertText(text) } }
    override func setMarkedText(_ text: String?, selectedRange: NSRange) { editing { super.setMarkedText(text, selectedRange: selectedRange) } }
    override func unmarkText() { editing { super.unmarkText() } }
    override func replace(_ range: UITextRange, withText text: String) { editing { super.replace(range, withText: text) } }
    override func deleteBackward() { editing { super.deleteBackward() } }
    override func paste(_ sender: Any?) { if markedTextRange != nil { super.paste(sender) } else { pasteAction?() } }
    override var undoManager: UndoManager? { nil }
}
extension ModernEmptyPlatformInput: UIViewRepresentable {
    func makeUIView(context: Context) -> ModernEmptyUIKitView {
        let view = ModernEmptyUIKitView(); view.isScrollEnabled = false; view.backgroundColor = .clear; view.accessibilityLabel = "Start writing"
        view.changed = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            if let window = view.window {
                coordinator.originalWindow = window
                coordinator.permitted = { [weak view, weak window] in guard let window else { return false }; func responder(_ root: UIView) -> UIView? { if root.isFirstResponder { return root }; for child in root.subviews { if let found = responder(child) { return found } }; return nil }
                    let current = responder(window); return current == nil || current === view }
            }
            coordinator.input(view.text, marked: view.markedTextRange != nil)
        }
        view.pasteAction = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, let window = view.window else { return }; coordinator.originalWindow = window
            coordinator.permitted = { [weak view, weak window] in
                guard let window else { return false }
                func responder(_ root: UIView) -> UIView? { if root.isFirstResponder { return root }; for child in root.subviews { if let found = responder(child) { return found } }; return nil }
                let current = responder(window); return current == nil || current === view
            }; coordinator.paste()
        }
        return view
    }
    func updateUIView(_ view: ModernEmptyUIKitView, context: Context) {
        view.isEditable = editable && context.environment.isEnabled
        let size = model.document.appearance.fontSize == .small ? 15.0 : model.document.appearance.fontSize == .large ? 20.0 : 17.0
        let base = model.document.appearance.fontFamily == .monospace ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size)
        let font = model.document.appearance.fontFamily == .serif ? UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) : base
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font); view.adjustsFontForContentSizeCategory = true
    }
    static func dismantleUIView(_ view: ModernEmptyUIKitView, coordinator: ModernEmptyCoordinator) { coordinator.close() }
}
#endif
#endif
