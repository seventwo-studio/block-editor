import BlockEditorCore
import Foundation
import Observation

/// Confined protocol-7 host state. Native controls own their buffers and marked
/// text; commands settle those controls before authoring shared operations.
@MainActor @Observable public final class ModernEditorModel {
    public private(set) var document: ModernDocument
    public private(set) var canUndo: Bool
    public private(set) var canRedo: Bool
    public private(set) var error: String?
    public var isEditable = true
    public private(set) var focusIntent: ModernFocusIntent?
    public private(set) var pendingInputs: [UUID: ModernPendingInput] = [:]
    @ObservationIgnored public let session: ModernSession
    @ObservationIgnored public var onChange: ((ModernDocument, ModernChange?) -> Void)?
    @ObservationIgnored private var inputs: [UUID: ModernInputController] = [:]
    @ObservationIgnored private weak var activeInput: ModernInputController?
    @ObservationIgnored private var performing = false
    @ObservationIgnored private var compositionOwners = Set<UUID>()
    @ObservationIgnored private var pendingFocus: PendingFocus?
    @ObservationIgnored private var focusScheduled = false
    @ObservationIgnored var restoringFocus = false
    private final class PendingFocus {
        let source: ModernInputController
        weak var window: AnyObject?
        let range: WritingTextRange
        let permitted: () -> Bool
        init(source: ModernInputController, window: AnyObject, range: WritingTextRange, permitted: @escaping () -> Bool) {
            self.source = source; self.window = window; self.range = range; self.permitted = permitted
        }
    }

    public init(session: ModernSession) {
        self.session = session; document = session.document; canUndo = session.canUndo; canRedo = session.canRedo
        session.onWillReceive = { [weak self] in self?.inputs.values.forEach { $0.prepareReceive() } }
        onChange = session.onChange
        session.onChange = { [weak self] document, change in self?.publish(); self?.onChange?(document, change) }
    }
    private func publish() {
        document = session.document; canUndo = session.canUndo; canRedo = session.canRedo
        Array(inputs.values).forEach { $0.refresh() }
        draftsChanged()
    }
    func register(_ input: ModernInputController) { inputs[input.id] = input; scheduleFocus() }
    func unregister(_ input: ModernInputController) { inputs.removeValue(forKey: input.id); composition(input.id, active: false); draftsChanged() }
    func activate(_ input: ModernInputController) {
        if activeInput !== input { session.endTypingGroup() }
        activeInput = input; focusIntent = nil
        pendingFocus = nil
    }
    public func blur() { activeInput = nil; pendingFocus = nil; focusIntent = nil; session.endTypingGroup() }
    func ownsInput(_ input: ModernInputController) -> Bool { activeInput === input }
    func composition(_ id: UUID, active: Bool) {
        if active { compositionOwners.insert(id) } else { compositionOwners.remove(id) }
        session.isComposing = !compositionOwners.isEmpty
    }
    func draftsChanged() { pendingInputs = Dictionary(uniqueKeysWithValues: inputs.values.compactMap { input in input.pendingInput.map { (input.id, $0) } }) }
    func report(_ failure: Error) { error = String(describing: failure); draftsChanged() }
    func inputSucceeded() { error = nil; publish() }
    /// Returned intent stays local. The canvas owns node/insertion surfaces;
    /// mounted native field controllers apply only checked text intents.
    public func perform(_ operation: (ModernSession) throws -> ModernFocusIntent?) throws {
        guard isEditable, !performing else { throw EditorError.invalidChange }
        performing = true; defer { performing = false }
        let source = activeInput, window = source?.window
        do {
            for input in Array(inputs.values) { try input.settle() }
            if let source { try source.selectionChanged(source.selection) }
            session.endTypingGroup()
            let intent = try operation(session)
            focusIntent = intent; error = nil; publish()
            if let intent, let source, let window { transfer(intent, source: source, window: window) }
        } catch { report(error); publish(); throw error }
    }
    public func undo() throws { try perform { try $0.undo(); return try $0.resolvedLocalSelection()?.focus } }
    public func redo() throws { try perform { try $0.redo(); return try $0.resolvedLocalSelection()?.focus } }
    /// Ordinary receives do not imply a command focus transfer. Controls rebase
    /// their own anchors only while their original native window still owns them.
    public func receive(_ batch: ModernBatch) throws {
        do { try session.receive(batch); error = nil; publish() }
        catch { report(error); publish(); throw error }
    }
    public func checkpoint() throws -> ModernHostCheckpoint {
        guard !inputs.values.contains(where: { $0.nativeEditing }) else { throw ModernSessionError.compositionActive }
        return try ModernHostCheckpoint(session: session, pendingInputs: Array(inputs.values).compactMap { $0.pendingInput })
    }
    func transfer(_ intent: ModernFocusIntent, source: ModernInputController, window: AnyObject, selection: WritingTextRange? = nil) {
        guard case .text(let position) = intent else { return }
        var range = selection ?? WritingTextRange(start: position, end: position)
        if selection == nil, case .text(let selected) = session.localSelection?.selection, selected.end == position { range = selected }
        guard let permitted = source.permitsFocusTransfer else { return }
        pendingFocus = PendingFocus(source: source, window: window, range: range, permitted: permitted)
        scheduleFocus()
    }
    func scheduleFocus() {
        guard pendingFocus != nil, !focusScheduled else { return }
        focusScheduled = true
        // Apply after layout; never resolve a returned caret through mutable
        // selection callbacks from the outgoing native control.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.focusScheduled = false
            guard let pending = self.pendingFocus else { return }
            guard self.isEditable, let window = pending.window, self.activeInput === pending.source, pending.permitted() else { self.pendingFocus = nil; return }
            for input in self.inputs.values {
                self.restoringFocus = true
                let applied = input.applyFocus(pending.range, window: window)
                self.restoringFocus = false
                if applied { self.activate(input); return }
            }
        }
    }
}
