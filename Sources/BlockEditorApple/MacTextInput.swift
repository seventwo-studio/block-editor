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
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.setAccessibilityLabel(label)
        scroll.documentView = view; scroll.hasVerticalScroller = true
        context.coordinator.connect(view)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.render() }
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
            input.onPrepare = { [weak self] in
                guard let self, let view = self.view else { return }
                self.input.selection = view.selectedRange()
            }
            input.onUpdate = { [weak self] in self?.render() }
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
        }
        func render() {
            guard let view, !view.hasMarkedText(), !input.composing else { return }
            rendering = true; defer { rendering = false }
            let text = attributedText()
            if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
            view.setSelectedRange(input.selection)
        }
        private func attributedText() -> NSAttributedString {
            let model = input.model, address = input.address
            var value: JSONValue? = model.document.blocks.first(where: { $0.id == address.blockID }).map { .object($0.fields) }
            for part in address.path {
                if let array = value?.array { value = array.first { $0["id"]?.string == part } }
                else { value = value?[part] }
            }
            let nodes = value?.array ?? [.object(["type": .string("text"), "text": .string(input.text)])]
            let result = NSMutableAttributedString(string: "")
            for node in nodes {
                var font = NSFont.preferredFont(forTextStyle: .body)
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
                for mark in node["marks"]?.array ?? [] {
                    switch mark["type"]?.string {
                    case "bold": font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    case "italic": font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    case "code": font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    case "link":
                        if let url = mark["href"]?.string.flatMap(URL.init(string:)), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
                    default: break
                    }
                }
                attributes[.font] = font
                result.append(NSAttributedString(string: plainText([node]), attributes: attributes))
            }
            return result
        }
        func close() { view?.delegate = nil; input.close() }
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
