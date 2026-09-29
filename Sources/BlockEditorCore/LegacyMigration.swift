import Foundation

/// Explicit cutover from a reviewed legacy materialized document. The old operation
/// archive remains host-owned evidence; it cannot be merged into protocol v1.
public enum LegacyMigration {
    public static func importDocument(_ json: Data, newDocumentID: String, actorID: String) throws -> EditorSession {
        try EditorSession(documentID: newDocumentID, actorID: actorID, document: Document(json: json))
    }
}
