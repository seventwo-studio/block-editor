import Foundation

public enum ModernCutPhase: String, Sendable { case prepared, applying, applied, cancelled }
/// Executor-local publication state. It is never replicated or restored as
/// accepted history; a fresh session cannot consume an old publication callback.
public final class ModernCutPreparation {
    public let target: ModernDeleteTarget
    public let clipboard: ModernClipboard
    public fileprivate(set) var phase: ModernCutPhase = .prepared
    public fileprivate(set) var transaction: ChangeID?
    fileprivate let historySelection: ModernLocalSelection?
    fileprivate weak var owner: ModernSession?
    fileprivate init(owner: ModernSession, target: ModernDeleteTarget, clipboard: ModernClipboard) {
        self.owner = owner; self.target = target; self.clipboard = clipboard
        historySelection = owner.localSelection ?? owner.historySelection(target)
    }
}
public struct ModernCutOutcome: Codable, Equatable, Sendable {
    public let status: String
    public let reason: String?
    public let transaction: ChangeID?
    public let result: ModernStructuralResult?
    public let retainedClipboard: ModernClipboard?
}

extension ModernSession {
    /// Native drafts are settled by the host before capture. Preparation is
    /// read-only and gives the publisher this exact immutable rich/plain payload.
    public func prepareCut(_ target: ModernDeleteTarget) throws -> ModernCutPreparation {
        let title = target.ranges.contains { $0.start.field == titleField || $0.end.field == titleField }
        try authoringAllowed(command: title ? "replaceTitle" : "delete")
        let clipboard = try copyClipboard(target)
        guard try canonicalEncoder().encode(target).count <= 32_000_000 else { throw EditorError.recoveryCapacityExceeded }
        return ModernCutPreparation(owner: self, target: target, clipboard: clipboard)
    }
    /// The host confirms publication of the prepared payload, never its current
    /// selection. Failure/cancellation has no accepted-state or history effect.
    public func finishCut(_ preparation: ModernCutPreparation, published: Bool) -> ModernCutOutcome {
        func retained(_ status: String, _ reason: String) -> ModernCutOutcome {
            ModernCutOutcome(status: status, reason: reason, transaction: nil, result: nil, retainedClipboard: preparation.clipboard)
        }
        guard preparation.owner === self else { return retained("unavailable", "cutSessionChanged") }
        switch preparation.phase {
        case .applied: return ModernCutOutcome(status: "noop", reason: "cutAlreadyApplied", transaction: nil, result: nil, retainedClipboard: nil)
        case .cancelled: return retained("unavailable", "cutCancelled")
        case .applying: return retained("unavailable", "cutAlreadyApplying")
        case .prepared: break
        }
        guard published else { return retained("unavailable", "clipboardPublicationFailed") }
        preparation.phase = .applying
        let before = Set(syncState.received)
        do {
            let title = preparation.target.ranges.contains { $0.start.field == titleField || $0.end.field == titleField }
            let result = try withHistorySelection(preparation.historySelection) {
                try title ? cutTitle(preparation.target) : delete(preparation.target)
            }
            let transaction = syncState.received.first { !before.contains($0) && $0.actor == actorID }
            preparation.transaction = transaction; preparation.phase = .applied
            return ModernCutOutcome(status: transaction == nil ? "noop" : "applied", reason: nil, transaction: transaction, result: result, retainedClipboard: nil)
        } catch {
            preparation.phase = .prepared
            if case ModernSessionError.unavailable(let reason) = error { return retained("unavailable", reason) }
            if case ModernSessionError.compositionActive = error { return retained("unavailable", "compositionActive") }
            if case ModernSessionError.recoveryRequired = error { return retained("recoveryRequired", "pendingRecovery") }
            return retained("unavailable", "invalidCutTargetOrAdmission")
        }
    }
    public func cancelCut(_ preparation: ModernCutPreparation) throws {
        guard preparation.owner === self else { throw EditorError.differentDocument }
        guard preparation.phase != .applying else { throw EditorError.invalidChange }
        if preparation.phase == .prepared { preparation.phase = .cancelled }
    }
    /// Convenient synchronous composition; the publisher is invoked once. The
    /// delayed form above lets async adapters await OS publication themselves.
    public func cut(_ target: ModernDeleteTarget, publish: (ModernClipboard) throws -> Bool) throws -> ModernCutOutcome {
        let preparation = try prepareCut(target)
        let published: Bool
        do { published = try publish(preparation.clipboard) }
        catch { return finishCut(preparation, published: false) }
        return finishCut(preparation, published: published)
    }
    private func cutTitle(_ target: ModernDeleteTarget) throws -> ModernStructuralResult {
        try authoringAllowed(command: "replaceTitle")
        guard target.nodes == nil, !target.ranges.isEmpty, target.ranges.allSatisfy({ $0.start.field == titleField && $0.end.field == titleField }) else { throw EditorError.invalidPath }
        var keys = Set<WritingAtomKey>(), caret: WritingPosition?
        for range in target.ranges {
            let selected = try modernCapturedSelection(range); keys.formUnion(selected.keys)
            if caret == nil { caret = selected.position }
        }
        guard keys.count <= 100_000, let caret else { throw EditorError.invalidRange }
        endTypingGroup()
        func result(_ replay: (WritingProjection, ModernDocument, StructuralState), _ observed: [ChangeID]) throws -> ModernStructuralResult {
            _ = try resolveWritingPosition(caret, projection: replay.0, structure: replay.2) { _ in nil }
            return ModernStructuralResult(focus: .text(caret), selection: .text(WritingTextRange(start: caret, end: caret)))
        }
        if keys.isEmpty { return try result(modernCurrentReplay, modernObserved) }
        return try performReturning(nextID(), [.text(.delete(keys: keys.sorted()))], historyBefore: historySelection(target), result: result)
    }
}
