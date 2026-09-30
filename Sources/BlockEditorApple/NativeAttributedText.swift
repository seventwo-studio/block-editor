#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor func nativeAttributedText(_ input: CollaborativeInput) -> NSAttributedString {
    let block = input.model.document.blocks.first { $0.id == input.address.blockID }
    let value = block.flatMap { JSONValue.object($0.fields).value(at: input.address.path) }
    let container = block.flatMap { JSONValue.object($0.fields).value(at: Array(input.address.path.dropLast())) }
    let heading = container?["type"]?.string == "heading"
    let level = container?["level"]
    let nodes = value?.array ?? [.object(["type": .string("text"), "text": .string(input.text)])]
    let result = NSMutableAttributedString(string: "")
    for node in nodes {
        var bold = heading || container?["header"] == .bool(true), italic = false, code = input.address.path.last == "code"
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
