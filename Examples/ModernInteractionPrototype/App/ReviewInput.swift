import BlockEditorCore
import SwiftUI
#if os(macOS)
import AppKit

@MainActor struct ReviewTitle:NSViewRepresentable {
    let model:ReviewModel
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSTextField {
        let view = NSTextField(); view.isBordered = false; view.drawsBackground = false
        view.isEditable = true; view.isSelectable = true; view.placeholderString = "Untitled"
        view.cell?.usesSingleLineMode = true; view.delegate = context.coordinator
        view.setAccessibilityLabel("Document title"); view.setAccessibilityIdentifier("Document title")
        return view
    }
    func updateNSView(_ view:NSTextField,context:Context) {
        context.coordinator.parent = self
        if view.stringValue != model.title { view.stringValue = model.title }
        let size = model.bodySize*2.1
        if context.coordinator.renderedSize != size { view.font = .systemFont(ofSize:size,weight:.bold); context.coordinator.renderedSize = size }
        view.textColor = .labelColor
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSTextField,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? 300,height:model.bodySize*2.6)
    }
    @MainActor final class Coordinator:NSObject,NSTextFieldDelegate {
        var parent:ReviewTitle
        var renderedSize:Double?
        init(_ parent:ReviewTitle) { self.parent = parent }
        func controlTextDidChange(_ notification:Notification) {
            if let view = notification.object as? NSTextField { parent.model.title = view.stringValue }
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { self.parent.model.submitTitle() }
            return true
        }
    }
}

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
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = fontSize*0.3
        view.typingAttributes = [.font:field.name == "code" ? NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular) : NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
        view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(label)
        view.reviewKey = { model.handleKey($0) }
        view.reviewFormat = { model.format($0) }
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
            let requestedRange = model.activeField == field ? model.activeRange : NSRange(location:0,length:0)
            if model.activeField == field { let location = min(model.activeRange.location,attributed.length); view.setSelectedRange(NSRange(location:location,length:min(model.activeRange.length,attributed.length-location))) }
            DispatchQueue.main.async { [weak view] in
                guard model.requestedFocus == field.key, let view, let window = view.window else { return }
                window.makeFirstResponder(view)
                let location = min(requestedRange.location,view.string.utf16.count)
                view.setSelectedRange(NSRange(location:location,length:min(requestedRange.length,view.string.utf16.count-location)))
                model.requestedFocus = nil
            }
        }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSScrollView,context:Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let text = reviewAttributed(model:model,field:field,size:fontSize)
        let bounds = text.boundingRect(with:NSSize(width:max(20,width-14),height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
        return CGSize(width:width,height:max(fontSize*1.65+8,ceil(bounds.height)+8))
    }
    @MainActor final class Coordinator: NSObject,NSTextViewDelegate {
        var parent:ReviewInput
        var refreshing = false
        init(_ parent:ReviewInput) { self.parent = parent }
        func textDidBeginEditing(_ notification:Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange(); parent.model.selected = []; parent.model.requestedFocus = nil
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
    var reviewFormat: ((String)->Void)?
    override func keyDown(with event:NSEvent) {
        if event.modifierFlags.contains(.command), [11,34].contains(event.keyCode) { reviewFormat?(event.keyCode == 11 ? "bold" : "italic"); return }
        let key:ReviewKey? = switch event.keyCode { case 125:.down; case 126:.up; case 36:.enter; case 53:.escape; default:nil }
        if let key,reviewKey?(key) == true { return }
        super.keyDown(with:event)
    }
}
@MainActor private func reviewAttributed(model:ReviewModel,field:ReviewField,size:Double) -> NSAttributedString {
    let result = NSMutableAttributedString(string:"")
    let font = field.name == "code" ? NSFont.monospacedSystemFont(ofSize:size,weight:.regular) : NSFont.systemFont(ofSize:size)
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size*0.3
    let base: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
    if let runs = model.value(field)?.array {
        for run in runs {
            var attributes = base
            var traits:NSFontTraitMask = []
            for mark in run["marks"]?.array ?? [] {
                switch mark["type"]?.string {
                case "bold": traits.insert(.boldFontMask)
                case "italic": traits.insert(.italicFontMask)
                case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "code": attributes[.font] = NSFont.monospacedSystemFont(ofSize:size,weight:.regular)
                case "link": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                default:break
                }
            }
            if !traits.isEmpty, let baseFont = attributes[.font] as? NSFont { attributes[.font] = NSFontManager.shared.convert(baseFont,toHaveTrait:traits) }
            result.append(NSAttributedString(string:plainText([run]),attributes:attributes))
        }
    } else { result.append(NSAttributedString(string:model.text(field),attributes:base)) }
    return result
}
#else
import UIKit

@MainActor struct ReviewTitle:UIViewRepresentable {
    let model:ReviewModel
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> UITextField {
        let view = UITextField(); view.placeholder = "Untitled"; view.borderStyle = .none
        view.delegate = context.coordinator
        view.accessibilityLabel = "Document title"; view.accessibilityIdentifier = "Document title"
        view.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.editingChanged)
        view.returnKeyType = .next
        return view
    }
    func updateUIView(_ view:UITextField,context:Context) {
        context.coordinator.parent = self
        if view.text != model.title { view.text = model.title }
        let size = model.bodySize*2.1
        if context.coordinator.renderedSize != size { view.font = .systemFont(ofSize:size,weight:.bold); context.coordinator.renderedSize = size }
        view.textColor = .label
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextField,context:Context) -> CGSize? {
        CGSize(width:proposal.width ?? 300,height:model.bodySize*2.6)
    }
    @MainActor final class Coordinator:NSObject,UITextFieldDelegate {
        var parent:ReviewTitle
        var renderedSize:Double?
        init(_ parent:ReviewTitle) { self.parent = parent }
        @objc func changed(_ view:UITextField) { parent.model.title = view.text ?? "" }
        func textFieldShouldReturn(_ view:UITextField) -> Bool {
            view.resignFirstResponder()
            DispatchQueue.main.async { self.parent.model.submitTitle() }
            return false
        }
    }
}

@MainActor struct ReviewInput: UIViewRepresentable {
    let model:ReviewModel
    let field:ReviewField
    let label:String
    let fontSize:Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> ReviewTextView {
        let view = ReviewTextView()
        view.backgroundColor = .clear; view.isScrollEnabled = false
        view.smartInsertDeleteType = .no
        if field.name == "code" { view.autocorrectionType = .no; view.autocapitalizationType = .none; view.smartQuotesType = .no; view.smartDashesType = .no }
        view.textContainerInset = UIEdgeInsets(top:4,left:0,bottom:4,right:0)
        view.textContainer.lineFragmentPadding = 2
        view.delegate = context.coordinator
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = fontSize*0.3
        view.font = field.name == "code" ? .monospacedSystemFont(ofSize:fontSize,weight:.regular) : .systemFont(ofSize:fontSize)
        view.textColor = .label
        view.typingAttributes = [.font:view.font!,.foregroundColor:UIColor.label,.paragraphStyle:paragraph]
        view.accessibilityLabel = label; view.accessibilityIdentifier = label
        view.reviewKey = { model.handleKey($0) }
        view.reviewFormat = { model.format($0) }
        view.reviewPickerOpen = { model.pickerOpen }
        view.didEdit = { [weak view, weak coordinator = context.coordinator] in if let view { coordinator?.textViewDidChange(view) } }
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    static func dismantleUIView(_ view:ReviewTextView,coordinator:Coordinator) { view.delegate = nil; view.didEdit = nil; view.reviewKey = nil; view.reviewFormat = nil; view.reviewPickerOpen = nil }
    func updateUIView(_ view:ReviewTextView,context:Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        let attributed = reviewAttributed(model:model,field:field,size:fontSize)
        let range = view.selectedRange
        if !reviewProjectionMatches(view.attributedText,attributed) {
            context.coordinator.refreshing = true
            view.attributedText = attributed
            let location = min(range.location,attributed.length)
            view.selectedRange = NSRange(location:location,length:min(range.length,attributed.length-location))
            context.coordinator.refreshing = false
        }
        if model.requestedFocus == field.key {
            let requestedRange = model.activeField == field ? model.activeRange : NSRange(location:0,length:0)
            if model.activeField == field { let location = min(model.activeRange.location,attributed.length); view.selectedRange = NSRange(location:location,length:min(model.activeRange.length,attributed.length-location)) }
            DispatchQueue.main.async { [weak view] in
                guard model.requestedFocus == field.key, let view, view.window != nil else { return }
                view.becomeFirstResponder()
                let location = min(requestedRange.location,view.text.utf16.count)
                view.selectedRange = NSRange(location:location,length:min(requestedRange.length,view.text.utf16.count-location))
                model.requestedFocus = nil
            }
        }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:ReviewTextView,context:Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude))
        return CGSize(width:width,height:max(fontSize*1.65+8,ceil(size.height)))
    }
    @MainActor final class Coordinator:NSObject,UITextViewDelegate {
        var parent:ReviewInput
        var refreshing = false
        init(_ parent:ReviewInput) { self.parent = parent }
        func textViewDidBeginEditing(_ view:UITextView) { parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange; parent.model.selected = []; parent.model.requestedFocus = nil }
        func textViewDidChange(_ view:UITextView) { guard !refreshing,view.markedTextRange == nil, (view as? ReviewTextView)?.nativeEditing != true else { return }; parent.model.update(parent.field,text:view.text,range:view.selectedRange) }
        func textView(_ view:UITextView,shouldChangeTextIn range:NSRange,replacementText text:String) -> Bool {
            if text == "\n", parent.model.pickerOpen { return !parent.model.handleKey(.enter) }
            return true
        }
        func textViewDidChangeSelection(_ view:UITextView) { guard !refreshing,view.isFirstResponder, (view as? ReviewTextView)?.nativeEditing != true else { return }; parent.model.activeField = parent.field; parent.model.activeRange = view.selectedRange }
    }
}
@MainActor final class ReviewTextView:UITextView {
    private(set) var nativeEditing = false
    var didEdit:(()->Void)?
    override func insertText(_ text:String) { nativeEditing = true; super.insertText(text); nativeEditing = false; didEdit?() }
    override func deleteBackward() { nativeEditing = true; super.deleteBackward(); nativeEditing = false; didEdit?() }
    override func setMarkedText(_ text:String?,selectedRange:NSRange) { nativeEditing = true; super.setMarkedText(text,selectedRange:selectedRange); nativeEditing = false; didEdit?() }
    override func unmarkText() { nativeEditing = true; super.unmarkText(); nativeEditing = false; didEdit?() }
    var reviewKey:((ReviewKey)->Bool)?
    var reviewFormat:((String)->Void)?
    var reviewPickerOpen:(()->Bool)?
    override var keyCommands:[UIKeyCommand]? {
        var commands = [UIKeyCommand(input:"b",modifierFlags:.command,action:#selector(bold)),UIKeyCommand(input:"i",modifierFlags:.command,action:#selector(italic))]
        if reviewPickerOpen?() == true {
            commands += [UIKeyCommand(input:UIKeyCommand.inputDownArrow,modifierFlags:[],action:#selector(down)),UIKeyCommand(input:UIKeyCommand.inputUpArrow,modifierFlags:[],action:#selector(up)),UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(escape)),UIKeyCommand(input:"\r",modifierFlags:[],action:#selector(enter))]
        }
        return commands + (super.keyCommands ?? [])
    }
    @objc private func bold() { reviewFormat?("bold") }
    @objc private func italic() { reviewFormat?("italic") }
    @objc private func down() { _ = reviewKey?(.down) }
    @objc private func up() { _ = reviewKey?(.up) }
    @objc private func escape() { _ = reviewKey?(.escape) }
    @objc private func enter() { _ = reviewKey?(.enter) }
}
@MainActor private func reviewAttributed(model:ReviewModel,field:ReviewField,size:Double) -> NSAttributedString {
    let result = NSMutableAttributedString(string:"")
    let font = field.name == "code" ? UIFont.monospacedSystemFont(ofSize:size,weight:.regular) : UIFont.systemFont(ofSize:size)
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = size*0.3
    let base:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:UIColor.label,.paragraphStyle:paragraph]
    if let runs = model.value(field)?.array {
        for run in runs {
            var attributes = base
            var traits:UIFontDescriptor.SymbolicTraits = []
            for mark in run["marks"]?.array ?? [] {
                switch mark["type"]?.string {
                case "bold": traits.insert(.traitBold)
                case "italic": traits.insert(.traitItalic)
                case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "code": attributes[.font] = UIFont.monospacedSystemFont(ofSize:size,weight:.regular)
                case "link": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue; attributes[.foregroundColor] = UIColor.link
                default:break
                }
            }
            if !traits.isEmpty, let baseFont = attributes[.font] as? UIFont, let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) { attributes[.font] = UIFont(descriptor:descriptor,size:size) }
            result.append(NSAttributedString(string:plainText([run]),attributes:attributes))
        }
    } else { result.append(NSAttributedString(string:model.text(field),attributes:base)) }
    return result
}
/// UIKit adds typing attributes that are not document styling. Avoid replacing
/// live text storage merely because those private attributes differ.
@MainActor private func reviewProjectionMatches(_ actual:NSAttributedString?,_ expected:NSAttributedString) -> Bool {
    guard let actual, actual.string == expected.string else { return false }
    for offset in 0..<expected.length {
        let a = actual.attributes(at:offset,effectiveRange:nil), b = expected.attributes(at:offset,effectiveRange:nil)
        let af = a[.font] as? UIFont, bf = b[.font] as? UIFont
        if af?.fontName != bf?.fontName || af?.pointSize != bf?.pointSize { return false }
        for key in [NSAttributedString.Key.strikethroughStyle,.underlineStyle] {
            if (a[key] as? Int ?? 0) != (b[key] as? Int ?? 0) { return false }
        }
        if (a[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing != (b[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing { return false }
    }
    return true
}
#endif
