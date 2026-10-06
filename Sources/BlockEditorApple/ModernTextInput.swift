#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import SwiftUI
#if os(macOS)
import AppKit
private typealias ModernPlatformView = ModernMacTextView
#else
import UIKit
private typealias ModernPlatformView = ModernUIKitTextView
#endif

/// Origin-bound protocol-7 input for a title, inline body or literal field.
/// The canvas supplies structural Return behavior through its host command.
@MainActor public struct ModernTextInput: View {
    private let model: ModernEditorModel
    private let field: WritingField
    private let label: String
    private let submit: (() -> Bool)?
    private let boundary: ((String) -> Bool)?
    private let clipboardAccess: any ModernClipboardAccess
    public init(model: ModernEditorModel, field: WritingField, label: String = "Block text", onSubmit: (() -> Bool)? = nil, onBoundary: ((String) -> Bool)? = nil, clipboard: any ModernClipboardAccess = ModernNativeClipboard()) {
        self.model = model; self.field = field; self.label = label; submit = onSubmit; boundary = onBoundary; clipboardAccess = clipboard
    }
    public var body: some View {
        // An explicit changing value invalidates the representable even while
        // its observable model reference and opaque field remain stable.
        ModernPlatformInput(model: model, field: field, label: label, submit: submit, boundary: boundary, clipboard: clipboardAccess,
            projectedText: (try? model.session.text(in: field)) ?? "", document: model.document,
            editable: model.isEditable && model.isActive, intent: model.focusIntent).id(field)
    }
}

@MainActor private struct ModernPlatformInput {
    let model: ModernEditorModel
    let field: WritingField
    let label: String
    let submit: (() -> Bool)?
    let boundary: ((String) -> Bool)?
    let clipboard: any ModernClipboardAccess
    let projectedText: String
    let document: ModernDocument
    let editable: Bool
    let intent: ModernFocusIntent?
    func makeCoordinator() -> ModernNativeCoordinator { ModernNativeCoordinator(model: model, field: field, submit: submit, boundary: boundary, clipboard: clipboard) }
}

