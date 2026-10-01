import Foundation

public enum MergeRecoveryReason: String, Codable, Sendable {
    case identityConflict, schemaConstraint
}

/// A canonical rejected union. It is transport state, never applied history or a receipt.
/// Hosts retain this separately from save() and re-submit its batch after restart.
public struct MergeRecovery: Codable, Equatable, Sendable {
    public let reason: MergeRecoveryReason
    public let batch: ChangeBatch
    public init(reason: MergeRecoveryReason, batch: ChangeBatch) { self.reason = reason; self.batch = batch }
}

/// Explicit host-selected repairs; permissions remain at the host/service boundary.
/// These operations preserve existing labels and use ordinary v2 changes on the wire.
public enum MergeRepair: Codable, Equatable, Sendable {
    case move(identity: NodeID, collection: NodeCollection)
    /// Introduce a host-chosen root container and move the original node into it.
    case wrap(identity: NodeID, container: Block, field: String)
    /// Reconcile a required field without replacing surviving atoms or marks.
    case text(identity: NodeID, field: String, text: String)
}
