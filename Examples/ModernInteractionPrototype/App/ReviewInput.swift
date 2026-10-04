import BlockEditorCore
import SwiftUI
#if os(macOS)
import AppKit

@MainActor struct ReviewInput: NSViewRepresentable {
    let model: ReviewModel
    let field: ReviewField
    let label: String
    let fontSize: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let view = ReviewTextView()
        view.isEditable = true; view.isRichText = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width:2,height:4)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.delegate = context.coordinator
        view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(label)
        view.reviewKey = { model.handleKey($0) }
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ReviewTextView, !view.hasMarkedText() else { return }
        let selection = view.selectedRange()
        let attributed = reviewAttributed(model:model,field:field,size:fontSize)
        if view.attributedString() != attributed {
            context.coordinator.refreshing = true
            view.textStorage?.setAttributedString(attributed)
            let location = min(selection.location,attributed.length)
            view.setSelectedRange(NSRange(location:location,length:min(selection.length,attributed.length-location)))
            context.coordinator.refreshing = false
        }
        if model.requestedFocus == field.key {
            if model.activeField == field { let location = min(model.activeRange.location,attributed.length); view.setSelectedRange(NSRange(location:location,length:min(model.activeRange.length,attributed.length-location))) }
            DispatchQueue.main.async { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
        }
    }
    @MainActor final class Coordinator: NSObject,NSTextViewDelegate {
        var parent:ReviewInput
        var refreshing = false
        init(_ parent:ReviewInput) { self.parent = parent }
        func textDidBeginEditing(_ notification:Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange(); parent.model.requestedFocus = nil
        }
        func textDidChange(_ notification:Notification) {
            guard !refreshing, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            parent.model.update(parent.field,text:view.string,range:view.selectedRange())
        }
        func textViewDidChangeSelection(_ notification:Notification) {
            guard !refreshing, let view = notification.object as? NSTextView, view.window?.firstResponder === view else { return }
            parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange()
        }
    }
}
@MainActor final class ReviewTextView: NSTextView {
    var reviewKey: ((ReviewKey)->Bool)?
    override func keyDown(with event:NSEvent) {
        let key:ReviewKey? = switch event.keyCode { case 125:.down; case 126:.up; case 36:.enter; case 53:.escape; default:nil }
        if let key,reviewKey?(key) == true { return }
        super.keyDown(with:event)
    }
}
@MainActor private func reviewAttributed(model:ReviewModel,field:ReviewField,size:Double) -> NSAttributedString {
    let result = NSMutableAttributedString(string:"")
    let font = NSFont.systemFont(ofSize:size)
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size*0.3
    let base: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
    if let runs = model.value(field)?.array {
        for run in runs {
            var attributes = base
            for mark in run["marks"]?.array ?? [] {
                switch mark["type"]?.string {
                case "bold": attributes[.font] = NSFont.systemFont(ofSize:size,weight:.bold)
                case "italic": attributes[.font] = NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask)
                case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "code": attributes[.font] = NSFont.monospacedSystemFont(ofSize:size,weight:.regular)
                case "link": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                default:break
                }
            }
            result.append(NSAttributedString(string:plainText([run]),attributes:attributes))
        }
    } else { result.append(NSAttributedString(string:model.text(field),attributes:base)) }
    return result
}
#else
import UIKit

@MainActor struct ReviewInput: UIViewRepresentable {
    let model:ReviewModel
    let field:ReviewField
    let label:String
    let fontSize:Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> ReviewTextView {
        let view = ReviewTextView()
        view.backgroundColor = .clear; view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top:4,left:0,bottom:4,right:0)
        view.textContainer.lineFragmentPadding = 2
        view.delegate = context.coordinator
        view.accessibilityLabel = label; view.accessibilityIdentifier = label
        view.reviewKey = { model.handleKey($0) }
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    func updateUIView(_ view:ReviewTextView,context:Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        let text = model.text(field)
        if view.text != text {
            let range = view.selectedRange
            context.coordinator.refreshing = true
            view.text = text
            let location = min(range.location,text.utf16.count)
            view.selectedRange = NSRange(location:location,length:min(range.length,text.utf16.count-location))
            context.coordinator.refreshing = false
        }
        view.font = .systemFont(ofSize:fontSize); view.textColor = .label
        if model.requestedFocus == field.key {
            if model.activeField == field { let location = min(model.activeRange.location,text.utf16.count); view.selectedRange = NSRange(location:location,length:min(model.activeRange.length,text.utf16.count-location)) }
            DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
        }
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:ReviewInput
        var refreshing = false
        init(_ parent:ReviewInput) { self.parent = parent }
        func textViewDidBeginEditing(_ view:UITextView) { parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange; parent.model.requestedFocus = nil }
        func textViewDidChange(_ view:UITextView) { guard !refreshing,view.markedTextRange == nil else { return }; parent.model.update(parent.field,text:view.text,range:view.selectedRange) }
        func textViewDidChangeSelection(_ view:UITextView) { guard !refreshing,view.isFirstResponder else { return }; parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange }
    }
}
@MainActor final class ReviewTextView:UITextView {
    var reviewKey:((ReviewKey)->Bool)?
    override var keyCommands:[UIKeyCommand]? {
        [UIKeyCommand(input:UIKeyCommand.inputDownArrow,modifierFlags:[],action:#selector(down)),UIKeyCommand(input:UIKeyCommand.inputUpArrow,modifierFlags:[],action:#selector(up)),UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(escape))]
    }
    @objc private func down() { _ = reviewKey?(.down) }
    @objc private func up() { _ = reviewKey?(.up) }
    @objc private func escape() { _ = reviewKey?(.escape) }
}
#endif
