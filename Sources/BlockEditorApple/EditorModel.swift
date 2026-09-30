#if canImport(SwiftUI)
import BlockEditorCore
import Observation
import SwiftUI

/// Hosts retain the model and decide when to save or exchange changes.
@MainActor @Observable public final class EditorModel {
    public private(set) var document: BlockEditorCore.Document
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var error: String?
    @ObservationIgnored public let session: EditorSession
    @ObservationIgnored public var onChange: ((BlockEditorCore.Document, Change?) -> Void)?

    @ObservationIgnored private var inputs: [UUID: (before: () -> Void, after: () -> Void)] = [:]

    public init(session: EditorSession) throws {
        self.session = session; self.document = try session.document
        canUndo = session.canUndo; canRedo = session.canRedo
        session.onWillReceive = { [weak self] in self?.inputs.values.forEach { $0.before() } }
        session.onChange = { [weak self] document, change in
            guard let self else { return }
            self.document = document; self.canUndo = self.session.canUndo; self.canRedo = self.session.canRedo
            self.inputs.values.forEach { $0.after() }
            self.onChange?(document, change)
        }
    }
    func observeInput(before: @escaping () -> Void, after: @escaping () -> Void) -> () -> Void {
        let id = UUID(); inputs[id] = (before, after)
        return { [weak self] in self?.inputs.removeValue(forKey: id) }
    }
    public func perform(_ operation: (EditorSession) throws -> Void) {
        do { try operation(session); error = nil }
        catch { self.error = String(describing: error) }
    }
}
#endif
