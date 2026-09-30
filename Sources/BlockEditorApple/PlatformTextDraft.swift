#if canImport(SwiftUI)
import BlockEditorCore
import Foundation
import Observation

/// Simple platform text-entry controls expose an editing lifecycle, not marked ranges.
@MainActor @Observable final class PlatformTextDraft {
    private(set) var draft: String
    private(set) var editing = false
    @ObservationIgnored private let input: CollaborativeInput

    init(model: EditorModel, address: TextAddress) {
        input = CollaborativeInput(model: model, address: address)
        draft = input.text
        input.onCommit = { [weak self] in
            guard let self else { throw EditorError.invalidChange }
            self.editing = false
            try self.input.commit(text: self.draft, selection: NSRange(location: self.draft.utf16.count, length: 0))
            self.draft = self.input.text
        }
        input.onUpdate = { [weak self] in
            guard let self, !self.editing else { return }
            self.draft = self.input.text
        }
    }
    func begin() {
        guard !editing else { return }
        draft = input.text; editing = true
        input.beginComposition()
    }
    func change(to value: String) {
        draft = value
        // Some controls deliver already-committed dictation without an editing phase.
        if !editing { commit() }
    }
    func finish() {
        guard editing else { return }
        editing = false; commit()
    }
    private func commit() {
        input.update(text: draft, selection: NSRange(location: draft.utf16.count, length: 0), composing: false)
        draft = input.text
    }
    func close() { finish(); input.close() }
}
#endif
