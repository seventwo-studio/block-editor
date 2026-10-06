import BlockEditorApple
import BlockEditorCore
import SwiftUI

/// Local reference integration. Foliostrate supplies authorization, asset
/// providers and its own save schedule around the same public host boundaries.
public struct ModernEditorDemoView: View {
    private let file: URL
    private let documentID: String
    private let actorID: String
    @State private var model: ModernEditorModel?
    @State private var persistence: ModernPersistenceController?
    @State private var release: (() throws -> Void)?
    @State private var failure: String?
    @State private var status = "Local modern editor"
    public init(file: URL, documentID: String = "modern-help-example", actorID: String = "reference-author") {
        self.file = file; self.documentID = documentID; self.actorID = actorID
    }
    public var body: some View {
        VStack(spacing: 0) {
            if let model {
                HStack {
                    Text(status).font(.caption)
                    Spacer()
                    Button("Save locally") { Task { do { try await persistence?.save(); status = "Saved with recovery and author history" } catch { failure = String(describing: error) } } }
                    if release != nil { Button("Resume saved peer packets") { do { try release?(); release = nil } catch { failure = String(describing: error) } } }
                }.padding(8)
                ModernBlockEditorView(model: model, host: ModernEditorHostActions(openReference: { status = "Application navigation: \($0)" }, copyBlockLink: { status = "Application copy-link request: \($0)" }))
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            } else if let failure { VStack { Text("The saved editor could not open. \(failure)"); Button("Retry opening") { Task { await open() } } }.padding() }
            else { ProgressView("Opening modern editor…").task { await open() } }
        }.onDisappear { model?.isActive = false }
    }
    @MainActor private func open() async {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = ModernHostStore(url: file, documentID: documentID, actorID: actorID)
            let model: ModernEditorModel, revision: UUID?
            if let checkpoint = try await store.load() {
                let restored = try checkpoint.restore()
                model = ModernEditorModel(session: restored.session, pendingInputs: restored.pendingInputs, retainedClipboard: restored.retainedClipboard)
                release = { try restored.resumeDeferredChanges() }; revision = checkpoint.revision
                // Failed native buffers stay available in the checkpoint. An
                // application presents explicit recovery before forgetting them.
                if !checkpoint.pendingInputs.isEmpty { status = "\(checkpoint.pendingInputs.count) retained input buffers require recovery" }
            } else {
                let session = try ModernSession(documentID: documentID, actorID: actorID, epoch: UUID().uuidString,
                    document: ModernDocument(documentID: documentID, title: "Help", blocks: [
                        ModernInsertionCatalog.block("paragraph", id: "welcome"),
                        ModernInsertionCatalog.block("heading1", id: "section"),
                        ModernInsertionCatalog.block("table", id: "table", childIDs: ["r1", "c1", "c2", "r2", "c3", "c4"]),
                        ModernInsertionCatalog.block("code", id: "code")]))
                model = ModernEditorModel(session: session); revision = nil
            }
            persistence = ModernPersistenceController(model: model, store: store, loadedRevision: revision)
            self.model = model; failure = nil
        } catch { failure = String(describing: error) }
    }
}
