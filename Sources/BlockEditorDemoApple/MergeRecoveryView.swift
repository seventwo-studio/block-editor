#if canImport(SwiftUI)
import BlockEditorCore
import BlockEditorLocalDemo
import SwiftUI

@MainActor struct MergeRecoveryView: View {
    let recovery: MergeRecovery
    let canWrap: Bool
    let repair: (NodeID) -> Void
    let export: () throws -> URL
    let retry: () -> Void
    @State private var selected: NodeID?
    @State private var archive: URL?
    @State private var exportError: String?

    var body: some View {
        let blocks = RecoveryBlock.candidates(in: recovery)
        VStack(alignment: .leading, spacing: 8) {
            Text("Some edits need recovery").font(.headline).accessibilityIdentifier("merge-recovery")
            Text("Your accepted document is still available. Pending edits are kept separately; editing and undo wait until the conflict is repaired.")
            Picker("Block to recover", selection: $selected) {
                Text("Choose a recorded block").tag(nil as NodeID?)
                ForEach(blocks) { block in Text(block.label).tag(Optional(block.id)) }
            }.accessibilityIdentifier("recovery-block-picker")
            Button("Place selected block in a new toggle") {
                if let selected { repair(selected) }
            }.disabled(selected == nil || !canWrap).accessibilityIdentifier("repair-merge")
            Text("This keeps the block's text, formatting and nested content. Other conflicts may need a different repair; export retains the complete pending history.")
                .font(.caption)
            Button("Export recovery archive") {
                do { archive = try export(); exportError = nil }
                catch { exportError = String(describing: error) }
            }.accessibilityIdentifier("export-recovery")
            Button("Retry synchronization", action: retry)
            if let archive {
                Text("Recovery archive saved locally").accessibilityIdentifier("recovery-exported")
                #if os(iOS) || os(macOS) || os(visionOS)
                ShareLink("Share recovery archive", item: archive)
                #endif
            }
            if let exportError { Text("Export failed: \(exportError)").foregroundStyle(.red) }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: recovery) { _, _ in
            if !blocks.contains(where: { $0.id == selected }) { selected = nil }
            archive = nil
        }
    }
}
#endif
