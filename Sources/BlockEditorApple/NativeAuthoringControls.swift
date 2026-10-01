#if canImport(SwiftUI)
import BlockEditorCore
import SwiftUI

#if os(macOS) || os(iOS) || os(visionOS)
@MainActor struct NativeInsertMenu: View {
    let model: EditorModel
    var after: String?
    var body: some View {
        Menu {
            ForEach(NativeBlockInsertion.allCases.filter { $0.isAllowed(allowedBlockTypes: model.allowedBlockTypes) }) { insertion in
                Button(insertion.title) {
                    model.perform { session in try session.insert(insertion.block(), after: after) }
                }
            }
        } label: { Label("Insert block", systemImage: "plus") }
        .accessibilityHint("Choose a block type permitted by this editor")
    }
}
#endif

@MainActor struct NativeNodeActions: View {
    let model: EditorModel
    let address: NodeAddress
    var listItem = false
    var body: some View {
        if let target = try? NativeNodeTarget(session: model.session, address: address) {
            Button("Move up", systemImage: "arrow.up") { model.perform { try target.move(in: $0, down: false) } }
                .disabled(!target.canMove(in: model.session, down: false))
            Button("Move down", systemImage: "arrow.down") { model.perform { try target.move(in: $0, down: true) } }
                .disabled(!target.canMove(in: model.session, down: true))
            if listItem, let identity = target.identity {
                Button("Indent", systemImage: "increase.indent") { model.perform { try $0.indent(identity) } }
                    .disabled(!target.canMove(in: model.session, down: false))
                Button("Outdent", systemImage: "decrease.indent") { model.perform { try $0.outdent(identity) } }
                    .disabled(!target.canOutdent(in: model.session))
            }
            Button("Delete", systemImage: "trash", role: .destructive) { model.perform { try target.delete(in: $0) } }
        }
    }
}
#endif
