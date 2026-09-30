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

    public init() {}
    public var body: some View {
        VStack(alignment: .leading) {
            if let model {
                Toggle("Connected to local server", isOn: $online)
                    .onChange(of: online) { _, value in client?.setConnected(value) }
                Text(status).accessibilityLabel("Synchronization: \(status)")
                BlockEditorView(model: model)
            } else {
                TextField("Server room URL", text: $endpoint)
                SecureField("Local demo token", text: $token)
                Button("Open editor") { attempt += 1 }.disabled(token.isEmpty)
                Text(status)
            }
        }
        .padding()
        .task(id: attempt) {
            guard attempt > 0, let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? "") else { return }
            do {
                status = "Opening…"
                let opened = try await LocalRelayClient.open(endpoint: url, token: token)
                try Task.checkCancellation()
                client = opened; model = try EditorModel(session: opened.session)
                defer { opened.setConnected(false); client = nil; model = nil }
                while !Task.isCancelled {
                    if online {
                        do {
                            try await opened.exchange()
                            status = "Connected; \(opened.pendingChanges) unacknowledged changes; \(opened.peers.count) other clients"
                        } catch { status = "Retrying: \(error)" }
                    } else { status = "Offline; edits remain on this client" }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError { }
            catch { status = String(describing: error) }
        }
    }
}
#endif
