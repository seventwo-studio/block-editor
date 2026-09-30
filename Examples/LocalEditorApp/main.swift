#if os(macOS)
import BlockEditorDemoApple
import SwiftUI

@main struct LocalEditorDemoApp: App {
    var body: some Scene {
        WindowGroup("Local editor lab") {
            LocalRelayDemoView().frame(minWidth: 480, minHeight: 400)
        }
    }
}
#else
@main struct LocalEditorDemoApp {
    static func main() { print("Embed LocalRelayDemoView in the platform application's SwiftUI scene.") }
}
#endif
