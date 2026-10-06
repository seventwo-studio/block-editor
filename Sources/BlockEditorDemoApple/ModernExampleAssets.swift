#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
import Observation
import ImageIO

/// Application-owned local asset example. The editor only stores inert asset
/// references; this host bounds, persists and resolves the original file bytes.
@MainActor @Observable final class ModernExampleAssets {
    struct Request: Identifiable { let id = UUID(); let kind: String }
    var request: Request?
    let directory: URL
    @ObservationIgnored private var continuation: CheckedContinuation<[String: JSONValue], any Error>?
    init(directory: URL) { self.directory = directory }
    func choose(kind: String) async throws -> [String: JSONValue] {
        guard request == nil else { throw ModernSessionError.unavailable("assetPickerBusy") }
        return try await withCheckedThrowingContinuation { continuation = $0; request = Request(kind: kind) }
    }
    func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil; request = nil }
    func finish(_ metadata: [String: JSONValue]) { continuation?.resume(returning: metadata); continuation = nil; request = nil }
    func importFile(_ url: URL) {
        do {
            guard let request else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let resource = try url.resourceValues(forKeys: [.fileSizeKey]); guard let size = resource.fileSize, size <= 16_000_000 else { throw EditorError.recoveryCapacityExceeded }
            let data = try Data(contentsOf: url); guard data.count <= 16_000_000 else { throw EditorError.recoveryCapacityExceeded }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString, saved = directory.appendingPathComponent(id)
            try data.write(to: saved, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
            guard try Data(contentsOf: saved) == data else { throw ModernSessionError.unavailable("assetReadbackMismatch") }
            var metadata: [String: JSONValue] = ["src": .string("asset://" + id)]
            if request.kind == "image" {
                guard let image = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw EditorError.invalidChange }
                metadata["width"] = .number(width.doubleValue); metadata["height"] = .number(height.doubleValue); metadata["alt"] = .string(url.lastPathComponent)
            } else { metadata["name"] = .string(url.lastPathComponent); metadata["size"] = .number(Double(data.count)) }
            finish(metadata)
        } catch { continuation?.resume(throwing: error); continuation = nil; request = nil }
    }
    func resolve(_ value: JSONValue) -> URL? {
        guard let source = value["src"]?.string, source.hasPrefix("asset://"), let id = UUID(uuidString: String(source.dropFirst(8))) else { return nil }
        let file = directory.appendingPathComponent(id.uuidString)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
#endif
