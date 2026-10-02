// Current shared-writing acceptance host. Native input is delivered through
// Computer Use; observing this app never substitutes for successful UI captures.
#if os(macOS)
import AppKit
import BlockEditorApple
import BlockEditorCore
import Observation
import SwiftUI

@MainActor @Observable final class WritingAcceptanceState {
    let protocolVersion: Int
    let model: WritingEditorModel
    var phase = "Focus ORIGINAL. Use the editor's native writing controls and system clipboard."
    var originalLocation = "left/children/p"
    var nativeFocus = "No focused text view"
    var archivedDrafts: [JSONValue] = []
    var archivedNativeObservations: [JSONValue] = []
    @ObservationIgnored private let peer: WritingSession
    @ObservationIgnored private let original: NodeID
    @ObservationIgnored private var replacement: NodeID?
    @ObservationIgnored private var recoveryPeer: WritingSession?
    @ObservationIgnored private var restartHold: (() throws -> Void)?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRecord: Data?

    init() {
        do {
            guard let version = Bundle.main.object(forInfoDictionaryKey: "WritingAcceptanceProtocol") as? Int,
                  [4, 5, 6].contains(version),
                  let configured = Bundle.main.object(forInfoDictionaryKey: "WritingAcceptanceDirectory") as? String,
                  let tree = Bundle.main.object(forInfoDictionaryKey: "WritingAcceptanceSourceTree") as? String,
                  tree.count == 40 else { throw EditorError.invalidChange }
            protocolVersion = version
            directory = URL(fileURLWithPath: configured).appendingPathComponent("protocol-\(version)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent("archive-state.json")
            let session: WritingSession
            if FileManager.default.fileExists(atPath: archive.path) {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: archive))
                guard value["protocol"] == .number(Double(version)), value["sourceTree"] == .string(tree) else { throw EditorError.invalidChange }
                session = try WritingSession.restore(Self.data(value["accepted"]), actorID: "apple")
                peer = try WritingSession.restore(Self.data(value["peerAccepted"]), actorID: "peer")
                guard session.protocolVersion == version, peer.protocolVersion == version,
                      session.documentID == peer.documentID, session.epoch == peer.epoch else { throw EditorError.invalidChange }
                original = try Self.decode(value["original"], NodeID.self)
                if let saved = value["replacement"], saved != .null { replacement = try Self.decode(saved, NodeID.self) }
                if let saved = value["recoveryPeerAccepted"], saved != .null {
                    recoveryPeer = try WritingSession.restore(Self.data(saved), actorID: "recovery-peer")
                }
                model = try WritingEditorModel(session: session)
                archivedDrafts = value["nativeDrafts"]?.array ?? []
                archivedNativeObservations = value["nativeUncommitted"]?.array ?? []
                // Recovery and deferred packets are restored separately from the
                // accepted snapshot. Expected recovery remains visibly pending.
                if let saved = value["pendingRecovery"], saved != .null {
                    do { try session.restoreRecovery(Self.data(saved)) }
                    catch let error as WritingSessionError {
                        guard case .recoveryRequired = error else { throw error }
                    }
                }
                let pending = try Self.decode(value["deferred"], [WritingBatch].self)
                if !pending.isEmpty { restartHold = session.deferRemoteChanges() }
                for batch in pending {
                    do { try session.receive(batch) }
                    catch let error as WritingSessionError {
                        guard case .recoveryRequired = error else { throw error }
                    }
                }
                phase = "Restart restored accepted history and separately retained pending material. Archived native drafts require explicit operator review."
            } else {
                let document = try Self.fixture()
                let id = "apple-writing-acceptance-" + UUID().uuidString
                session = try WritingSession(documentID: id, actorID: "apple", epoch: "acceptance-v\(version)", document: document, protocolVersion: version)
                peer = try WritingSession(documentID: id, actorID: "peer", epoch: session.epoch, document: document, protocolVersion: version)
                original = try session.node(at: NodeAddress("left", path: ["children", "p"]))
                model = try WritingEditorModel(session: session)
            }
            model.onChange = { [weak self] _, _ in self?.record() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
            record()
        } catch { fatalError("Acceptance host cannot restore or initialize without preserving its archive: \(error)") }
    }

    private static func fixture() throws -> BlockEditorCore.Document {
        let rich: [JSONValue] = [textNode("ORIGINAL café 東京😀", marks: [.object(["type": .string("italic")])]),
            .object(["type": .string("entity-ref"), "entityType": .string("task"), "entityId": .string("task-acceptance"), "label": .string("TASK"), "consumer": .object(["opaque": .string("keep")])])]
        let child = try Block(fields: ["id": .string("p"), "type": .string("paragraph"), "content": .array(rich), "consumer": .object(["opaque": .string("ORIGINAL")])])
        let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"), "summary": .array([textNode("LEFT")]), "children": .array([.object(child.fields)])])
        let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"), "summary": .array([textNode("RIGHT")]), "children": .array([])])
        let list = try Block(fields: ["id": .string("list"), "type": .string("list"), "style": .string("todo"), "items": .array([.object(["id": .string("item"), "content": .array([textNode("Checklist")]), "checked": .bool(false)])])])
        let math = try Block(fields: ["id": .string("math"), "type": .string("math"), "expression": .string("AB"), "consumer": .object(["opaque": .string("MATH")])])
        return try Document(blocks: [left, right, list, math])
    }

