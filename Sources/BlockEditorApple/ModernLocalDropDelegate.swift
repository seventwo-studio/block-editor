#if os(macOS) || os(iOS) || os(visionOS)
import SwiftUI

/// Native drag destinations only preview captured boundaries. Cancellation and
/// external pasteboard drags cannot publish a shared move.
@MainActor struct ModernLocalDropDelegate: DropDelegate {
    let allowed: () -> Bool
    let preview: (CGPoint) -> Void
    let cancel: () -> Void
    let commit: () -> Bool
    func validateDrop(info: DropInfo) -> Bool { allowed() }
    func dropEntered(info: DropInfo) { if allowed() { preview(info.location) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard allowed() else { return DropProposal(operation: .cancel) }
        preview(info.location); return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { cancel() }
    func performDrop(info: DropInfo) -> Bool { allowed() && commit() }
}
#endif
