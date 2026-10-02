#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor func nativeAttributedText(_ input: CollaborativeInput) -> NSAttributedString {
    var address = input.address
    if let identity = address.identity {
        guard let live = try? input.model.session.address(of: identity), let field = address.path.last else {
            return NSAttributedString(string: "")
        }
        address = TextAddress(live.blockID, path: live.path + [field], identity: identity)
    }
    let block = input.model.document.blocks.first { $0.id == address.blockID }
    let value = block.flatMap { JSONValue.object($0.fields).value(at: address.path) }
    let container = block.flatMap { JSONValue.object($0.fields).value(at: Array(address.path.dropLast())) }
    let nodes = value?.array ?? [.object(["type": .string("text"), "text": .string(input.text)])]
    return nativeRichAttributedText(nodes, container: container, address: address)
}

@MainActor func nativeWritingAttributedText(_ input: WritingCollaborativeInput) -> NSAttributedString {
    let value = try? input.model.field(input.effectiveAddress)
    let identity = try? input.model.session.position(at: input.effectiveAddress, offset: 0).field.node
    let container = identity.flatMap { try? input.model.nodeValue($0) }
    return nativeRichAttributedText(value?.array ?? [.object(["type": .string("text"), "text": .string(input.text)])], container: container, address: input.effectiveAddress)
}

@MainActor private func nativeRichAttributedText(_ nodes: [JSONValue], container: JSONValue?, address: TextAddress) -> NSAttributedString {
    let heading = container?["type"]?.string == "heading", level = container?["level"]
    let result = NSMutableAttributedString(string: "")
    for node in nodes {
        var bold = heading || container?["header"] == .bool(true), italic = false, code = address.path.last == "code"
        var attributes: [NSAttributedString.Key: Any] = [:]
        for mark in node["marks"]?.array ?? [] {
            switch mark["type"]?.string {
            case "bold": bold = true
            case "italic": italic = true
            case "code": code = true
            case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "link":
                if let url = mark["href"]?.string.flatMap(URL.init(string:)), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
            default: break
            }
        }
        #if os(macOS)
        var font = NSFont.preferredFont(forTextStyle: heading ? (level == .number(1) ? .title1 : level == .number(2) ? .title2 : .title3) : .body)
        if code { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.foregroundColor] = NSColor.textColor
        #else
        var font = UIFont.preferredFont(forTextStyle: heading ? (level == .number(1) ? .title1 : level == .number(2) ? .title2 : .title3) : .body)
        if code { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }; if italic { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
        attributes[.foregroundColor] = UIColor.label
        #endif
        attributes[.font] = font
        result.append(NSAttributedString(string: plainText([node]), attributes: attributes))
    }
    return result
}
#endif
