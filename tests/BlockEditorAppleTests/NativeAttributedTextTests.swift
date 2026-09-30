#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
import Testing
@testable import BlockEditorApple
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Test func nativeFormattingCombinesCodeBoldAndItalic() throws {
    let marks: [JSONValue] = ["bold", "italic", "code"].map { .object(["type": .string($0)]) }
    let block = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array([
        .object(["type": .string("text"), "text": .string("Hello"), "marks": .array(marks)])
    ])])
    let session = try EditorSession(documentID: "native-marks", actorID: "a", document: Document(blocks: [block]))
    let input = CollaborativeInput(model: try EditorModel(session: session), address: TextAddress("p"))
    defer { input.close() }
    let attributed = nativeAttributedText(input)
    #expect(attributed.string == "Hello")
    #if os(macOS)
    let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let traits = NSFontManager.shared.traits(of: font)
    #expect(traits.contains(.boldFontMask))
    #expect(traits.contains(.italicFontMask))
    #else
    let font = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    #expect(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    #endif
}
#endif
