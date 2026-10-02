#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI

@MainActor struct WritingMacTextInput: NSViewRepresentable {
    let model: WritingEditorModel
    let address: TextAddress
    var label = "Block text"
    func makeCoordinator() -> Coordinator { Coordinator(model: model, address: address) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), view = WritingMacTextView()
        view.isEditable = context.environment.isEnabled && model.isEditable; view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4); view.setAccessibilityLabel(label)
        scroll.documentView = view; context.coordinator.connect(view); return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let text = view.documentView as? WritingMacTextView {
            text.isEditable = context.environment.isEnabled && model.isEditable
            if !text.isEditable, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        }
        context.coordinator.render()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let view = nsView.documentView as? NSTextView else { return nil }
        let storage = NSTextStorage(attributedString: view.attributedString()), layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - 8), height: .greatestFiniteMagnitude))
        layout.addTextContainer(container); storage.addLayoutManager(layout); layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(max(24, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 8))
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let input: WritingCollaborativeInput
        private weak var view: WritingMacTextView?
        private var rendering = false
        init(model: WritingEditorModel, address: TextAddress) { input = WritingCollaborativeInput(model: model, address: address) }
        func connect(_ view: WritingMacTextView) {
            self.view = view; view.delegate = self;
            input.permission = { [weak self] in self?.view?.authoringPermitted == true }; input.model.focus.register(view, input: input)
            view.didMove = { [weak self] in self?.input.model.focus.restoreAfterLayout() }
            view.didResignFocus = { [weak self] in
                guard let self, !self.input.model.focus.restoringFocus else { return }
                self.input.selectionChangedByUser()
            }
            view.beginComposition = { [weak self] in self?.input.beginComposition() }
            view.didEdit = { [weak self] in self?.changed() }
            view.command = { [weak self] key in self?.input.command(key) ?? false }
            view.history = { [weak self] redo in
                guard let self, self.input.canReceiveKey else { return }
                self.input.model.perform { if redo { try $0.redo() } else { try $0.undo() } }
            }
            view.formatSelection = { [weak self] type in self?.input.format(type) }
            view.copySharedClipboard = { [weak self] in self?.input.copyClipboard() }
            view.pasteSharedClipboard = { [weak self] payload in self?.input.pasteImported(payload) ?? false }
            input.onCommit = { [weak self] in
                guard let self, self.input.canAuthor, let view = self.view else { throw EditorError.invalidChange }
                if !self.input.composing, self.input.effectiveAddress.identity.flatMap({ try? self.input.model.session.address(of: $0) }) == nil { return }
                let selection = view.selectedRange(); self.input.selectionAffinity = view.selectionAffinity
                self.rendering = true; view.unmarkText(); self.rendering = false
                try self.input.commit(text: view.string, selection: selection)
            }
            input.onPrepare = { [weak self] in
                guard let self, let view = self.view else { return }
                self.input.selection = view.selectedRange(); self.input.selectionAffinity = view.selectionAffinity; self.input.model.focus.capture(view, input: self.input)
            }
            input.onUpdate = { [weak self] in
                guard let self else { return }
                self.render(); self.input.model.focus.update(self.view, input: self.input)
            }
            render()
        }
        func textDidChange(_ notification: Notification) { changed() }
        func textViewDidChangeSelection(_ notification: Notification) { if !rendering, !input.model.focus.restoringFocus, let view, !view.nativeEditing { input.selectionAffinity = view.selectionAffinity; input.selectionChangedByUser(view.selectedRange()); input.selection = view.selectedRange() } }
        private func changed() {
            guard !rendering, let view, !view.nativeEditing else { return }
            input.selectionAffinity = view.selectionAffinity
            input.update(text: view.string, selection: view.selectedRange(), composing: view.hasMarkedText())
        }
        func render() {
            guard !rendering, let view, !view.hasMarkedText(), !input.composing else { return }
            rendering = true; defer { rendering = false }
            let text = nativeWritingAttributedText(input)
            if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
            view.setSelectedRange(input.selection, affinity: input.selectionAffinity, stillSelecting: false); view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func close() {
            input.close()
            if let view { input.model.focus.unregister(view) }
            view?.delegate = nil; view?.didMove = nil; view?.didResignFocus = nil; view?.beginComposition = nil; view?.didEdit = nil
            view?.command = nil; view?.history = nil; view?.formatSelection = nil; view?.copySharedClipboard = nil; view?.pasteSharedClipboard = nil; view = nil
        }
    }
}

