#if os(macOS) || os(iOS) || os(visionOS)
import BlockEditorCore
import Foundation
#if os(macOS)
import AppKit
typealias WritingFocusView = WritingMacTextView
typealias WritingFocusWindow = NSWindow
#else
import UIKit
typealias WritingFocusView = WritingUIKitTextView
typealias WritingFocusWindow = UIWindow
#endif

/// Per-model native leases. Focus follows a rebased opaque origin only inside
/// its original window, and an intentional user responder choice cancels it.
@MainActor final class WritingNativeFocus {
    @MainActor private final class Entry {
        weak var view: WritingFocusView?
        weak var input: WritingCollaborativeInput?
        var hasBeenAttached: Bool
        init(_ view: WritingFocusView, _ input: WritingCollaborativeInput) { self.view = view; self.input = input; hasBeenAttached = view.window != nil }
    }
    @MainActor private final class Pending {
        weak var source: WritingFocusView?
        weak var model: WritingEditorModel?
        weak var window: WritingFocusWindow?
        let address: TextAddress
        let location: NodeAddress?
        var start: WritingPosition?
        var end: WritingPosition?
        var selection: NSRange
        #if os(macOS)
        var affinity: NSSelectionAffinity
        #endif
        var explicit = false
        init(_ view: WritingFocusView, _ input: WritingCollaborativeInput) {
            source = view; model = input.model; window = view.window; address = input.address; selection = input.selection
            #if os(macOS)
            affinity = input.selectionAffinity
            #endif
            location = input.address.identity.flatMap { try? input.model.session.address(of: $0) }
        }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var pending: Pending?
    private var scheduled = false
    private(set) var restoringFocus = false
    func register(_ view: WritingFocusView, input: WritingCollaborativeInput) { entries[ObjectIdentifier(view)] = Entry(view, input) }
    func unregister(_ view: WritingFocusView) { entries.removeValue(forKey: ObjectIdentifier(view)); restoreAfterLayout() }
    func capture(_ view: WritingFocusView, input: WritingCollaborativeInput) {
        guard focused(view), pending?.source !== view else { return }
        pending = Pending(view, input)
    }
    func update(_ view: WritingFocusView?, input: WritingCollaborativeInput) {
        if let pending, pending.source === view, !pending.explicit {
            guard let identity = pending.address.identity, let location = pending.location,
                  (try? input.model.session.address(of: identity)) != location else { cancel(pending); return }
            pending.selection = input.selection
            #if os(macOS)
            pending.affinity = input.selectionAffinity
            #endif
        }
        restoreAfterLayout()
    }
    func permitsKey(from input: WritingCollaborativeInput) -> Bool {
        let live = entries.values.filter { $0.input === input && $0.view != nil }
        for entry in live where entry.view?.window != nil { entry.hasBeenAttached = true }
        return live.allSatisfy { !$0.hasBeenAttached && $0.view?.window == nil } || live.contains { $0.view.map(focused) == true }
    }
    private func cancel(_ pending: Pending) {
        self.pending = nil
        if pending.explicit { pending.model?.finishCaretTransfer() }
    }
    func cancelExplicitCaret(from input: WritingCollaborativeInput? = nil) {
        guard let pending, pending.explicit, input == nil || pending.address == input?.address else { return }
        self.pending = nil
    }
    func requestCaret(_ position: WritingPosition?) { if let position { requestSelection(position, position) } }
    func requestSelection(_ start: WritingPosition, _ end: WritingPosition, from source: WritingCollaborativeInput? = nil) {
        guard let entry = entries.values.first(where: { $0.view.map(focused) == true && (source == nil || $0.input === source) }), let view = entry.view, let input = entry.input else { return }
        let request = Pending(view, input); request.start = start; request.end = end; request.explicit = true
        pending = request; restoreAfterLayout()
    }
    func restoreAfterLayout() {
        guard pending != nil, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.scheduled = false; self.restore() }
    }
    private func restore() {
        guard let pending else { return }
        guard let window = pending.window, pending.model?.isEditable == true else { cancel(pending); return }
        #if os(macOS)
        guard window.firstResponder == nil || window.firstResponder === window || window.firstResponder === pending.source else { cancel(pending); return }
        #else
        if let responder = firstResponder(window), responder !== pending.source { cancel(pending); return }
        #endif
        if !pending.explicit, let source = pending.source, source.window === window, focused(source) { return }
        for entry in entries.values {
            guard let view = entry.view, let input = entry.input, view.window === window, input.canAuthor else { continue }
            var selection = pending.selection
            if let start = pending.start, let end = pending.end {
                guard let a = try? input.model.session.resolve(start), let b = try? input.model.session.resolve(end),
                      a.address.identity == input.address.identity, b.address.identity == input.address.identity,
                      a.address.path.last == input.address.path.last, b.address.path.last == input.address.path.last else { continue }
                selection = NSRange(location: min(a.offset, b.offset), length: abs(b.offset - a.offset))
            } else { guard input.address == pending.address, view !== pending.source else { continue } }
            input.selection = selection
            restoringFocus = true
            #if os(macOS)
            input.selectionAffinity = pending.affinity
            view.setSelectedRange(selection, affinity: pending.affinity, stillSelecting: false)
            let restored = window.makeFirstResponder(view)
            #else
            view.selectedRange = selection
            let restored = view.becomeFirstResponder()
            #endif
            restoringFocus = false
            if restored {
                if let start = pending.start, let end = pending.end { input.retainSelection(start, end) }
                self.pending = nil; input.model.finishCaretTransfer()
            }
            return
        }
    }
    private func focused(_ view: WritingFocusView) -> Bool {
        if view.window != nil { entries[ObjectIdentifier(view)]?.hasBeenAttached = true }
        #if os(macOS)
        return view.window?.firstResponder === view
        #else
        return view.isFirstResponder
        #endif
    }
    #if !os(macOS)
    private func firstResponder(_ view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let found = firstResponder(child) { return found } }
        return nil
    }
    #endif
}
#endif
