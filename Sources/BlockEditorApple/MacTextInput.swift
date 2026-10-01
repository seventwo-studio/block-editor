#if os(macOS)
import AppKit
import BlockEditorCore
import SwiftUI

@MainActor struct MacTextInput: NSViewRepresentable {
    let model: EditorModel
    let address: TextAddress
    var label = "Block text"
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(model: model, address: address, selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = ComposingTextView()
        view.isEditable = context.environment.isEnabled
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.setAccessibilityLabel(label)
        scroll.documentView = view; scroll.hasVerticalScroller = false
        context.coordinator.connect(view)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let text = view.documentView as? NSTextView {
            text.isEditable = context.environment.isEnabled
            if !text.isEditable, text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        }
        context.coordinator.render()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let view = nsView.documentView as? NSTextView else { return nil }
        // Measure a separate layout so querying SwiftUI's proposed width cannot
        // alter the active text view's selection or marked-text composition.
        let storage = NSTextStorage(attributedString: view.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - 2 * view.textContainerInset.width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = view.textContainer?.lineFragmentPadding ?? 5
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: view.font ?? NSFont.preferredFont(forTextStyle: .body))
        let height = max(lineHeight, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: ceil(height + 2 * view.textContainerInset.height))
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let input: CollaborativeInput
        private weak var view: ComposingTextView?
        private var selection: Binding<NSRange>
        private var rendering = false
        init(model: EditorModel, address: TextAddress, selection: Binding<NSRange>) {
            input = CollaborativeInput(model: model, address: address); self.selection = selection
        }
        func connect(_ view: ComposingTextView) {
            self.view = view; view.delegate = self
            view.beginComposition = { [weak self] in self?.input.beginComposition() }
            view.didEdit = { [weak self] in self?.changed() }
            view.history = { [weak self] redo in self?.input.model.perform { if redo { try $0.redo() } else { try $0.undo() } } }
            input.onCommit = { [weak self] in
                guard let self, let view = self.view else { throw EditorError.invalidChange }
                // End native composition without recursively publishing its delegate callbacks.
                self.rendering = true
                view.unmarkText()
                self.rendering = false
                try self.input.commit(text: view.string, selection: view.selectedRange())
            }
            input.onPrepare = { [weak self] in
                guard let self, let view = self.view else { return }
                self.input.selection = view.selectedRange()
            }
            input.onUpdate = { [weak self] in
                guard let self else { return }
                self.render()
                self.selection.wrappedValue = self.input.selection
            }
            render()
        }
        func textDidChange(_ notification: Notification) { changed() }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !rendering, let view else { return }
            input.selection = view.selectedRange(); selection.wrappedValue = input.selection
        }
        private func changed() {
            guard !rendering, let view else { return }
            input.update(text: view.string, selection: view.selectedRange(), composing: view.hasMarkedText())
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func render() {
            guard let view, !view.hasMarkedText(), !input.composing else { return }
            rendering = true; defer { rendering = false }
            let text = nativeAttributedText(input)
            if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
            view.setSelectedRange(input.selection)
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
        func close() {
            view?.delegate = nil; view?.beginComposition = nil; view?.didEdit = nil; view?.history = nil
            input.close(); view = nil
        }
    }
}

@MainActor final class ComposingTextView: NSTextView {
    var beginComposition: (() -> Void)?
    var didEdit: (() -> Void)?
    var history: ((Bool) -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        beginComposition?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() { super.unmarkText(); didEdit?() }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange); didEdit?()
    }
    override func paste(_ sender: Any?) { super.pasteAsPlainText(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z", !hasMarkedText() {
            history?(event.modifierFlags.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
#endif