@MainActor final class WritingMacTextView: NSTextView {
    private(set) var nativeEditing = false
    private(set) var authoringPermitted = true
    override var isEditable: Bool { willSet { authoringPermitted = newValue } }
    var didMove: (() -> Void)?
    var didResignFocus: (() -> Void)?
    private var detaching = false
    override func viewWillMove(toWindow newWindow: NSWindow?) { detaching = newWindow == nil; super.viewWillMove(toWindow: newWindow) }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, !detaching { didResignFocus?() }
        return resigned
    }
    var beginComposition: (() -> Void)?
    var didEdit: (() -> Void)?
    var command: ((WritingNativeKey) -> Bool)?
    var history: ((Bool) -> Void)?
    var formatSelection: ((String) -> Void)?
    var copySharedClipboard: (() -> WritingClipboard?)?
    var pasteSharedClipboard: ((WritingNativeClipboardPayload) -> Bool)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); didMove?() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { guard isEditable else { return }; beginComposition?(); nativeEditing = true; super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); nativeEditing = false; didEdit?() }
    override func unmarkText() { nativeEditing = true; super.unmarkText(); nativeEditing = false; didEdit?() }
    override func insertText(_ string: Any, replacementRange: NSRange) { guard isEditable else { return }; nativeEditing = true; super.insertText(string, replacementRange: replacementRange); nativeEditing = false; didEdit?() }
    override func doCommand(by selector: Selector) {
        guard isEditable else { return }
        let key: WritingNativeKey?
        switch NSStringFromSelector(selector) {
        case "insertNewline:": key = .enter
        case "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": key = .softBreak
        case "deleteBackward:": key = .backspace
        default: key = nil
        }
        if let key, command?(key) == true { return }
        super.doCommand(by: selector)
    }
    override func copy(_ sender: Any?) {
        guard let clipboard = copySharedClipboard?(), let data = try? WritingNativeClipboard.encode(clipboard) else { super.copy(sender); return }
        let board = NSPasteboard.general
        board.clearContents(); board.setData(data, forType: NSPasteboard.PasteboardType(WritingNativeClipboard.identifier))
        board.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }
    override func paste(_ sender: Any?) {
        guard isEditable, let pasteSharedClipboard else { return }
        let board = NSPasteboard.general
        if let data = board.data(forType: NSPasteboard.PasteboardType(WritingNativeClipboard.identifier)) { _ = pasteSharedClipboard(.structured(data)) }
        else if let text = board.string(forType: .string) { _ = pasteSharedClipboard(.text(text)) }
    }
    /// Opt-in interpretation of the actual plain-text clipboard companion.
    /// Ordinary Paste retains structured DTO precedence and stays literal.
    @objc func pasteMarkdown(_ sender: Any?) {
        guard isEditable, let pasteSharedClipboard,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        _ = pasteSharedClipboard(.markdown(text))
    }
    func pasteMarkdownMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Paste Markdown", action: #selector(pasteMarkdown(_:)), keyEquivalent: "")
        item.target = self; item.isEnabled = isEditable && pasteSharedClipboard != nil
        return item
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // The standard menu may be reused; replace only our own action.
        for item in menu.items where item.target === self && item.action == #selector(pasteMarkdown(_:)) { menu.removeItem(item) }
        menu.addItem(pasteMarkdownMenuItem())
        return menu
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { history?(event.modifierFlags.contains(.shift)); return true }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           selectedRange().length > 0, let type = ["b": "bold", "i": "italic"][event.charactersIgnoringModifiers?.lowercased() ?? ""] { formatSelection?(type); return true }
        return super.performKeyEquivalent(with: event)
    }
}
#endif
