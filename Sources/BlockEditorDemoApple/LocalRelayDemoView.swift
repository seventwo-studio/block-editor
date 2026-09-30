#if canImport(SwiftUI)
import BlockEditorApple
import BlockEditorLocalDemo
import SwiftUI

/// Embed in an Apple demo application's scene. No account or cloud service is used.
@MainActor public struct LocalRelayDemoView: View {
    @State private var endpoint = "http://127.0.0.1:4319/rooms/shared-demo"
    @State private var token = ""
    @State private var attempt = 0
    @State private var online = true
    @State private var model: EditorModel?
    @State private var client: LocalRelayClient?
    @State private var status = "Enter the local server address and token."
    @State private var saveStatus = ""

    public init(endpoint: URL? = nil) {
        if let endpoint { _endpoint = State(initialValue: endpoint.absoluteString) }
    }
    public var body: some View {
        VStack(alignment: .leading) {
            SecureField("Local demo token", text: $token)
                .onChange(of: token) { _, value in client?.setToken(value) }
            if let model {
                Toggle("Connected to local server", isOn: $online)
                    .onChange(of: online) { _, value in client?.setConnected(value) }
                Text(status).accessibilityLabel("Synchronization: \(status)")
                Text(saveStatus)
                BlockEditorView(model: model)
            } else {
                TextField("Server room URL", text: $endpoint)
                Button("Open editor") { attempt += 1 }
                Text(status)
            }
        }
        .padding()
        .task(id: attempt) {
            guard attempt > 0, let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? "") else { return }
            do {
                status = "Opening…"
                let key = "BlockEditorLocalDraft:\(url.absoluteString)"
                let stored = UserDefaults.standard.string(forKey: key)
                let identifier = stored.flatMap(UUID.init(uuidString:)) ?? UUID()
                UserDefaults.standard.set(identifier.uuidString, forKey: key)
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("BlockEditorLocalLab", isDirectory: true)
                let draft = try LocalDraft(file: root.appendingPathComponent(identifier.uuidString + ".json"))
                let opened: LocalRelayClient
                if let restored = try draft.restore(endpoint: url) {
                    opened = LocalRelayClient(session: restored, endpoint: url, token: token)
                    opened.setConnected(false); online = false
                } else {
                    guard !token.isEmpty else { throw RelayError.rejected("Enter the local relay token to open a new draft.") }
                    opened = try await LocalRelayClient.open(endpoint: url, token: token)
                    online = true
                }
                try Task.checkCancellation()
                try draft.save(opened.session, endpoint: url); saveStatus = "Saved locally"
                client = opened; model = try EditorModel(session: opened.session)
                model?.onChange = { _, _ in
                    do { try draft.save(opened.session, endpoint: url); saveStatus = "Saved locally" }
                    catch { saveStatus = "Local save failed: \(error)" }
                }
                defer { opened.setConnected(false); client = nil; model = nil }
                while !Task.isCancelled {
                    if online {
                        do {
                            try await opened.exchange()
                            status = "Connected; \(opened.pendingChanges) unacknowledged changes; \(opened.peers.count) other clients"
                        } catch { status = "Retrying: \(error)" }
                    } else { status = "Offline; local draft recovery is available" }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError { }
            catch { status = String(describing: error) }
        }
    }
}
#endif
