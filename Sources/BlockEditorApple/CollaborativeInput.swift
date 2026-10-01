#if canImport(SwiftUI)
import BlockEditorCore
import Foundation

/// Platform text views own marked text; this adapter commits it before remote replay.
@MainActor final class CollaborativeInput {
    let model: EditorModel
    let address: TextAddress
    var selection = NSRange(location: 0, length: 0)
    var onPrepare: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onCommit: (() throws -> Void)?
    private var closed = false
    private var anchors: (TextPosition, TextPosition)?
    private var release: (() throws -> Void)?
    private var unsubscribe: (() -> Void)?
    private(set) var composing = false
    var text: String { (try? model.session.text(at: address)) ?? "" }

    init(model: EditorModel, address: TextAddress) {
        self.model = model
        // Capture the origin before a remote move can reuse this live document path.
        self.address = (try? model.session.position(at: address, offset: 0).address) ?? address
        unsubscribe = model.observeInput(before: { [weak self] in self?.prepare() }, after: { [weak self] in self?.refresh() }, commit: { [weak self] in
            guard let self, self.composing else { return }
            guard let commit = self.onCommit else { throw EditorError.invalidChange }
            try commit()
        })
    }
    func beginComposition() {
        guard !closed else { return }
        composing = true
        if release == nil { release = model.session.deferRemoteChanges() }
    }
    func update(text: String, selection: NSRange, composing: Bool) {
        guard !closed else { return }
        self.selection = selection
        if composing { beginComposition(); return }
        model.performInput { _ in try commit(text: text, selection: selection) }
    }
    /// Called only after the platform has ended its marked-text interaction.
    func commit(text: String, selection: NSRange) throws {
        guard !closed else { return }
        self.selection = selection; composing = false
        let finish = release; release = nil
        var failure: Error?
        do { if try model.session.text(at: address) != text { try model.session.setText(at: address, to: text) } }
        catch { failure = error }
        do { try finish?() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
    private func prepare() {
        onPrepare?()
        anchors = try? (model.session.position(at: address, offset: selection.location),
                        model.session.position(at: address, offset: NSMaxRange(selection)))
    }
    private func refresh() {
        guard !composing else { return }
        if let anchors, let start = try? model.session.offset(of: anchors.0), let end = try? model.session.offset(of: anchors.1) {
            selection = NSRange(location: min(start, end), length: abs(end - start))
        }
        anchors = nil
        let count = text.utf16.count
        let start = min(selection.location, count)
        selection = NSRange(location: start, length: min(selection.length, count - start))
        onUpdate?()
    }
    func close() {
        guard !closed else { return }
        closed = true
        unsubscribe?(); unsubscribe = nil
        onPrepare = nil; onUpdate = nil; onCommit = nil
        let finish = release; release = nil
        if let finish { model.performInput { _ in try finish() } }
    }
}
#endif
