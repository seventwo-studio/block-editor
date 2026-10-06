import BlockEditorApple
import BlockEditorCore
import Observation
import SwiftUI

@MainActor @Observable final class CaptureController {
    static let shared = try! CaptureController()
    var model: EditorModel
    init() throws {
        let fixture = Bundle.main.url(forResource: "rich-blocks", withExtension: "json")!
        let document = try Document(json: Data(contentsOf: fixture))
        model = try EditorModel(session: EditorSession(documentID: "ST116-vision-capture", actorID: "assessment", document: document, collaborationVersion: 2))
    }
}
@main struct AssessmentVisionHost: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading) {
                Text("ST116 native visionOS model capture")
                BlockEditorView(model: CaptureController.shared.model)
            }.padding().frame(minWidth: 700, minHeight: 500)
        }
    }
}
