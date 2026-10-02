#if os(iOS) || os(visionOS)
import BlockEditorCore
import SwiftUI
import UIKit

@MainActor struct WritingUIKitTextInput: UIViewRepresentable {
    let model: WritingEditorModel
    let address: TextAddress
    var label = "Block text"
    func makeCoordinator() -> Coordinator { Coordinator(model: model, address: address) }
    func makeUIView(context: Context) -> WritingUIKitTextView {
        let view = WritingUIKitTextView()
        view.isEditable = context.environment.isEnabled && model.isEditable; view.isSelectable = true; view.allowsEditingTextAttributes = false
        view.adjustsFontForContentSizeCategory = true; view.isScrollEnabled = false; view.backgroundColor = .clear
        view.accessibilityLabel = label; context.coordinator.connect(view); return view
    }
    func updateUIView(_ view: WritingUIKitTextView, context: Context) { view.isEditable = context.environment.isEnabled && model.isEditable; if !view.isEditable { view.resignFirstResponder() }; context.coordinator.render() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WritingUIKitTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    static func dismantleUIView(_ view: WritingUIKitTextView, coordinator: Coordinator) { coordinator.close() }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let input: WritingCollaborativeInput
        private weak var view: WritingUIKitTextView?
        private var rendering = false
        init(model: WritingEditorModel, address: TextAddress) { input = WritingCollaborativeInput(model: model, address: address) }
        func connect(_ view: WritingUIKitTextView) {
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
            input.onCommit = { [weak self] in
                guard let self, self.input.canAuthor, let view = self.view else { throw EditorError.invalidChange }
                if !self.input.composing, self.input.effectiveAddress.identity.flatMap({ try? self.input.model.session.address(of: $0) }) == nil { return }
                let selection = view.selectedRange
                self.rendering = true; view.unmarkText(); self.rendering = false
                try self.input.commit(text: view.text, selection: selection)
            }
            input.onPrepare = { [weak self] in
                guard let self, let view = self.view else { return }
                self.input.selection = view.selectedRange; self.input.model.focus.capture(view, input: self.input)
            }
            input.onUpdate = { [weak self] in guard let self else { return }; self.render(); self.input.model.focus.update(self.view, input: self.input) }
            render()
        }
        func textViewDidChange(_ textView: UITextView) { changed() }
        func textViewDidChangeSelection(_ textView: UITextView) { if !rendering, !input.model.focus.restoringFocus, !((textView as? WritingUIKitTextView)?.nativeEditing ?? false) { input.selectionChangedByUser(textView.selectedRange); input.selection = textView.selectedRange } }
        private func changed() { guard !rendering, let view, !view.nativeEditing else { return }; input.update(text: view.text, selection: view.selectedRange, composing: view.markedTextRange != nil) }
        func render() {
            guard !rendering, let view, view.markedTextRange == nil, !input.composing else { return }
            rendering = true; defer { rendering = false }
            let text = nativeWritingAttributedText(input)
            if !view.attributedText.isEqual(to: text) { view.attributedText = text }
            view.selectedRange = input.selection; view.invalidateIntrinsicContentSize()
        }
        func close() {
            input.close(); if let view { input.model.focus.unregister(view) }
            view?.delegate = nil; view?.didMove = nil; view?.didResignFocus = nil; view?.beginComposition = nil; view?.didEdit = nil
            view?.command = nil; view?.history = nil; view?.formatSelection = nil; view = nil
        }
    }
}

@MainActor final class WritingUIKitTextView: UITextView {
    private(set) var nativeEditing = false
    private(set) var authoringPermitted = true
    override var isEditable: Bool { willSet { authoringPermitted = newValue } }
    var didMove: (() -> Void)?
    var didResignFocus: (() -> Void)?
    private var detaching = false
    override func willMove(toWindow newWindow: UIWindow?) { detaching = newWindow == nil; super.willMove(toWindow: newWindow) }
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
    override var undoManager: UndoManager? { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); didMove?() }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) { guard isEditable else { return }; beginComposition?(); nativeEditing = true; super.setMarkedText(markedText, selectedRange: selectedRange); nativeEditing = false; didEdit?() }
    override func unmarkText() { nativeEditing = true; super.unmarkText(); nativeEditing = false; didEdit?() }
    override func insertText(_ text: String) { guard isEditable else { return }; if text == "\n", command?(.enter) == true { return }; nativeEditing = true; super.insertText(text); nativeEditing = false; didEdit?() }
    override func deleteBackward() { guard isEditable else { return }; if command?(.backspace) == true { return }; nativeEditing = true; super.deleteBackward(); nativeEditing = false; didEdit?() }
    override func paste(_ sender: Any?) { if isEditable, let text = UIPasteboard.general.string { nativeEditing = true; super.insertText(text); nativeEditing = false; didEdit?() } }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(softBreak)),
         UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoLocal)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoLocal)),
         UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(boldSelection)),
         UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italicSelection))]
    }
    @objc private func softBreak() { if isEditable { _ = command?(.softBreak) } }
    @objc private func boldSelection() { if isEditable, selectedRange.length > 0 { formatSelection?("bold") } }
    @objc private func italicSelection() { if isEditable, selectedRange.length > 0 { formatSelection?("italic") } }
    @objc private func undoLocal() { if isEditable { history?(false) } }
    @objc private func redoLocal() { if isEditable { history?(true) } }
}
#endif
