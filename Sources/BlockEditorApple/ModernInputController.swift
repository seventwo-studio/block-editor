import BlockEditorCore
import Foundation

/// Native input integration for one opaque field, independent of labels and
/// viewport containers. Bind callbacks to weak native views in a host adapter.
@MainActor public final class ModernInputController {
    public let id = UUID()
    public let field: WritingField
    private weak var host: ModernEditorModel?
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var composing = false
    public private(set) var pendingInput: ModernPendingInput?
    public weak var window: AnyObject? { didSet { host?.scheduleFocus() } }
    /// True only while this control, or its detached lease, still owns focus in
    /// that window. An intentional responder choice must return false.
    public var permitsFocusTransfer: (() -> Bool)?
    public var applyNativeFocus: ((NSRange) -> Bool)?
    public var onProjection: (() -> Void)?
    /// Unmark the actual native input and submit its final buffer. A failed
    /// settle must throw; commands cannot skip a retained composition draft.
    public var settleNativeInput: (() throws -> Void)?
    private var release: (() throws -> Void)?
    private var sourceText: String?
    private var retainedTarget: ModernTextRange
    private var anchors: WritingTextRange?
    private var closed = false
    private var committing = false
    public private(set) var nativeEditing = false
    private let typingGroup = UUID().uuidString
    public var text: String { host.flatMap { try? $0.session.text(in: field) } ?? "" }

