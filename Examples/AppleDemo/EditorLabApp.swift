import BlockEditorDemoApple
import SwiftUI

@main struct EditorLabApp: App {
    private var localFile: URL? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["EDITOR_LAB_LOCAL_DOCUMENT"],
           let id = UUID(uuidString: value) {
            return FileManager.default.temporaryDirectory.appendingPathComponent("editor-ui-\(id.uuidString).json")
        }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup { EditorDemoView(localFile: localFile) }
    }
}
