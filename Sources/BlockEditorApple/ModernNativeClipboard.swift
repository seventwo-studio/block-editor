import BlockEditorCore
import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

/// Original clipboard bytes stay inert, including malformed rich input.
public enum ModernClipboardPayload: Codable, Equatable, Sendable {
    case structured(Data), text(String), markdown(String)
    public func decode() throws -> ModernClipboard {
        switch self {
        case .structured(let bytes): return try ModernClipboard(json: bytes)
        case .text(let text): return try ModernClipboard.multiline(text)
        case .markdown(let text): return try ModernClipboard.markdown(text)
        }
    }
}
public enum ModernClipboardPurpose: Codable, Equatable, Sendable {
    case paste(ModernPasteTarget), cut(ModernDeleteTarget)
}
public struct ModernRetainedClipboard: Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: String
    public let epoch: String
    public let payload: ModernClipboardPayload
    public let purpose: ModernClipboardPurpose
    public let reason: String
    public init(id: UUID = UUID(), documentID: String, epoch: String, payload: ModernClipboardPayload, purpose: ModernClipboardPurpose, reason: String) {
        self.id = id; self.documentID = documentID; self.epoch = epoch
        self.payload = payload; self.purpose = purpose; self.reason = reason
    }
    func withReason(_ reason: String) -> Self {
        Self(id: id, documentID: documentID, epoch: epoch, payload: payload, purpose: purpose, reason: String(reason.prefix(1000)))
    }
}
func validateRetainedClipboard(_ records: [ModernRetainedClipboard], documentID: String, epoch: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard records.count <= 64, Set(records.map(\.id)).count == records.count,
          try encoder.encode(records).count <= 64_000_000 else { throw ModernHostStoreError.capacityExceeded }
    for record in records {
        guard record.documentID == documentID, record.epoch == epoch, record.reason.utf16.count <= 1000 else { throw ModernHostStoreError.invalidCheckpoint }
        switch record.payload {
        case .structured(let data): guard data.count <= 32_000_000 else { throw ModernHostStoreError.capacityExceeded }
        case .text(let text), .markdown(let text): guard text.utf16.count <= 1_000_000 else { throw ModernHostStoreError.capacityExceeded }
        }
        // The record may intentionally contain an invalid clipboard/target.
        // Only explicit retry performs shared admission; restoration is inert.
    }
}

@MainActor public protocol ModernClipboardAccess {
    func read() throws -> ModernClipboardPayload?
    /// Return true only after the exact prepared rich/plain payload is stored.
    func publish(_ clipboard: ModernClipboard) throws -> Bool
}

#if os(macOS) || os(iOS) || os(visionOS)
@MainActor public struct ModernNativeClipboard: ModernClipboardAccess {
    public static let identifier = "studio.seventwo.blockeditor.modern-clipboard"
    #if os(macOS)
    public let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public func read() throws -> ModernClipboardPayload? {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(Self.identifier)) { return .structured(data) }
        return pasteboard.string(forType: .string).map(ModernClipboardPayload.text)
    }
    public func publish(_ clipboard: ModernClipboard) throws -> Bool {
        let data = try clipboard.json(), item = NSPasteboardItem(), type = NSPasteboard.PasteboardType(Self.identifier)
        guard item.setData(data, forType: type), item.setString(clipboard.plainText, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) && pasteboard.data(forType: type) == data && pasteboard.string(forType: .string) == clipboard.plainText
    }
    #else
    public let pasteboard: UIPasteboard
    public init(pasteboard: UIPasteboard = .general) { self.pasteboard = pasteboard }
    public func read() throws -> ModernClipboardPayload? {
        if let data = pasteboard.data(forPasteboardType: Self.identifier) { return .structured(data) }
        return pasteboard.string.map(ModernClipboardPayload.text)
    }
    public func publish(_ clipboard: ModernClipboard) throws -> Bool {
        let data = try clipboard.json()
        pasteboard.setItems([[Self.identifier: data, "public.utf8-plain-text": clipboard.plainText]])
        return pasteboard.data(forPasteboardType: Self.identifier) == data && pasteboard.string == clipboard.plainText
    }
    #endif
}
#endif

public enum ModernHostClipboardResult: Equatable, Sendable {
    case applied, noop, retained(UUID, String)
}