    func scheduleMove() {
        guard task == nil, replacement == nil else { return }
        phase = "Move scheduled in 45 seconds. Return to ORIGINAL and compose with the installed input source."
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self else { return }
            self.action("Peer moved ORIGINAL and reused its old label") {
                try self.peer.receive(self.model.session.changes())
                let right = try self.peer.node(at: NodeAddress("right"))
                try self.peer.move(WritingSelection(nodes: [self.original]), into: NodeCollection(owner: right, field: "children"))
                let left = try self.peer.node(at: NodeAddress("left"))
                let inserted = try self.peer.insertCollectionNodes([.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields)], into: NodeCollection(owner: left, field: "children"))
                self.replacement = inserted.nodes.first
                try self.model.session.receive(self.peer.changes())
            }
            self.task = nil
        }
        record()
    }

    func scheduleAppend() {
        guard task == nil else { return }
        phase = "Peer R scheduled in 15 seconds. Compose in ORIGINAL before it arrives."
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self else { return }
            self.action("Peer R submitted; inspect accepted/deferred state until native command commits composition") {
                try self.peer.receive(self.model.session.changes())
                let address = try self.peer.textAddress(of: self.original)
                let end = try self.peer.text(at: address).utf16.count
                try self.peer.replaceText(at: address, range: end..<end, with: "R")
                try self.model.session.receive(self.peer.changes())
            }
            self.task = nil
        }
        record()
    }

    func armRecovery() {
        action("Math race armed. In the real Math control delete A so accepted text is B, then submit peer deletion") {
            guard try model.session.text(at: TextAddress("math", path: ["expression"])) == "AB" else { throw EditorError.invalidRange }
            recoveryPeer = try WritingSession.restore(model.session.save(), actorID: "recovery-peer")
        }
    }
    func submitRecovery() {
        action("Peer required-field deletion submitted; inspect pending recovery without accepting an invalid document") {
            guard let recoveryPeer, try model.session.text(at: TextAddress("math", path: ["expression"])) == "B" else { throw EditorError.invalidRange }
            try recoveryPeer.replaceText(at: TextAddress("math", path: ["expression"]), range: 1..<2, with: "")
            try model.session.receive(recoveryPeer.changes())
        }
    }
    func failedRepair() {
        action("Empty repair attempt") {
            let node = try model.session.node(at: NodeAddress("math"))
            let before = try model.session.save(), pending = try model.session.exportRecovery()
            do {
                try model.session.repairText(node: node, field: "expression", text: "")
                throw EditorError.invalidChange
            } catch {
                guard try model.session.save() == before, try model.session.exportRecovery() == pending else { throw EditorError.invalidChange }
                throw error
            }
        }
    }
    func repair() {
        action("Explicit text repair admitted; every accepted and pending original change retained") {
            let node = try model.session.node(at: NodeAddress("math"))
            try model.session.repairText(node: node, field: "expression", text: "R")
        }
    }
    func retry() { action("Retried separately retained deferred changes") {
        if let release = restartHold { restartHold = nil; try release() }
        else { try model.session.retryDeferredChanges() }
    } }
    func checkpoint() { record(force: true) }

    private func action(_ success: String, _ operation: () throws -> Void) {
        do { try operation(); phase = success }
        catch { phase = "Action retained its failure: \(error)" }
        record(force: true)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    private static func decode<T: Decodable>(_ value: JSONValue?, _ type: T.Type) throws -> T {
        guard let value else { throw EditorError.invalidChange }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
    private static func data(_ value: JSONValue?) throws -> Data {
        guard let text = value?.string, let data = Data(base64Encoded: text) else { throw EditorError.invalidChange }
        return data
    }

    func record(force: Bool = false) {
        do {
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
            let address = try? model.session.address(of: original)
            originalLocation = address.map { ([$0.blockID] + $0.path).joined(separator: "/") } ?? "Unavailable"
            nativeFocus = textView?.string ?? "No focused text view"
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let drafts = try model.pendingDrafts.map { id, draft in
                JSONValue.object(["id": .string(id.uuidString), "address": try Self.json(draft.address), "text": .string(draft.text),
                    "selection": .object(["location": .number(Double(draft.selection.location)), "length": .number(Double(draft.selection.length))]), "reason": .string(draft.reason)])
            }
            let archive: JSONValue = .object([
                "sourceTree": .string(Bundle.main.object(forInfoDictionaryKey: "WritingAcceptanceSourceTree") as? String ?? "Unqualified"),
                "protocol": .number(Double(protocolVersion)), "accepted": .string(try model.session.save().base64EncodedString()),
                "peerAccepted": .string(try peer.save().base64EncodedString()), "original": try Self.json(original),
                "replacement": try replacement.map { try Self.json($0) } ?? .null,
                "recoveryPeerAccepted": try recoveryPeer.map { .string(try $0.save().base64EncodedString()) } ?? .null,
                "deferred": try JSONDecoder().decode(JSONValue.self, from: model.session.exportDeferredChanges()),
                "pendingRecovery": try model.session.exportRecovery().map { .string($0.base64EncodedString()) } ?? .null,
                "nativeDrafts": .array(archivedDrafts + drafts),
                // A marked native draft may not yet be in model.pendingDrafts.
                // Preserve it as unbound operator evidence; never guess its owner
                // or silently replay it into the accepted document on restart.
                "nativeUncommitted": .array(archivedNativeObservations + (textView?.hasMarkedText() == true ? [.object([
                    "text": .string(textView!.string), "selection": .string(NSStringFromRange(textView!.selectedRange())),
                    "markedRange": .string(NSStringFromRange(textView!.markedRange())), "binding": .string("Unbound native observation; manual reconciliation required")
                ])] : []))
            ])
            let state: JSONValue = .object([
                "librarySourceTree": .string(Bundle.main.object(forInfoDictionaryKey: "WritingAcceptanceSourceTree") as? String ?? "Unqualified"),
                "protocol": .number(Double(protocolVersion)), "documentID": .string(model.session.documentID), "epoch": .string(model.session.epoch),
                "runtime": .string(ProcessInfo.processInfo.operatingSystemVersionString), "processPID": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "phase": .string(phase), "originalLocation": .string(originalLocation), "originalNode": try Self.json(original),
                "replacementNode": try replacement.map { try Self.json($0) } ?? .null,
                "originalText": .string((try? model.session.text(at: model.session.textAddress(of: original))) ?? "Unavailable"),
                "replacementText": replacement.map { .string((try? model.session.text(at: model.session.textAddress(of: $0))) ?? "Unavailable") } ?? .null,
                "focusedNativeText": textView.map { .string($0.string) } ?? .null,
                "nativeSelection": textView.map { .string(NSStringFromRange($0.selectedRange())) } ?? .null,
                "hasMarkedText": .bool(textView?.hasMarkedText() ?? false), "nativeMarkedRange": textView.map { .string(NSStringFromRange($0.markedRange())) } ?? .null,
                "receipt": try Self.json(model.session.syncState), "recovery": try Self.json(model.session.mergeRecovery),
                "modelError": model.error.map(JSONValue.string) ?? .null, "nativeDraftCount": .number(Double(archivedDrafts.count + drafts.count)),
                "archive": archive
            ])
            let data = try encoder.encode(state)
            guard force || data != lastRecord else { return }
            // The restart envelope is one atomic write: accepted and pending
            // portions cannot be mistaken for a single accepted snapshot.
            try encoder.encode(archive).write(to: directory.appendingPathComponent("archive-state.json"), options: .atomic)
            try data.write(to: directory.appendingPathComponent("latest-state.json"), options: .atomic)
            let log = directory.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: log.path) { _ = FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10]))
            lastRecord = data
        } catch { phase = "Evidence export failed; preserve this host and its last archive: \(error)" }
    }
}