#if os(macOS)
extension ModernPlatformInput: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), view = ModernMacTextView()
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4); view.setAccessibilityLabel(label)
        scroll.documentView = view; context.coordinator.connect(view); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.view?.isEditable = editable && context.environment.isEnabled && context.coordinator.input != nil
        context.coordinator.render()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite, let view = context.coordinator.view else { return nil }
        let storage = NSTextStorage(attributedString: view.attributedString()), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - 8), height: .greatestFiniteMagnitude))
        layout.addTextContainer(container); storage.addLayoutManager(layout); layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(max(24, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 8))
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ModernNativeCoordinator) { coordinator.close() }
}
#else
extension ModernPlatformInput: UIViewRepresentable {
    func makeUIView(context: Context) -> ModernUIKitTextView {
        let view = ModernUIKitTextView(); view.backgroundColor = .clear; view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true; view.allowsEditingTextAttributes = false
        view.accessibilityLabel = label; context.coordinator.connect(view); return view
    }
    func updateUIView(_ view: ModernUIKitTextView, context: Context) { view.isEditable = editable && context.environment.isEnabled && context.coordinator.input != nil; context.coordinator.render() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ModernUIKitTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    static func dismantleUIView(_ view: ModernUIKitTextView, coordinator: ModernNativeCoordinator) { coordinator.close() }
}
#endif

@MainActor private final class ModernNativeCoordinator: NSObject {
    let model: ModernEditorModel
    let input: ModernInputController?
    weak var view: ModernPlatformView?
    private var rendering = false
    private let submit: (() -> Bool)?
    private let boundary: ((String) -> Bool)?
    private let clipboard: any ModernClipboardAccess
    init(model: ModernEditorModel, field: WritingField, submit: (() -> Bool)?, boundary: ((String) -> Bool)?, clipboard: any ModernClipboardAccess) {
        self.model = model; input = try? ModernInputController(model: model, field: field); self.submit = submit
        self.clipboard = clipboard
        self.boundary = boundary
    }
    func connect(_ view: ModernPlatformView) {
        self.view = view; view.delegate = self; view.isEditable = input != nil && model.isEditable
        view.beforeEdit = { [weak self] marked in guard let self, !self.rendering else { return }; do { try self.input?.beginNativeOperation(marked: marked) } catch { self.model.report(error) } }
        view.afterEdit = { [weak self] in self?.changed() }
        view.didMove = { [weak self] in self?.attached() }
        view.didFocus = { [weak self] in guard let self, !self.model.restoringFocus else { return }; do { try self.input?.activate(selection: self.selectedRange) } catch { self.model.report(error) } }
        view.didBlur = { [weak self] in guard let self, !self.model.restoringFocus else { return }; self.model.blur() }
        view.submit = submit
        view.boundary = boundary
        view.clipboardAction = { [weak self] action in self?.clipboardAction(action) }
        view.history = { [weak self] redo in
            guard let self else { return }; do { if redo { try self.model.redo() } else { try self.model.undo() } } catch { self.model.report(error) }
        }
        input?.onProjection = { [weak self] in self?.render() }
        input?.applyNativeFocus = { [weak self] range in
            guard let self, let view = self.view, view.window != nil else { return false }
            #if os(macOS)
            let success = view.window?.makeFirstResponder(view) == true
            if success { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
            #else
            let success = view.becomeFirstResponder()
            if success { view.selectedRange = range; view.scrollRangeToVisible(range) }
            #endif
            return success
        }
        input?.settleNativeInput = { [weak self] in
            guard let self, let view = self.view, !view.nativeEditing else { throw ModernSessionError.compositionActive }
            let range = self.selectedRange
            #if os(macOS)
            let marked = view.hasMarkedText()
            #else
            let marked = view.markedTextRange != nil
            #endif
            if marked { self.rendering = true; view.unmarkText(); self.rendering = false }
            try self.input?.update(text: self.nativeText, selection: range, marked: false)
        }
        attached(); render()
    }
    private func clipboardAction(_ action: String) {
        guard let input else { return }
        do {
            try model.captureClipboardSelection(input)
            let selection = input.selection
            let range = try model.session.captureTextRange(in: input.field, start: selection.location, end: NSMaxRange(selection))
            switch action {
            case "copy":
                guard selection.length > 0 else { return }
                _ = try model.clipboard.copy(ModernDeleteTarget(ranges: [range]), to: clipboard, source: input)
            case "cut":
                guard selection.length > 0 else { return }
                _ = try model.clipboard.cut(ModernDeleteTarget(ranges: [range]), to: clipboard, source: input)
            case "paste", "pastePlain":
                guard let payload = try clipboard.read() else { return }
                _ = try model.clipboard.paste(payload, at: ModernPasteTarget(range: range), mode: action == "pastePlain" ? .plainText : .rich, source: input)
            default: break
            }
        } catch { model.report(error) }
    }
    private var nativeText: String {
        #if os(macOS)
        view?.string ?? ""
        #else
        view?.text ?? ""
        #endif
    }
    private var selectedRange: NSRange {
        #if os(macOS)
        view?.selectedRange() ?? NSRange(location: 0, length: 0)
        #else
        view?.selectedRange ?? NSRange(location: 0, length: 0)
        #endif
    }
    private func attached() {
        input?.window = view?.window
        guard let view, let window = view.window else { return }
        input?.permitsFocusTransfer = { [weak view, weak window] in
            guard let window else { return false }
            #if os(macOS)
            return window.firstResponder == nil || window.firstResponder === window || window.firstResponder === view
            #else
            func responder(_ root: UIView) -> UIView? {
                if root.isFirstResponder { return root }
                for child in root.subviews { if let value = responder(child) { return value } }; return nil
            }
            let current = responder(window); return current == nil || current === view
            #endif
        }
        model.scheduleFocus()
    }
    private func changed() {
        guard !rendering, let view, !view.nativeEditing else { return }
        #if os(macOS)
        let marked = view.hasMarkedText()
        #else
        let marked = view.markedTextRange != nil
        #endif
        do {
            try input?.update(text: nativeText, selection: selectedRange, marked: marked)
            if !marked, let input, input.pendingInput == nil, model.session.availability(for: "typingShortcut").available {
                let before = model.session.syncState
                let range = try model.session.captureTextRange(in: input.field, start: input.selection.location, end: NSMaxRange(input.selection))
                let result = try model.session.typingShortcut(in: range)
                if before != model.session.syncState { model.clipboardApplied(result, source: input) }
            }
        }
        catch { model.report(error) }
    }
    func render() {
        guard !rendering, let view, let input, !input.composing, !input.nativeEditing, input.pendingInput == nil else { return }
        #if os(macOS)
        guard !view.hasMarkedText() else { return }
        #else
        guard view.markedTextRange == nil else { return }
        #endif
        rendering = true; defer { rendering = false }
        let value = attributedText(input)
        let sample = attributedText(input, placeholder: true)
        view.typingAttributes = value.length > 0 ? value.attributes(at: max(0, min(value.length - 1, selectedRange.location - 1)), effectiveRange: nil) : sample.attributes(at: 0, effectiveRange: nil)
        #if os(macOS)
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
        view.setSelectedRange(input.selection); view.enclosingScrollView?.invalidateIntrinsicContentSize()
        #else
        if !view.attributedText.isEqual(to: value) { view.attributedText = value }
        view.selectedRange = input.selection; view.invalidateIntrinsicContentSize()
        #endif
    }
    private func attributedText(_ input: ModernInputController, placeholder: Bool = false) -> NSAttributedString {
        if case .document = input.field.node {
            return nativeRichAttributedText([.object(["type": .string("text"), "text": .string(placeholder ? " " : input.text)])],
                container: .object(["type": .string("heading"), "level": .number(1)]), address: TextAddress(model.session.documentID, path: ["title"]), appearance: model.document.appearance)
        }
        guard let position = try? model.session.position(in: input.field, offset: 0), let address = try? model.session.resolve(position).address,
              let block = model.document.blocks.first(where: { $0.id == address.blockID }) else { return NSAttributedString(string: input.text) }
        let root = JSONValue.object(block.fields), value = root.value(at: address.path)
        return nativeRichAttributedText(placeholder ? [.object(["type": .string("text"), "text": .string(" ")])] : value?.array ?? [.object(["type": .string("text"), "text": .string(placeholder ? " " : input.text)])], container: root.value(at: Array(address.path.dropLast())), address: address, appearance: model.document.appearance)
    }
    func close() {
        do { try input?.settle(); try input?.close() } catch { model.report(error) }
        // A failed detached buffer remains owned by the model for checkpoint
        // recovery; it cannot keep callbacks to a dismantled native control.
        input?.onProjection = nil; input?.settleNativeInput = nil; input?.applyNativeFocus = nil
        view?.delegate = nil; view?.beforeEdit = nil; view?.afterEdit = nil; view?.didMove = nil
        view?.didFocus = nil; view?.didBlur = nil; view?.submit = nil; view?.boundary = nil; view?.history = nil; view?.clipboardAction = nil; view = nil
    }
}

#if os(macOS)
extension ModernNativeCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { changed() }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !rendering, !model.restoringFocus, let view, !view.nativeEditing, view.window?.firstResponder === view else { return }
        do { try input?.selectionChanged(selectedRange) } catch { model.report(error) }
    }
}
@MainActor private final class ModernMacTextView: NSTextView {
    var beforeEdit: ((Bool) -> Void)?, afterEdit: (() -> Void)?, didMove: (() -> Void)?
    var didFocus: (() -> Void)?, didBlur: (() -> Void)?, submit: (() -> Bool)?
    var boundary: ((String) -> Bool)?
    var history: ((Bool) -> Void)?
    var clipboardAction: ((String) -> Void)?
    private var depth = 0, detaching = false
    var nativeEditing: Bool { depth > 0 }
    override func viewWillMove(toWindow window: NSWindow?) { detaching = window == nil; super.viewWillMove(toWindow: window) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); didMove?() }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { didFocus?() }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result, !detaching { didBlur?() }; return result }
    private func edit(marked: Bool = false, _ operation: () -> Void) {
        guard isEditable else { return }; depth += 1
        if depth == 1 { beforeEdit?(marked) }
        defer { depth -= 1; if depth == 0 { afterEdit?() } }; operation()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) { edit { super.insertText(string, replacementRange: replacementRange) } }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { edit(marked: true) { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) } }
    override func unmarkText() { edit { super.unmarkText() } }
    override func doCommand(by selector: Selector) {
        if !hasMarkedText(), boundary?(NSStringFromSelector(selector)) == true { return }
        if NSStringFromSelector(selector) == "insertNewline:", submit?() == true { return }
        edit { super.doCommand(by: selector) }
    }
    override var undoManager: UndoManager? { nil }
    override func copy(_ sender: Any?) { clipboardAction?("copy") }
    override func cut(_ sender: Any?) { clipboardAction?("cut") }
    override func paste(_ sender: Any?) { clipboardAction?("paste") }
    override func pasteAsPlainText(_ sender: Any?) { clipboardAction?("pastePlain") }
    override func pasteAsRichText(_ sender: Any?) { clipboardAction?("paste") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEditable, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { history?(event.modifierFlags.contains(.shift)); return true }
        return super.performKeyEquivalent(with: event)
    }
}
#else
extension ModernNativeCoordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !rendering, !model.restoringFocus, let view, !view.nativeEditing, view.isFirstResponder else { return }
        do { try input?.selectionChanged(selectedRange) } catch { model.report(error) }
    }
}
@MainActor private final class ModernUIKitTextView: UITextView {
    var beforeEdit: ((Bool) -> Void)?, afterEdit: (() -> Void)?, didMove: (() -> Void)?
    var didFocus: (() -> Void)?, didBlur: (() -> Void)?, submit: (() -> Bool)?
    var boundary: ((String) -> Bool)?
    var history: ((Bool) -> Void)?
    var clipboardAction: ((String) -> Void)?
    private var depth = 0, detaching = false
    var nativeEditing: Bool { depth > 0 }
    override func willMove(toWindow window: UIWindow?) { detaching = window == nil; super.willMove(toWindow: window) }
    override func didMoveToWindow() { super.didMoveToWindow(); didMove?() }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { didFocus?() }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result, !detaching { didBlur?() }; return result }
    private func edit(marked: Bool = false, _ operation: () -> Void) {
        guard isEditable else { return }; depth += 1
        if depth == 1 { beforeEdit?(marked) }
        defer { depth -= 1; if depth == 0 { afterEdit?() } }; operation()
    }
    override func insertText(_ text: String) { if text == "\n", submit?() == true { return }; edit { super.insertText(text) } }
    override func replace(_ range: UITextRange, withText text: String) { edit { super.replace(range, withText: text) } }
    override func deleteBackward() { if markedTextRange == nil, boundary?("deleteBackward:") == true { return }; edit { super.deleteBackward() } }
    override func setMarkedText(_ text: String?, selectedRange: NSRange) { edit(marked: true) { super.setMarkedText(text, selectedRange: selectedRange) } }
    override func unmarkText() { edit { super.unmarkText() } }
    override var undoManager: UndoManager? { nil }
    override func copy(_ sender: Any?) { clipboardAction?("copy") }
    override func cut(_ sender: Any?) { clipboardAction?("cut") }
    override func paste(_ sender: Any?) { clipboardAction?("paste") }
    override func pasteAndMatchStyle(_ sender: Any?) { clipboardAction?("pastePlain") }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoShared)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoShared))]
    }
    @objc private func undoShared() { if isEditable { history?(false) } }
    @objc private func redoShared() { if isEditable { history?(true) } }
}
#endif
#endif
