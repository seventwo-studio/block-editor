#if canImport(SwiftUI)
import BlockEditorCore
import Foundation
import Observation
import SwiftUI

/// Dictation/remote controls commit at the native editing lifecycle boundary.
@MainActor @Observable final class WritingPlatformDraft {
    var draft: String
    private(set) var editing = false
    @ObservationIgnored let input: WritingCollaborativeInput
    @ObservationIgnored private var lastNativeValue: String
    init(model: WritingEditorModel, address: TextAddress) {
        input = WritingCollaborativeInput(model: model, address: address); draft = input.text
        lastNativeValue = input.text
        input.onCommit = { [weak self] in
            guard let self, self.input.canAuthor else { throw EditorError.invalidChange }
            try self.input.commit(text: self.draft, selection: NSRange(location: self.draft.utf16.count, length: 0))
            self.editing = false; self.draft = self.input.text
        }
        input.onUpdate = { [weak self] in guard let self, !self.editing else { return }; self.draft = self.input.text }
    }
    func begin() {
        guard input.canAuthor, !editing else { return }
        draft = input.text; lastNativeValue = draft
        editing = true; input.beginComposition()
    }
    func finish() { _ = input.model.performInput { try input.onCommit?() } }
    func change(_ text: String) {
        guard input.canAuthor, text != lastNativeValue else { return }
        // A control can echo its submitted value after deferred peer changes merge.
        // Only a new native value is an edit; begin() resets this for the next lifecycle.
        lastNativeValue = text; draft = text
        input.update(text: text, selection: NSRange(location: text.utf16.count, length: 0), composing: editing)
        if !editing { finish() }
    }
    func close() { finish(); input.close() }
}
#if os(tvOS) || os(watchOS)
@MainActor struct WritingPlatformTextField: View {
    let model: WritingEditorModel
    let address: TextAddress
    var label = "Text"
    @State private var draft: WritingPlatformDraft?
    var body: some View {
        Group {
            if let draft {
                TextField(label, text: Binding(get: { draft.draft }, set: { draft.change($0) }),
                          onEditingChanged: { if $0 { draft.begin() } else { draft.finish() } }, onCommit: { draft.finish() })
            } else { Text((try? model.session.text(at: address)) ?? "") }
        }.onAppear { if draft == nil { draft = WritingPlatformDraft(model: model, address: address) } }
         .onDisappear { draft?.close(); draft = nil }
    }
}
#endif
#endif
