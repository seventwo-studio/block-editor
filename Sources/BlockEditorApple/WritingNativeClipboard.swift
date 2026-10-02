#if canImport(SwiftUI)
import BlockEditorCore
import Foundation

/// Native clipboard input is inert data. Hosts remain responsible for assets.
enum WritingNativeClipboardPayload { case structured(Data), text(String) }

enum WritingNativeClipboard {
    static let identifier = "studio.seventwo.blockeditor.writing-clipboard"
    static func encode(_ clipboard: WritingClipboard) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(clipboard)
        guard data.count <= 32_000_000 else { throw EditorError.invalidRange }
        return data
    }
    static func decode(_ payload: WritingNativeClipboardPayload, protocolVersion: Int = 6) throws -> WritingClipboard {
        switch payload {
        case .text(let text):
            // Existing v4 has shared inline paste, including literal line breaks.
            // Block import stays explicit to v5/v6; single-line text is inline.
            guard text.utf16.count <= 1_000_000 else { throw EditorError.invalidRange }
            if protocolVersion == 4 || (!text.contains("\n") && !text.contains("\r")) {
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                guard normalized.components(separatedBy: "\n").count <= 10_000 else { throw EditorError.invalidRange }
                return WritingClipboard.plainText(normalized)
            }
            return try WritingClipboard.multilineText(text)
        case .structured(let data):
            guard data.count <= 32_000_000 else { throw EditorError.invalidRange }
            // Check unknown wire nesting before recursive typed decoding. The
            // envelope allowance includes Codable's clipboard/part wrappers;
            // the shared normalizer separately enforces payload depth100.
            let object = try JSONSerialization.jsonObject(with: data)
            var pending: [(Any, Int)] = [(object, 0)]
            while let (value, depth) = pending.popLast() {
                guard depth <= 128 else { throw EditorError.invalidRange }
                if let values = value as? [String: Any] { pending += values.values.map { ($0, depth + 1) } }
                else if let values = value as? [Any] { pending += values.map { ($0, depth + 1) } }
            }
            return try JSONDecoder().decode(WritingClipboard.self, from: data)
        }
    }
}
#endif