@MainActor final class WritingAcceptanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor @main struct MacWritingInputHost: App {
    @NSApplicationDelegateAdaptor(WritingAcceptanceDelegate.self) private var delegate
    @State private var state = WritingAcceptanceState()
    var body: some Scene {
        WindowGroup("Shared writing v\(state.protocolVersion) input acceptance") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Actual input / composition / Enter / soft break / formatting / copy and paste use the full editor below.").font(.caption)
                HStack {
                    Toggle("Editing allowed", isOn: Binding(get: { state.model.isEditable }, set: { state.model.isEditable = $0 }))
                    Button("Move ORIGINAL + reuse label in 45s") { state.scheduleMove() }
                    Button("Peer R in 15s") { state.scheduleAppend() }
                    Button("Checkpoint accepted + pending") { state.checkpoint() }
                }
                HStack {
                    Button("Arm math race") { state.armRecovery() }
                    Button("Peer delete B") { state.submitRecovery() }
                    Button("Try empty repair") { state.failedRepair() }
                    Button("Repair expression to R") { state.repair() }
                    Button("Retry deferred") { state.retry() }
                }
                Text(state.phase).accessibilityLabel("Acceptance phase")
                Text("ORIGINAL: \(state.originalLocation) | Native focus: \(state.nativeFocus)").lineLimit(2).font(.caption)
                WritingBlockEditorView(model: state.model)
                Text(state.model.document.blocks.map { "\($0.type): \($0.text)" }.joined(separator: " | "))
                    .accessibilityLabel("Shared document state")
                Text("Archived drafts: \(state.archivedDrafts.count), marked native observations: \(state.archivedNativeObservations.count); live failed drafts: \(state.model.pendingDrafts.count). Untested families and accessibility remain open.").font(.caption)
            }.padding().frame(minWidth: 850, minHeight: 650)
        }
    }
}
#endif
