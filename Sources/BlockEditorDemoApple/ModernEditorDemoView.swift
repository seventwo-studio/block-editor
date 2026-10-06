import BlockEditorApple
import BlockEditorCore
import SwiftUI
import UniformTypeIdentifiers

/// Local reference integration. Foliostrate supplies authorization, asset
/// providers and its own save schedule around the same public host boundaries.
public struct ModernEditorDemoView: View {
    private let file: URL
    private let documentID: String
    private let actorID: String
    @State private var model: ModernEditorModel?
    @State private var persistence: ModernPersistenceController?
    #if os(macOS) || os(iOS) || os(visionOS)
    @State private var assets: ModernExampleAssets?
    @State private var providers: ModernProviderController?
    @State private var importing = false
    @State private var previewURL = ""
    #endif
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
                #if os(macOS) || os(iOS) || os(visionOS)
                ModernBlockEditorView(model: model, host: ModernEditorHostActions(openReference: { status = "Application navigation: \($0)" }, suggestLinks: { query in
                    [ModernEditorLinkSuggestion(id: "getting-started", entityType: "help", label: "Getting started")].filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
                }, copyBlockLink: { status = "Application copy-link request: \($0)" }, resolveMedia: { _, value in
                    if let file = assets?.resolve(value) { return .available(file) }
                    return .unavailable("Application has no local asset for this reference")
                }, insertAssetSelection: { descriptor, boundary, range in
                    guard let assets else { return }; let generation = model.invocationGeneration
                    Task { @MainActor in do {
                        var metadata = try await assets.choose(kind: descriptor.blockType)
                        guard model.isActive, model.isEditable, generation == model.invocationGeneration else { throw ModernSessionError.unavailable("originalDocumentInactive") }
                        metadata["id"] = .string(UUID().uuidString); metadata["type"] = .string(descriptor.blockType)
                        if descriptor.blockType == "image" { metadata["caption"] = .array([]) }
                        try model.perform { try $0.paste(ModernClipboard(parts: [.node(value: .object(metadata), kind: "block")]), at: range.map { .init(range: $0) } ?? .init(boundary: boundary), policy: WritingPastePolicy(allowAssetMetadata: true)).focus }
                        try await persistence?.save()
                    } catch { failure = String(describing: error) } }
                }), providers: providers)
                .onChange(of: assets?.request?.id) { _, _ in
                    if let kind = assets?.request?.kind, kind != "embed" { importing = true }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: assets?.request?.kind == "image" ? [.image] : [.data]) { result in
                    switch result { case .success(let url): assets?.importFile(url); case .failure: assets?.cancel() }
                }
                .sheet(isPresented: Binding(get: { assets?.request?.kind == "embed" }, set: { if !$0 { assets?.cancel() } })) {
                    VStack { TextField("Preview URL", text: $previewURL); Button("Use preview") { assets?.finish(["url": .string(previewURL), "title": .string(previewURL)]) }; Button("Cancel") { assets?.cancel() } }.padding()
                }
                #else
                ModernBlockEditorView(model: model)
                #endif
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            } else if let failure { VStack { Text("The saved editor could not open. \(failure)"); Button("Retry opening") { Task { await open() } } }.padding() }
            else { ProgressView("Opening modern editor…").task { await open() } }
        }.onDisappear { model?.isActive = false
            #if os(macOS) || os(iOS) || os(visionOS)
            assets?.cancel()
            #endif
        }
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
            #if os(macOS) || os(iOS) || os(visionOS)
            let assetHost = ModernExampleAssets(directory: file.deletingLastPathComponent().appendingPathComponent("modern-assets"))
            assets = assetHost
            if let persistence { providers = ModernProviderController(persistence: persistence, provider: { target in try await assetHost.choose(kind: target.origin.kind.rawValue) }) }
            #endif
            self.model = model; failure = nil
        } catch { failure = String(describing: error) }
    }
}
