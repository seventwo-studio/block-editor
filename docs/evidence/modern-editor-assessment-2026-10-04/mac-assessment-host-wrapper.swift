#if os(macOS)
import BlockEditorDemoApple
import SwiftUI
import Foundation

@main struct LocalEditorDemoApp: App {
    var body: some Scene {
        WindowGroup("Local editor lab") {
            EditorDemoView(localFile: URL(fileURLWithPath: "/private/tmp/block-editor-native-assessment-ntz96ybc/mac-assessment-document.json")).frame(minWidth: 480, minHeight: 400)
        }
    }
}
#else
@main struct LocalEditorDemoApp {
    static func main() { print("Embed LocalRelayDemoView in the platform application's SwiftUI scene.") }
}
#endif
