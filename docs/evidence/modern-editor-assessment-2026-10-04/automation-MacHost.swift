import BlockEditorDemoApple
import SwiftUI
@main struct AssessmentHost: App {
var localFile: URL? { guard let value = ProcessInfo.processInfo.environment["EDITOR_LAB_LOCAL_DOCUMENT"], let id = UUID(uuidString: value) else { return nil }; return FileManager.default.temporaryDirectory.appendingPathComponent("editor-ui-\(id.uuidString).json") }
var body: some Scene { WindowGroup { EditorDemoView(localFile: localFile).frame(minWidth: 700, minHeight: 500) } }
}
