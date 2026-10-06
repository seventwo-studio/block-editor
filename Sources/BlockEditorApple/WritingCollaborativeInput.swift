#if canImport(SwiftUI)
import BlockEditorCore
import Foundation
#if os(macOS)
import AppKit
#endif

/// Native drafts are committed through shared atom operations, preserving every
/// unchanged rich atom and reference. Native controls own marked-text lifecycle.
@MainActor final class WritingCollaborativeInput {
    let model: WritingEditorModel
    let address: TextAddress
    let id = UUID()
    var selection = NSRange(location: 0, length: 0)
    #if os(macOS)
    var selectionAffinity: NSSelectionAffinity = .downstream
    #endif
    var onPrepare: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onCommit: (() throws -> Void)?
    var permission: (() -> Bool)?
    private var draft: (String, NSRange)?
    private var sourceSelection: NSRange?
    #if os(macOS)
    private var sourceAffinity: NSSelectionAffinity?
    #endif
    private var formatting = false
    var effectiveAddress: TextAddress {
        guard model.pendingCaretInput == id, let caret = model.pendingCaret, let resolved = try? model.session.resolve(caret) else { return address }
        return resolved.address
    }
    var canReceiveKey: Bool {
        #if os(macOS) || os(iOS) || os(visionOS)
        canAuthor && model.focus.permitsKey(from: self)
        #else
        canAuthor
        #endif
    }
    var canAuthor: Bool {
        !closed && model.isEditable && permission?() != false && (try? model.session.position(at: effectiveAddress, offset: 0)) != nil
    }
    private(set) var composing = false
    private var anchors: (WritingPosition, WritingPosition)?
    private var retainedSelection: (WritingPosition, WritingPosition)?
    private var release: (() throws -> Void)?
    private var unsubscribe: (() -> Void)?
    private var closed = false
    private var committing = false
    var text: String { (try? model.session.text(at: effectiveAddress)) ?? "" }
    init(model: WritingEditorModel, address: TextAddress) {
        self.model = model
        self.address = (try? model.session.position(at: address, offset: 0).field.node.textAddressForApple(address.path.last ?? "content")) ?? address
        unsubscribe = model.observeInput(id: id, before: { [weak self] in self?.prepare() }, after: { [weak self] in self?.refresh() }, commit: { [weak self] in
            guard let self, !self.closed else { return }
            guard self.canAuthor else {
                if self.composing { throw WritingSessionError.compositionActive }; return
            }
            if let commit = self.onCommit { try commit() }
            else if self.composing { throw WritingSessionError.compositionActive }
        }, caret: { [weak self] in self?.adoptCommandCaret($0) })
    }
    func beginComposition() {
        guard canAuthor else { return }
        composing = true; model.composing(id, true)
        if release == nil { release = model.session.deferRemoteChanges() }
    }
    func update(text: String, selection: NSRange, composing: Bool) {
        guard canAuthor else { return }
        self.selection = selection; draft = (text, selection)
        if composing { beginComposition(); return }
        if model.performInput({ try commit(text: text, selection: selection) }) { applyShortcut() }
        if !self.composing { onUpdate?() }
    }
    func commit(text: String, selection: NSRange) throws {
        guard canAuthor else { throw EditorError.invalidChange }
        let live = effectiveAddress, ownsCaret = model.pendingCaretInput == id
        let old = try model.session.text(at: live)
        if old == text, !composing, release == nil { self.selection = selection; return }
        committing = true
        defer { committing = false; refresh() }
        if old != text {
            retainedSelection = nil
            let difference = Self.difference(old: old, new: text)
            _ = try model.session.replaceText(at: live, range: difference.range, with: difference.text)
        }
        self.selection = selection
        let retained = try model.session.selectedText(at: live, range: selection.location..<NSMaxRange(selection))
        anchors = (retained.start, retained.end)
        if ownsCaret { model.pendingCaret = retained.start }
        draft = nil
        composing = false; model.composing(id, false)
        let finish = release; release = nil
        try finish?()
    }
    private func applyShortcut() {
        guard canAuthor, !composing, selection.length == 0,
              let origin = effectiveAddress.identity, (try? model.nodeValue(origin)["type"]) == .string("paragraph") else { return }
        let literal = String(decoding: text.utf16.prefix(selection.location), as: UTF16.self)
        let targets = ["# ": "heading", "## ": "heading", "### ": "heading", "> ": "quote", "- ": "list", "1. ": "list", "[ ] ": "list", "- [ ] ": "list", "```": "code"]
        guard let target = targets[literal], model.allowedBlockTypes?.contains(target) != false else { return }
        let live = effectiveAddress
        _ = model.performCommand(on: origin, source: id) { try $0.markdownShortcut(at: live, offset: self.selection.location) }
    }
    static func difference(old: String, new: String) -> (range: Range<Int>, text: String) {
        let before = Array(old.unicodeScalars), after = Array(new.unicodeScalars)
        var prefix = 0, suffix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        while suffix < min(before.count, after.count) - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let start = before.prefix(prefix).reduce(0) { $0 + $1.utf16.count }
        let end = before.prefix(before.count - suffix).reduce(0) { $0 + $1.utf16.count }
        return (start..<end, String(String.UnicodeScalarView(after[prefix..<(after.count - suffix)])))
    }
    private func saveSourceSelection() {
        guard sourceSelection == nil else { return }
        sourceSelection = selection
        #if os(macOS)
        sourceAffinity = selectionAffinity
        #endif
    }
    private func adoptCommandCaret(_ caret: WritingPosition) {
        if caret.field.node == address.identity, caret.field.name == address.path.last {
            // A command returning to this field owns the new caret after layout.
            sourceSelection = nil
            #if os(macOS)
            sourceAffinity = nil
            #endif
        } else {
            saveSourceSelection()
        }
        anchors = nil; retainedSelection = nil
        if let resolved = try? model.session.resolve(caret) { selection = NSRange(location: resolved.offset, length: 0) }
    }
    func retainSelection(_ start: WritingPosition, _ end: WritingPosition) { retainedSelection = (start, end) }
    private func prepare() {
        onPrepare?()
        if anchors == nil, let retainedSelection,
           let start = try? model.session.resolve(retainedSelection.0), let end = try? model.session.resolve(retainedSelection.1),
           start.address.identity == effectiveAddress.identity, end.address.identity == effectiveAddress.identity,
           start.address.path.last == effectiveAddress.path.last, end.address.path.last == effectiveAddress.path.last,
           min(start.offset, end.offset) == selection.location, abs(end.offset - start.offset) == selection.length {
            anchors = retainedSelection
        }
        if anchors == nil, let retained = try? model.session.selectedText(at: effectiveAddress, range: selection.location..<NSMaxRange(selection)) {
            anchors = (retained.start, retained.end)
        }
    }
    private func refresh() {
        guard !closed, !composing, !committing else { return }
        let ownedCaret = model.pendingCaretInput == id ? model.pendingCaret : nil
        if ownedCaret != nil, sourceSelection == nil {
            saveSourceSelection()
        } else if ownedCaret == nil, let original = sourceSelection {
            selection = original; sourceSelection = nil
            #if os(macOS)
            if let sourceAffinity { selectionAffinity = sourceAffinity }; sourceAffinity = nil
            #endif
        }
        if let anchors, let start = try? model.session.resolve(anchors.0), let end = try? model.session.resolve(anchors.1), start.address.identity == end.address.identity {
            selection = NSRange(location: min(start.offset, end.offset), length: abs(end.offset - start.offset))
            #if os(macOS) || os(iOS) || os(visionOS)
            if start.address.identity != address.identity || start.address.path.last != address.path.last {
                model.focus.requestSelection(anchors.0, anchors.1, from: self)
            }
            #endif
        }
        anchors = nil
        if !formatting, let ownedCaret, let resolved = try? model.session.resolve(ownedCaret) { selection = NSRange(location: resolved.offset, length: selection.length) }
        let count = text.utf16.count, start = min(selection.location, count)
        selection = NSRange(location: start, length: min(selection.length, count - start))
        onUpdate?()
    }
    @discardableResult func command(_ key: WritingNativeKey) -> Bool {
        // Ordinary deletion remains a native text replacement. Boundary deletion
        // becomes the shared adjacent-paragraph merge after composition commits.
        guard canReceiveKey else { return false }
        let pending = model.pendingCaretInput == id ? model.pendingCaret : nil
        let pendingLocation = pending.flatMap { try? model.session.resolve($0) }
        let location = pendingLocation?.offset ?? selection.location
        let length = selection.length
        if key == .backspace, location != 0 || length != 0 { return false }
        let succeeded = model.performCommand(source: id) { session in
            let resolved = try (self.model.commandCaret ?? pending).map { try session.resolve($0) }
            let offset = resolved?.offset ?? self.selection.location
            let live = try resolved?.address ?? session.resolve(session.position(at: address, offset: offset)).address
            let identity = try session.position(at: live, offset: 0).field.node
            let node = try self.model.nodeValue(identity), range = offset..<(offset + self.selection.length)
            switch key {
            case .softBreak: return try session.softBreak(at: live, range: range)
            case .enter:
                if node["type"] == nil { return try session.enterListItem(at: live, range: range, newItemID: UUID().uuidString) }
                if live.path.last == "content", ["paragraph", "heading", "quote", "callout"].contains(node["type"]?.string ?? "") {
                    return try session.splitParagraph(at: live, range: range, newBlockID: UUID().uuidString)
                }
                return try session.softBreak(at: live, range: range)
            case .backspace:
                let siblings = try session.collectionNodes(in: self.model.collection(containing: identity))
                guard node["type"] == .string("paragraph"), let index = siblings.firstIndex(of: identity), index > 0,
                      try self.model.nodeValue(siblings[index - 1])["type"] == .string("paragraph") else { throw EditorError.invalidPath }
                return try session.mergeParagraphs(left: siblings[index - 1], right: identity)
            }
        }
        if succeeded { onUpdate?() }
        return true
    }
    func copyClipboard() -> WritingClipboard? {
        guard canReceiveKey, !composing else { return nil }
        onPrepare?()
        var clipboard: WritingClipboard?
        _ = model.performInput {
            let range = try model.session.selectedText(at: effectiveAddress, range: selection.location..<NSMaxRange(selection))
            clipboard = try model.session.copyClipboard(WritingSelection(text: [range]))
        }
        return clipboard
    }
    /// Finalize the native draft and drain peers before resolving its current range.
    /// Failed import/paste stays visible; the native control never writes a fallback.
    @discardableResult func pasteImported(_ payload: WritingNativeClipboardPayload) -> Bool {
        guard canReceiveKey else { return false }
        return model.performCommand(source: id) { session in
            let clipboard = try WritingNativeClipboard.decode(payload, protocolVersion: session.protocolVersion)
            let normalized = try clipboard.normalizeForImport(policy: self.model.pastePolicy, hostBlockTypes: self.model.allowedBlockTypes)
            let resolved = try self.model.commandCaret.map { try session.resolve($0) }
            let offset = resolved?.offset ?? self.selection.location
            let live = try resolved?.address ?? session.resolve(session.position(at: self.address, offset: offset)).address
            let range = try session.selectedText(at: live, range: offset..<(offset + self.selection.length))
            if session.protocolVersion == 4 {
                return try session.pasteInline(normalized.clipboard, replacing: range, policy: normalized.effectivePastePolicy)
            }
            return try session.pasteSelection(normalized.clipboard, replacing: range, policy: normalized.effectivePastePolicy)
        }
    }
    func selectionChangedByUser(_ nativeSelection: NSRange? = nil) {
        if let nativeSelection, nativeSelection == selection { return }
        anchors = nil; retainedSelection = nil
        if let nativeSelection, model.pendingCaretInput == id,
           let retained = try? model.session.selectedText(at: effectiveAddress, range: nativeSelection.location..<NSMaxRange(nativeSelection)) {
            // The old responder is rendering the proven target while layout is
            // pending. Selecting that text updates its range, not its origin.
            selection = nativeSelection; model.pendingCaret = retained.start
            #if os(macOS) || os(iOS) || os(visionOS)
            model.focus.requestSelection(retained.start, retained.end, from: self)
            #endif
            return
        }
        if model.pendingCaretInput == id { model.finishCaretTransfer() }
        #if os(macOS) || os(iOS) || os(visionOS)
        model.focus.cancelExplicitCaret(from: self)
        #endif
    }
    func format(_ type: String) {
        guard canReceiveKey, selection.length > 0 else { return }
        let live = effectiveAddress
        formatting = true; defer { formatting = false }
        _ = model.performCommand(source: id, preservingCaret: true) { session in
            let range = self.selection.location..<NSMaxRange(self.selection)
            let selection = try session.selectedText(at: live, range: range)
            let nodes = try session.copy(WritingSelection(text: [selection])).text.flatMap { $0 }
            let marked = !nodes.isEmpty && nodes.allSatisfy { $0["marks"]?.array?.contains { $0["type"] == .string(type) } == true }
            try session.format(at: live, range: range, markType: type, mark: marked ? nil : .object(["type": .string(type)]))
            return nil
        }
    }
    func close() {
        guard !closed else { return }
        // A view cannot discard marked input on a structural handoff.
        if composing {
            let accepted = model.performInput {
                guard canAuthor, let onCommit else { throw WritingSessionError.compositionActive }
                try onCommit()
            }
            if !accepted, let draft {
                model.retainDraft(WritingPendingDraft(address: effectiveAddress, text: draft.0, selection: draft.1, reason: model.error ?? "Composition commit failed"), id: id)
            }
        }
        closed = true; unsubscribe?(); unsubscribe = nil
        model.composing(id, false); composing = false
        let finish = release; release = nil
        if let finish { _ = model.performInput { try finish() } }
        onCommit = nil; onPrepare = nil; onUpdate = nil; permission = nil
    }
}

enum WritingNativeKey { case enter, softBreak, backspace }
extension NodeID {
    func textAddressForApple(_ name: String) -> TextAddress {
        switch self {
        case .document: return TextAddress("", path: [name], identity: self)
        case .baseline(let root, let path): return TextAddress(root, path: path + [name], identity: self)
        case .inserted(let creation, let path): return TextAddress("@\(creation.change.actor)/\(creation.change.counter)/\(creation.index)", path: path + [name], identity: self)
        }
    }
}
#endif
