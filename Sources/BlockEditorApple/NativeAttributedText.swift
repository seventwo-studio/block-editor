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

@MainActor func nativeRichAttributedText(_ nodes: [JSONValue], container: JSONValue?, address: TextAddress, appearance: ModernAppearance? = nil) -> NSAttributedString {
    let heading = container?["type"]?.string == "heading", level = container?["level"]
    let result = NSMutableAttributedString(string: "")
    for node in nodes {
        var bold = heading || container?["header"] == .bool(true), italic = false, code = address.path.last == "code"
        var attributes: [NSAttributedString.Key: Any] = [:]
        var ink = container?["semanticColor"]?.string, fill = container?["semanticBackground"]?.string
        for mark in node["marks"]?.array ?? [] {
            switch mark["type"]?.string {
            case "bold": bold = true
            case "italic": italic = true
            case "code": code = true
            case "strikethrough": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "semantic-color": ink = mark["value"]?.string
            case "semantic-background": fill = mark["value"]?.string
            case "link":
                if let url = mark["href"]?.string.flatMap(URL.init(string:)), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { attributes[.link] = url }
            default: break
            }
        }
        #if os(macOS)
        var font = NSFont.preferredFont(forTextStyle: heading ? (level == .number(1) ? .title1 : level == .number(2) ? .title2 : .title3) : .body)
        if let appearance {
            let base: Double = appearance.fontSize == .small ? 15 : appearance.fontSize == .large ? 20 : 17
            let ratio: Double = address.path == ["title"] ? 2.1 : heading ? (level == .number(1) ? 1.55 : 1.2) : address.path.last == "caption" ? 0.88 : code ? 0.9 : 1
            font = .systemFont(ofSize: base * ratio)
            if let descriptor = font.fontDescriptor.withDesign(appearance.fontFamily == .serif ? .serif : appearance.fontFamily == .monospace ? .monospaced : .default), let styled = NSFont(descriptor: descriptor, size: base * ratio) { font = styled }
        }
        if code { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.foregroundColor] = NSColor.textColor
        #else
        var font = UIFont.preferredFont(forTextStyle: heading ? (level == .number(1) ? .title1 : level == .number(2) ? .title2 : .title3) : .body)
        if let appearance {
            let base: Double = appearance.fontSize == .small ? 15 : appearance.fontSize == .large ? 20 : 17
            let ratio: Double = address.path == ["title"] ? 2.1 : heading ? (level == .number(1) ? 1.55 : 1.2) : address.path.last == "caption" ? 0.88 : code ? 0.9 : 1
            let descriptor = UIFont.systemFont(ofSize: base * ratio).fontDescriptor.withDesign(appearance.fontFamily == .serif ? .serif : appearance.fontFamily == .monospace ? .monospaced : .default)
            font = UIFontMetrics(forTextStyle: .body).scaledFont(for: descriptor.map { UIFont(descriptor: $0, size: base * ratio) } ?? .systemFont(ofSize: base * ratio))
        }
        if code { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }; if italic { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
        attributes[.foregroundColor] = UIColor.label
        #endif
        if let ink, let color = nativeSemanticColor(ink, fill: false) { attributes[.foregroundColor] = color }
        if let fill, let color = nativeSemanticColor(fill, fill: true) { attributes[.backgroundColor] = color }
        attributes[.font] = font
        result.append(NSAttributedString(string: plainText([node]), attributes: attributes))
    }
    return result
}
#if os(macOS)
private typealias ModernNativeColor = NSColor
#else
private typealias ModernNativeColor = UIColor
#endif
@MainActor private func nativeSemanticColor(_ role: String, fill: Bool) -> ModernNativeColor? {
    let lightInk = ["neutral": 0x242b28, "green": 0x285e4d, "blue": 0x235a96, "purple": 0x65428b, "amber": 0x775415, "red": 0x9d2e35]
    let darkInk = ["neutral": 0xe7eee9, "green": 0x9be1bd, "blue": 0xa8cdf7, "purple": 0xd4b8ed, "amber": 0xf5d38c, "red": 0xffb3b6]
    let lightFill = ["neutral": 0xf3f6f4, "green": 0xe5f1ea, "blue": 0xedf4ff, "purple": 0xf5effc, "amber": 0xfff5db, "red": 0xfff0f0]
    let darkFill = ["neutral": 0x232d27, "green": 0x294b39, "blue": 0x273849, "purple": 0x3b2d49, "amber": 0x3e3321, "red": 0x432629]
    guard let light = (fill ? lightFill : lightInk)[role], let dark = (fill ? darkFill : darkInk)[role] else { return nil }
    func color(_ value: Int) -> ModernNativeColor { ModernNativeColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
    #if os(macOS)
    return NSColor(name: nil) { appearance in color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) }
    #else
    return UIColor { traits in color(traits.userInterfaceStyle == .dark ? dark : light) }
    #endif
}
#endif
