#if os(macOS)
import AppKit
import BlockEditorApple
import BlockEditorCore
import SwiftUI

/// Compile-only qualification is distinct from real keyboard/IME acceptance.
@main struct MacWritingInputHost: App {
    @State private var model: WritingEditorModel
    private let peer: WritingSession
    init() {
        do {
            let document = try Document(blocks: [
                .paragraph(id: "p", text: "AB"),
                Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("item"), "content": .array([textNode("Checklist")]), "checked": .bool(false)])])]),
                Block(fields: ["id": .string("toggle"), "type": .string("toggle"), "summary": .array([textNode("Details")]), "children": .array([])])
            ])
            let session = try WritingSession(documentID: "native-acceptance", actorID: "apple", epoch: "writing-v4", document: document, protocolVersion: 4)
            peer = try WritingSession(documentID: "native-acceptance", actorID: "peer", epoch: "writing-v4", document: document, protocolVersion: 4)
            _model = State(initialValue: try WritingEditorModel(session: session))
        } catch { fatalError(String(describing: error)) }
    }
    var body: some Scene {
        WindowGroup("Shared writing input acceptance") {
            VStack {
                HStack {
                    Toggle("Editing allowed", isOn: Binding(get: { model.isEditable }, set: { model.isEditable = $0 }))
                    Button("Peer append R") {
                        do {
                            try peer.receive(model.session.changes())
                            let address = TextAddress("p"), count = try peer.text(at: address).utf16.count
                            try peer.replaceText(at: address, range: count..<count, with: "R")
                            try model.session.receive(peer.changes())
                        } catch { print("Acceptance peer error: \(error)") }
                    }
                    Text("Pending native drafts: \(model.pendingDrafts.count)")
                }
                WritingBlockEditorView(model: model)
                Text(model.document.blocks.map { "\($0.type): \($0.text)" }.joined(separator: " | "))
                    .accessibilityLabel("Shared document state")
            }.padding().frame(minWidth: 700, minHeight: 500)
        }
    }
}
#endif
