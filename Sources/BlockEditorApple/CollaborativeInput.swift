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
    private var anchors: (TextPosition, TextPosition)?
    private var release: (() throws -> Void)?
    private var unsubscribe: (() -> Void)?
    private(set) var composing = false
    var text: String { (try? model.session.text(at: address)) ?? "" }

    init(model: EditorModel, address: TextAddress) {
        self.model = model; self.address = address
        unsubscribe = model.observeInput(before: { [weak self] in self?.prepare() }, after: { [weak self] in self?.refresh() })
    }
    func beginComposition() {
        composing = true
        if release == nil { release = model.session.deferRemoteChanges() }
    }
    func update(text: String, selection: NSRange, composing: Bool) {
        self.selection = selection
        if composing { beginComposition(); return }
        self.composing = false
        let finish = release; release = nil
        model.perform { session in
            var failure: Error?
            do { if try session.text(at: address) != text { try session.setText(at: address, to: text) } }
            catch { failure = error }
            do { try finish?() } catch { if failure == nil { failure = error } }
            if let failure { throw failure }
        }
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
        unsubscribe?(); unsubscribe = nil
        onPrepare = nil; onUpdate = nil
        let finish = release; release = nil
        if let finish { model.perform { _ in try finish() } }
    }
}
#endif
