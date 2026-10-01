import Foundation

/// Persist this archive before activation. Legacy undo remains in the archived
/// snapshot; v3 starts a fresh author history with the original document ID.
public struct WritingCutoverArchive: Codable, Equatable, Sendable {
    public let acceptedSnapshot: Data
    public let pendingRecovery: MergeRecovery?
    public let unacknowledged: [ChangeBatch]
    public let reconciledSnapshot: Data
    public let epoch: String
    public init(acceptedSnapshot: Data, pendingRecovery: MergeRecovery? = nil, unacknowledged: [ChangeBatch] = [], reconciledSnapshot: Data, epoch: String) {
        self.acceptedSnapshot = acceptedSnapshot; self.pendingRecovery = pendingRecovery
        self.unacknowledged = unacknowledged; self.reconciledSnapshot = reconciledSnapshot; self.epoch = epoch
    }
}

extension ProtocolMigration {
    /// The host stops every legacy writer, reconciles all retained packets and
    /// durably stores the archive. These explicit acknowledgments are mandatory.
    public static func cutoverToV3(_ archive: WritingCutoverArchive, actorID: String, oldWritersStopped: Bool, archivePersisted: Bool, resetUndoAcknowledged: Bool) throws -> WritingSession {
        guard oldWritersStopped, archivePersisted, resetUndoAcknowledged,
              archive.unacknowledged.count <= 64,
              try canonicalEncoder().encode(archive).count <= 192_000_000 else { throw EditorError.invalidChange }
        let accepted = try EditorSession.restore(archive.acceptedSnapshot, actorID: actorID)
        let reconciled = try EditorSession.restore(archive.reconciledSnapshot, actorID: actorID)
        guard accepted.documentID == reconciled.documentID, accepted.baseline == reconciled.baseline,
              accepted.collaborationVersion == reconciled.collaborationVersion else { throw EditorError.differentDocument }
        let final = reconciled.changes()
        var finalChanges: [ChangeID: Change] = [:]
        for change in final.changes {
            guard finalChanges.updateValue(change, forKey: change.id) == nil else { throw EditorError.conflictingChange }
        }
        var inputs = archive.unacknowledged
        inputs.append(accepted.changes())
        if let pending = archive.pendingRecovery { inputs.append(pending.batch) }
        for input in inputs {
            guard input.documentID == accepted.documentID, input.version == accepted.collaborationVersion,
                  input.baseline == accepted.baseline else { throw EditorError.differentDocument }
            for change in input.changes {
                guard finalChanges[change.id] == change else { throw EditorError.invalidChange }
            }
        }
        // Replaying the complete reconciled legacy log validates any repair and
        // prevents a visible-document-only conversion from dropping offline input.
        return try WritingSession(documentID: accepted.documentID, actorID: actorID, epoch: archive.epoch, document: reconciled.document)
    }
}