/// Host-local tickets bind publication to the original active invocation.
/// Reopen restores payloads, never publication acknowledgments or live tickets.
@MainActor @Observable public final class ModernClipboardController {
    public private(set) var retained: [ModernRetainedClipboard]
    public var pastePolicy = WritingPastePolicy()
    @ObservationIgnored private weak var model: ModernEditorModel?
    @ObservationIgnored private var tickets: [UUID: Ticket] = [:]
    @MainActor private final class Ticket {
        let preparation: ModernCutPreparation
        let generation: UInt64
        weak var source: ModernInputController?
        weak var window: AnyObject?
        let hasSource: Bool
        let permitted: (() -> Bool)?
        init(_ preparation: ModernCutPreparation, generation: UInt64, source: ModernInputController?) {
            self.preparation = preparation; self.generation = generation; self.source = source
            window = source?.window; hasSource = source != nil; permitted = source?.permitsFocusTransfer
        }
    }
    init(model: ModernEditorModel, retained: [ModernRetainedClipboard]) { self.model = model; self.retained = retained }
    public func forget(_ id: UUID) throws {
        if let ticket = tickets[id], let model { try model.session.cancelCut(ticket.preparation) }
        tickets.removeValue(forKey: id); retained.removeAll { $0.id == id }
    }
    private func reserve(_ payload: ModernClipboardPayload, purpose: ModernClipboardPurpose) throws -> UUID {
        guard let model else { throw EditorError.invalidChange }
        let record = ModernRetainedClipboard(documentID: model.session.documentID, epoch: model.session.epoch,
            payload: payload, purpose: purpose, reason: "Awaiting clipboard operation")
        try validateRetainedClipboard(retained + [record], documentID: model.session.documentID, epoch: model.session.epoch)
        retained.append(record); return record.id
    }
    private func fail(_ id: UUID, _ reason: String) -> ModernHostClipboardResult {
        if let index = retained.firstIndex(where: { $0.id == id }) { retained[index] = retained[index].withReason(reason) }
        return .retained(id, reason)
    }
    /// Retain an uncommitted native empty-body buffer without applying it. The
    /// boundary was captured before composition; restored records remain inert.
    public func retainInput(_ text: String, at target: ModernPasteTarget, id: UUID, reason: String) throws {
        guard let model else { throw EditorError.invalidChange }
        let record = ModernRetainedClipboard(id: id, documentID: model.session.documentID, epoch: model.session.epoch, payload: .text(text), purpose: .paste(target), reason: reason)
        let candidate = retained.filter { $0.id != id } + [record]
        try validateRetainedClipboard(candidate, documentID: model.session.documentID, epoch: model.session.epoch)
        retained = candidate
    }
    public func copy(_ target: ModernDeleteTarget, to access: any ModernClipboardAccess, source: ModernInputController? = nil) throws -> Bool {
        guard let model else { throw EditorError.invalidChange }
        try model.captureClipboardSelection(source)
        return try access.publish(model.session.copyClipboard(target))
    }
    public func prepareCut(_ target: ModernDeleteTarget, source: ModernInputController? = nil) throws -> (id: UUID, clipboard: ModernClipboard) {
        guard let model, model.isEditable, tickets.count < 8 else { throw EditorError.invalidChange }
        try model.captureClipboardSelection(source)
        let preparation = try model.session.prepareCut(target)
        let id = try reserve(.structured(preparation.clipboard.json()), purpose: .cut(target))
        tickets[id] = Ticket(preparation, generation: model.invocationGeneration, source: source)
        return (id, preparation.clipboard)
    }
    public func finishCut(_ id: UUID, published: Bool) -> ModernHostClipboardResult {
        guard let ticket = tickets[id], let model else { return .noop }
        guard model.isActive, model.isEditable, model.invocationGeneration == ticket.generation,
              !ticket.hasSource || (ticket.source != nil && ticket.window != nil && ticket.source?.window === ticket.window && model.ownsInput(ticket.source!) && ticket.permitted?() == true) else {
            return fail(id, "Original clipboard invocation is inactive")
        }
        let result = model.session.finishCut(ticket.preparation, published: published)
        guard result.retainedClipboard == nil else { return fail(id, result.reason ?? "Cut unavailable") }
        tickets.removeValue(forKey: id); retained.removeAll { $0.id == id }
        model.clipboardApplied(result.result, source: ticket.source)
        return result.status == "applied" ? .applied : .noop
    }
    public func cut(_ target: ModernDeleteTarget, to access: any ModernClipboardAccess, source: ModernInputController? = nil) throws -> ModernHostClipboardResult {
        let prepared = try prepareCut(target, source: source)
        let published: Bool
        do { published = try access.publish(prepared.clipboard) } catch { published = false }
        return finishCut(prepared.id, published: published)
    }
    public func paste(_ payload: ModernClipboardPayload, at target: ModernPasteTarget, mode: ModernPasteMode = .rich, source: ModernInputController? = nil) throws -> ModernHostClipboardResult {
        guard let model else { throw EditorError.invalidChange }
        try model.captureClipboardSelection(source)
        let id = try reserve(payload, purpose: .paste(target))
        return applyPaste(id, mode: mode, source: source)
    }
    /// Explicit retry preserves the captured destination. A plain fallback uses
    /// the stored rich envelope's checked fallback, never a new clipboard read.
    public func retryPaste(_ id: UUID, mode: ModernPasteMode = .rich) -> ModernHostClipboardResult {
        applyPaste(id, mode: mode, source: nil)
    }
    private func applyPaste(_ id: UUID, mode: ModernPasteMode, source: ModernInputController?) -> ModernHostClipboardResult {
        guard let model, let record = retained.first(where: { $0.id == id }), case .paste(let target) = record.purpose else { return .noop }
        guard model.isActive, model.isEditable, record.documentID == model.session.documentID, record.epoch == model.session.epoch else { return fail(id, "Original paste invocation is inactive") }
        do {
            try model.captureClipboardSelection(source)
            let effectiveMode: ModernPasteMode
            if case .text = record.payload { effectiveMode = .plainText } else { effectiveMode = mode }
            let result = try model.session.paste(record.payload.decode(), at: target, mode: effectiveMode, policy: pastePolicy)
            retained.removeAll { $0.id == id }; model.clipboardApplied(result, source: source); return .applied
        } catch { model.report(error); return fail(id, String(describing: error)) }
    }
}
