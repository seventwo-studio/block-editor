#if canImport(SwiftUI)
import BlockEditorApple
import BlockEditorLocalDemo
import Observation
import SwiftUI

@MainActor @Observable private final class StandaloneDocument {
    let model: EditorModel
    var status = "Saved locally"
    private let draft: LocalDraft
    init(file: URL) throws {
        draft = try LocalDraft(file: file)
        model = try EditorModel(session: draft.openLocalDocument())
        model.onChange = { [weak self] _, _ in self?.save() }
    }
    private func save() {
        do { try draft.saveLocalDocument(model.session); status = "Saved locally" }
        catch { status = "Local save failed: \(error)" }
    }
}

/// A standalone editor that never creates a network client.
@MainActor public struct LocalEditorDemoView: View {
    @State private var document: StandaloneDocument?
    @State private var status = "Opening local document…"
    private let file: URL?

    /// Hosts may choose a different local file for each document.
    public init(file: URL? = nil) { self.file = file }

    public var body: some View {
        VStack(alignment: .leading) {
            Text("Local document")
            Text(document?.status ?? status)
            if let document { BlockEditorView(model: document.model) }
        }
        .padding()
        .task {
            guard document == nil else { return }
            do {
                let url: URL
                if let file { url = file }
                else {
                    url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                        .appendingPathComponent("BlockEditorLocalLab/local-only.json")
                }
                document = try StandaloneDocument(file: url)
            } catch { status = "Could not open local document: \(error)" }
        }
    }
}

/// Choose a standalone document or the local collaboration lab explicitly.
@MainActor public struct EditorDemoView: View {
    private enum Mode { case local, collaborative }
    @State private var mode: Mode?
    private let localFile: URL?
    public init(localFile: URL? = nil) { self.localFile = localFile }
    public var body: some View {
        switch mode {
        case .local: LocalEditorDemoView(file: localFile)
        case .collaborative: LocalRelayDemoView()
        case nil:
            VStack(alignment: .leading, spacing: 16) {
                Button("Open local document") { mode = .local }
                Text("Create or reopen a document on this device. No server or account is needed.")
                Button("Open collaborative lab") { mode = .collaborative }
                Text("Connect to a local relay to test simultaneous and offline editing.")
            }.padding()
        }
    }
}
#endif
