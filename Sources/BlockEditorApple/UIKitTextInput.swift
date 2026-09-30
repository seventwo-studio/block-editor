#if os(iOS) || os(visionOS)
import BlockEditorCore
import SwiftUI
import UIKit

@MainActor struct UIKitTextInput: UIViewRepresentable {
    let model: EditorModel
    let address: TextAddress
    var label = "Block text"
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(model: model, address: address, selection: $selection) }
    func makeUIView(context: Context) -> ComposingUIKitTextView {
        let view = ComposingUIKitTextView()
        view.isEditable = true; view.isSelectable = true
        view.allowsEditingTextAttributes = false
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.accessibilityLabel = label
        context.coordinator.connect(view)
        return view
    }
    func updateUIView(_ view: ComposingUIKitTextView, context: Context) { context.coordinator.render() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposingUIKitTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }
    static func dismantleUIView(_ view: ComposingUIKitTextView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let input: CollaborativeInput
        private weak var view: ComposingUIKitTextView?
        private var selection: Binding<NSRange>
        private var rendering = false
        init(model: EditorModel, address: TextAddress, selection: Binding<NSRange>) {
            input = CollaborativeInput(model: model, address: address); self.selection = selection
        }
        func connect(_ view: ComposingUIKitTextView) {
            self.view = view; view.delegate = self
            view.beginComposition = { [weak self] in self?.input.beginComposition() }
            view.didEdit = { [weak self] in self?.changed() }
            view.history = { [weak self] redo in self?.input.model.perform { if redo { try $0.redo() } else { try $0.undo() } } }
            input.onPrepare = { [weak self] in
                guard let self, let view = self.view else { return }
                self.input.selection = view.selectedRange
            }
            input.onUpdate = { [weak self] in
                guard let self else { return }
                self.render()
                self.selection.wrappedValue = self.input.selection
            }
            render()
        }
        func textViewDidChange(_ textView: UITextView) { changed() }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !rendering else { return }
            input.selection = textView.selectedRange; selection.wrappedValue = input.selection
        }
        private func changed() {
            guard !rendering, let view else { return }
            input.update(text: view.text, selection: view.selectedRange, composing: view.markedTextRange != nil)
            view.invalidateIntrinsicContentSize()
        }
        func render() {
            guard let view, view.markedTextRange == nil, !input.composing else { return }
            rendering = true; defer { rendering = false }
            let text = nativeAttributedText(input)
            if !view.attributedText.isEqual(to: text) { view.attributedText = text }
            view.selectedRange = input.selection
            view.invalidateIntrinsicContentSize()
        }
        func close() {
            view?.delegate = nil; view?.beginComposition = nil; view?.didEdit = nil; view?.history = nil
            input.close(); view = nil
        }
    }
}

@MainActor final class ComposingUIKitTextView: UITextView {
    var beginComposition: (() -> Void)?
    var didEdit: (() -> Void)?
    var history: ((Bool) -> Void)?
    override var undoManager: UndoManager? { nil }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        beginComposition?()
        super.setMarkedText(markedText, selectedRange: selectedRange)
        didEdit?()
    }
    override func unmarkText() { super.unmarkText(); didEdit?() }
    override func insertText(_ text: String) { super.insertText(text); didEdit?() }
    override func deleteBackward() { super.deleteBackward(); didEdit?() }
    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { insertText(text) }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoLocal)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoLocal))]
    }
    @objc private func undoLocal() { if markedTextRange == nil { history?(false) } }
    @objc private func redoLocal() { if markedTextRange == nil { history?(true) } }
}
#endif