    public init(model: ModernEditorModel, field: WritingField) throws {
        _ = try model.session.text(in: field)
        retainedTarget = try model.session.captureTextRange(in: field, start: 0, end: model.session.text(in: field).utf16.count)
        host = model; self.field = field; model.register(self)
    }
    public func activate(selection: NSRange) throws {
        guard let model = host, !closed, model.isActive else { throw EditorError.invalidChange }
        model.activate(self); try selectionChanged(selection)
    }
    public func selectionChanged(_ range: NSRange) throws {
        guard let model = host, !closed, range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { throw EditorError.invalidChange }
        selection = range
        guard !composing, !committing else { return }
        try updateSelectionAnchors(range, model: model)
    }
    private func updateSelectionAnchors(_ range: NSRange, model: ModernEditorModel) throws {
        // Native offset echoes can describe either side of an atom boundary.
        // Keep the command's existing causal anchor when the caret is unchanged.
        if model.ownsInput(self), let local = model.session.localSelection,
           case .text(let current) = local.selection,
           let start = try? model.session.resolve(current.start), let end = try? model.session.resolve(current.end),
           start.address.identity == field.node, end.address.identity == field.node,
           start.address.path.last == field.name, end.address.path.last == field.name,
           min(start.offset, end.offset) == range.location, abs(end.offset - start.offset) == range.length {
            anchors = current; return
        }
        let captured = try model.session.captureTextRange(in: field, start: range.location, end: NSMaxRange(range))
        anchors = WritingTextRange(start: captured.start, end: captured.end)
        if model.ownsInput(self) { try model.session.setLocalSelection(model.session.captureLocalSelection(focus: .text(captured.end), selection: .text(anchors!))) }
    }
    public func beginComposition() throws {
        guard let model = host, !closed, model.isActive, model.isEditable else { throw EditorError.invalidChange }
        if !composing {
            if sourceText == nil { sourceText = text }
            if release == nil { release = try model.session.holdRemoteChanges() }
            composing = true; model.composition(id, active: true)
        }
    }
    public func beginNativeOperation(marked: Bool = false) throws {
        guard let model = host, !closed, model.isActive, model.isEditable else { throw EditorError.invalidChange }
        if sourceText == nil { sourceText = text }
        if release == nil { release = try model.session.holdRemoteChanges() }
        nativeEditing = true
        if marked { try beginComposition() }
    }
    /// Call after the outermost native operation, including replacement and
    /// unmarking. Do not refresh the platform projection while it owns marks.
    public func update(text value: String, selection range: NSRange, marked: Bool) throws {
        guard let model = host, !closed, range.location != NSNotFound, range.location >= 0,
              range.length >= 0, range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location else { throw EditorError.invalidChange }
        nativeEditing = false
        if !marked, !composing, pendingInput == nil, sourceText == nil, value == text {
            try selectionChanged(range); return
        }
        if marked, model.isEditable { try beginComposition() }
        let before = sourceText ?? text, difference = Self.difference(before, value)
        let target: ModernTextRange
        do { target = try model.session.captureTextRange(in: field, start: difference.range.lowerBound, end: difference.range.upperBound) }
        catch {
            pendingInput = ModernPendingInput(target: retainedTarget, text: value, selection: 0..<value.utf16.count,
                reason: "Target unavailable", nativeText: value, nativeSelection: range.location..<NSMaxRange(range))
            model.report(error); throw error
        }
        pendingInput = ModernPendingInput(target: target, text: difference.text,
            selection: 0..<difference.text.utf16.count, reason: marked ? "Native composition" : "Uncommitted native input",
            nativeText: value, nativeSelection: range.location..<NSMaxRange(range))
        selection = range
        if marked { model.draftsChanged(); return }
        guard model.isActive, model.isEditable else { let failure = EditorError.invalidChange; model.report(failure); throw failure }
        let wasComposing = composing
        committing = true; defer { committing = false; refresh() }
        model.composition(id, active: false)
        do {
            if before != value {
                _ = try model.session.replaceText(in: target, with: difference.text, typingGroup: typingGroup)
            }
            try updateSelectionAnchors(range, model: model)
            pendingInput = nil; sourceText = nil; composing = false; model.composition(id, active: false)
            let finish = release; release = nil; try finish?()
            model.inputSucceeded()
        } catch {
            // Keep original captured payload and hold on authoring failure.
            // If peer draining fails after the edit, the edit stays committed;
            // recovery/deferred exports own that separate retained proposal.
            if pendingInput != nil { composing = wasComposing; model.composition(id, active: wasComposing) }
            model.report(error); throw error
        }
    }
    func settle() throws {
        guard !closed else { return }
        guard !nativeEditing else { throw ModernSessionError.compositionActive }
        if let settleNativeInput { try settleNativeInput() }
        if composing || pendingInput != nil { throw ModernSessionError.compositionActive }
    }
    func prepareReceive() {
        guard let model = host, !closed, !composing, !committing, !nativeEditing else { return }
        if let captured = try? model.session.captureTextRange(in: field, start: selection.location, end: NSMaxRange(selection)) {
            anchors = WritingTextRange(start: captured.start, end: captured.end)
        }
    }
    func refresh() {
        guard let model = host, !closed, !composing, !committing, !nativeEditing else { return }
        if let anchors, let start = try? model.session.resolve(anchors.start), let end = try? model.session.resolve(anchors.end) {
            if start.address.identity == field.node, end.address.identity == field.node,
               start.address.path.last == field.name, end.address.path.last == field.name {
                selection = NSRange(location: min(start.offset, end.offset), length: abs(end.offset - start.offset))
            } else if model.ownsInput(self), let window, permitsFocusTransfer?() == true {
                model.transfer(.text(anchors.end), source: self, window: window, selection: anchors)
            }
        }
        if let captured = try? model.session.captureTextRange(in: field, start: 0, end: text.utf16.count) { retainedTarget = captured }
        onProjection?()
    }
    func applyFocus(_ range: WritingTextRange, window: AnyObject) -> Bool {
        guard let model = host, !closed, !composing, model.isEditable, self.window === window,
              let start = try? model.session.resolve(range.start), let end = try? model.session.resolve(range.end),
              start.address.identity == field.node, end.address.identity == field.node,
              start.address.path.last == field.name, end.address.path.last == field.name else { return false }
        let selected = NSRange(location: min(start.offset, end.offset), length: abs(end.offset - start.offset))
        guard applyNativeFocus?(selected) == true else { return false }
        selection = selected; anchors = range; return true
    }
    /// Retains a failed/detached native buffer for the host's durable checkpoint.
    /// Caller must export that buffer before forgetting this controller.
    public func close() throws {
        guard !closed else { return }
        if composing || nativeEditing || pendingInput != nil { throw ModernSessionError.compositionActive }
        closed = true; host?.unregister(self); onProjection = nil; settleNativeInput = nil
        permitsFocusTransfer = nil; applyNativeFocus = nil; window = nil
        let finish = release; release = nil; try finish?()
    }
    private static func difference(_ before: String, _ after: String) -> (range: Range<Int>, text: String) {
        let a = Array(before.unicodeScalars), b = Array(after.unicodeScalars)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let start = a.prefix(prefix).reduce(0) { $0 + $1.utf16.count }
        let end = a.prefix(a.count - suffix).reduce(0) { $0 + $1.utf16.count }
        return (start..<end, String(String.UnicodeScalarView(b[prefix..<(b.count - suffix)])))
    }
}
