import BlockEditorCore
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Resolution is application controlled. A stored reference never grants network
/// or file access by itself; denied/offline results remain readable and retryable.
public enum ModernMediaPresentation: Sendable {
    case available(URL)
    case denied(String)
    case offline(String)
    case unavailable(String)
}
#if os(macOS) || os(iOS) || os(visionOS)
@MainActor struct ModernResolvedMediaView: View {
    let node: NodeID
    let value: JSONValue
    let resolve: ((NodeID, JSONValue) async throws -> ModernMediaPresentation)?
    let open: ((String) -> Void)?
    @State private var presentation: ModernMediaPresentation?
    @State private var retry = 0
    private var source: String { value["src"]?.string ?? value["url"]?.string ?? "" }
    private var title: String { value["alt"]?.string ?? value["name"]?.string ?? value["title"]?.string ?? source }
    var body: some View {
        VStack(alignment: .leading) {
            switch presentation {
            case .available(let url):
                if value["type"] == .string("image") {
                    if url.isFileURL {
                        #if os(macOS)
                        if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(title) }
                        else { Text("Image unavailable") }
                        #else
                        if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(title) }
                        else { Text("Image unavailable") }
                        #endif
                    } else { AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit().accessibilityLabel(title) }
                        else if phase.error != nil { Text("Image unavailable"); Button("Retry resolution") { retry += 1 } }
                        else { ProgressView("Loading image") }
                    } }
                } else { Button(title.isEmpty ? "Open attachment" : title) { open?(source) }.buttonStyle(.bordered) }
            case .denied(let reason): Text("Access denied: \(reason)"); retryButton
            case .offline(let reason): Text("Offline: \(reason)"); retryButton
            case .unavailable(let reason): Text("\(title) — \(reason)"); retryButton
            case nil: ProgressView("Resolving attachment")
            }
        }.task(id: source + ":" + String(retry)) {
            presentation = nil
            guard let resolve else { presentation = .unavailable("Application resolution required"); return }
            do { let resolved = try await resolve(node, value); try Task.checkCancellation(); presentation = resolved }
            catch is CancellationError { }
            catch { presentation = .unavailable(String(describing: error)) }
        }
    }
    private var retryButton: some View { Button("Retry resolution") { retry += 1 }.disabled(resolve == nil) }
}
#endif
