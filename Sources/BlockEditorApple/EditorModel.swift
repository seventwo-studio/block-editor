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

    public init(session: EditorSession) throws {
        self.session = session; self.document = try session.document
        canUndo = session.canUndo; canRedo = session.canRedo
        session.onChange = { [weak self] document, change in
            guard let self else { return }
            self.document = document; self.canUndo = self.session.canUndo; self.canRedo = self.session.canRedo
            self.onChange?(document, change)
        }
    }
    public func perform(_ operation: (EditorSession) throws -> Void) {
        do { try operation(session); error = nil }
        catch { self.error = String(describing: error) }
    }
}
#endif
