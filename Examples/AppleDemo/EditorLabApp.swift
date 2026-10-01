import BlockEditorDemoApple
import BlockEditorCore
import BlockEditorLocalDemo
import SwiftUI

@main struct EditorLabApp: App {
    private var localFile: URL? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["EDITOR_LAB_LOCAL_DOCUMENT"],
           let id = UUID(uuidString: value) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("editor-ui-\(id.uuidString).json")
            if ProcessInfo.processInfo.environment["EDITOR_LAB_FIXTURE"] == "rich-blocks",
               !FileManager.default.fileExists(atPath: file.path) {
                do {
                    guard let fixture = Bundle.main.url(forResource: "rich-blocks", withExtension: "json") else {
                        preconditionFailure("Missing rich-blocks UI fixture")
                    }
                    let document = try BlockEditorCore.Document(json: Data(contentsOf: fixture))
                    let draft = try LocalDraft(file: file)
                    try draft.saveLocalDocument(EditorSession(documentID: id.uuidString, actorID: UUID().uuidString, document: document))
                } catch { preconditionFailure("Cannot create rich-blocks UI fixture: \(error)") }
            }
            return file
        }
        #endif
        return nil
    }
    private var relayEndpoint: URL? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["EDITOR_LAB_RELAY_ENDPOINT"],
           let url = URL(string: value), ["localhost", "127.0.0.1"].contains(url.host ?? "") {
            // A reserved UI campaign resumes only its seeded draft, without
            // replacing other writers or relying on external preference caches.
            if let value = ProcessInfo.processInfo.environment["EDITOR_LAB_RESUME_DRAFT"],
               let identifier = UUID(uuidString: value) {
                UserDefaults.standard.set(identifier.uuidString, forKey: "BlockEditorLocalDraft:\(url.absoluteString)")
            }
            return url
        }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup { EditorDemoView(localFile: localFile, relayEndpoint: relayEndpoint) }
    }
}
