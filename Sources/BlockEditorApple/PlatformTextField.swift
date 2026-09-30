#if os(watchOS) || os(tvOS)
import BlockEditorCore
import SwiftUI

@MainActor struct PlatformTextField: View {
    let model: EditorModel
    let address: TextAddress
    var label = "Text"
    @State private var input: PlatformTextDraft?

    var body: some View {
        Group {
            if let input {
                TextField(label, text: Binding(get: { input.draft }, set: { input.change(to: $0) }),
                          onEditingChanged: { editing in if editing { input.begin() } else { input.finish() } },
                          onCommit: { input.finish() })
            } else {
                Text((try? model.session.text(at: address)) ?? "")
            }
        }
        .onAppear { if input == nil { input = PlatformTextDraft(model: model, address: address) } }
        .onDisappear { input?.close(); input = nil }
    }
}
#endif
