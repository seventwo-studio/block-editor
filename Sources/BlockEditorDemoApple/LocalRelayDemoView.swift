#if canImport(SwiftUI)
import BlockEditorApple
import BlockEditorCore
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
    @State private var recovery: MergeRecovery?
    @State private var exportRecovery: (() throws -> URL)?
    @State private var retryLocalSave: (() -> Void)?
    @State private var saveFailed = false
    @State private var capacityBytes: Int?
    @State private var capacityArchive: URL?
    @State private var capacityExportError: String?

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
                if saveFailed {
                    Button("Retry local save") { retryLocalSave?() }
                        .accessibilityIdentifier("retry-local-save")
                }
                if capacityBytes != nil || saveFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        if let capacityBytes {
                            Text("Synchronization needs a larger transport").font(.headline)
                                .accessibilityIdentifier("transport-capacity")
                            Text("The relay limit is \(capacityBytes) bytes. Your complete local history remains unacknowledged. Export before changing transport or arranging a cutover.")
                        }
                        Button("Export retained history") {
                            do {
                                guard let exportRecovery else { throw DraftError.storageUnavailable }
                                capacityArchive = try exportRecovery(); capacityExportError = nil
                            }
                            catch { capacityExportError = String(describing: error) }
                        }.accessibilityIdentifier("export-retained-history")
                        if capacityBytes != nil {
                            Button("Retry synchronization") { online = true; client?.setConnected(true) }
                        }
                        if let capacityArchive {
                            Text("Retained history saved locally").accessibilityIdentifier("retained-history-exported")
                            #if os(iOS) || os(macOS) || os(visionOS)
                            ShareLink("Share retained history", item: capacityArchive)
                            #endif
                        }
                        if let capacityExportError { Text("Export failed: \(capacityExportError)").foregroundStyle(.red) }
                    }
                }
                if let recovery {
                    ScrollView {
                        MergeRecoveryView(recovery: recovery,
                        canWrap: model.session.allowedBlockTypes.map { $0.contains("toggle") } ?? true,
                        repair: { identity in
                            model.perform { session in
                                let container = try Block(fields: ["id": .string(UUID().uuidString), "type": .string("toggle"),
                                    "summary": .array([.object(["type": .string("text"), "text": .string("Recovered block"), "marks": .array([])])]),
                                    "children": .array([])])
                                try session.repairMerge([.wrap(identity: identity, container: container, field: "children")])
                            }
                            self.recovery = model.session.mergeRecovery
                        }, export: {
                            guard let exportRecovery else { throw DraftError.storageUnavailable }
                            return try exportRecovery()
                        }, retry: { online = true; client?.setConnected(true) })
                    }.frame(maxHeight: 360)
                }
                BlockEditorView(model: model)
                    .disabled(recovery != nil)
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
                try draft.save(opened.session, endpoint: url); saveStatus = "Saved locally"; saveFailed = false
                client = opened; model = try EditorModel(session: opened.session)
                recovery = opened.session.mergeRecovery
                exportRecovery = {
                    let archive = root.appendingPathComponent("recovery-\(UUID().uuidString).json")
                    try draft.exportRecovery(opened.session, endpoint: url, to: archive)
                    return archive
                }
                let persist = {
                    do {
                        try draft.save(opened.session, endpoint: url)
                        saveStatus = "Saved locally"; saveFailed = false
                    } catch {
                        saveStatus = "Local save failed: \(error). Retry or export before closing."
                        saveFailed = true
                    }
                }
                retryLocalSave = persist
                opened.onStatus = {
                    capacityBytes = opened.transportCapacityBytes
                    guard recovery != opened.session.mergeRecovery else { return }
                    recovery = opened.session.mergeRecovery
                    persist()
                }
                model?.onChange = { _, _ in
                    capacityArchive = nil
                    recovery = opened.session.mergeRecovery
                    persist()
                }
                defer {
                    opened.onStatus = nil; opened.setConnected(false); client = nil; model = nil
                    recovery = nil; exportRecovery = nil; retryLocalSave = nil; saveFailed = false
                    capacityBytes = nil; capacityArchive = nil; capacityExportError = nil
                }
                while !Task.isCancelled {
                    if online {
                        do {
                            try await opened.exchange()
                            status = "Connected; \(opened.pendingChanges) unacknowledged changes; \(opened.peers.count) other clients"
                        } catch {
                            status = opened.session.mergeRecovery != nil ? "Synchronization paused for recovery"
                                : "Retrying: \(opened.lastError ?? String(describing: error))"
                        }
                    } else { status = "Offline; local draft recovery is available" }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError { }
            catch { status = String(describing: error) }
        }
    }
}
#endif
