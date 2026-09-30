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
    private var relayEndpoint: URL? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["EDITOR_LAB_RELAY_ENDPOINT"],
           let url = URL(string: value), ["localhost", "127.0.0.1"].contains(url.host ?? "") {
            return url
        }
        #endif
        return nil
    }
    var body: some Scene {
        WindowGroup { EditorDemoView(localFile: localFile, relayEndpoint: relayEndpoint) }
    }
}
