import Foundation

/// A coordinated cutover materializes the old history into a new document baseline.
/// Hosts must stop old writers and archive their history first. Old undo transactions
/// are not reinterpreted as v2 operations; the new session starts a fresh history.
public enum ProtocolMigration {
    public static func cutoverToV2(_ snapshot: Data, newDocumentID: String, actorID: String) throws -> EditorSession {
        let old = try EditorSession.restore(snapshot, actorID: actorID)
        guard old.collaborationVersion == 1, newDocumentID != old.documentID else { throw EditorError.invalidChange }
        return try EditorSession(documentID: newDocumentID, actorID: actorID, document: old.document, collaborationVersion: 2)
    }
}
