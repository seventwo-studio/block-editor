// Standalone acceptance host; compile separately from the package test targets.
// All input is delivered through Computer Use. Telemetry observes this app only
// and supplements successful UI captures; it does not replace them.
#if os(macOS)
import AppKit
import BlockEditorApple
import BlockEditorCore
import Observation
import SwiftUI

@MainActor @Observable final class IdentityFocusState {
    let model: EditorModel
    var phase = "Focus ORIGINAL, then schedule the remote move."
    var originLocation = "left"
    var nativeFocus = "No text view is focused"
    @ObservationIgnored private let local: EditorSession
    @ObservationIgnored private let remote: EditorSession
    @ObservationIgnored private let original: NodeID
    @ObservationIgnored private var replacement: NodeID?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRecord: Data?
    @ObservationIgnored private let directory: URL

    init() {
        do {
            let child = try Block.paragraph(id: "p", text: "ORIGINAL")
            let left = try Block(fields: ["id": .string("left"), "type": .string("toggle"),
                "summary": .array([.object(["type": .string("text"), "text": .string("LEFT")])]),
                "children": .array([.object(child.fields)])])
            let right = try Block(fields: ["id": .string("right"), "type": .string("toggle"),
                "summary": .array([.object(["type": .string("text"), "text": .string("RIGHT")])]),
                "children": .array([])])
            let document = try Document(blocks: [left, right])
            let documentID = "st45-focus-" + UUID().uuidString
            local = try EditorSession(documentID: documentID, actorID: "local", document: document, collaborationVersion: 2)
            remote = try EditorSession(documentID: documentID, actorID: "remote", document: document, collaborationVersion: 2)
            original = try local.node(at: NodeAddress("left", path: ["children", "p"]))
            model = try EditorModel(session: local)
            guard let configured = Bundle.main.object(forInfoDictionaryKey: "ST45FocusEvidenceDirectory") as? String else {
                fatalError("Set an issue-owned ST45FocusEvidenceDirectory in the test bundle")
            }
            directory = URL(fileURLWithPath: configured).appendingPathComponent(documentID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model.onChange = { [weak self] _, _ in self?.record() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
            record()
        } catch { fatalError("Isolated identity host initialization failed: \(error)") }
    }

    func scheduleMove() {
        guard moveTask == nil, replacement == nil else { return }
        phase = "Remote move scheduled in 45 seconds. Return to ORIGINAL and type or compose."
        moveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            self?.receiveMove()
        }
        record()
    }

    private func receiveMove() {
        do {
            let target = try remote.node(at: NodeAddress("left", path: ["children", "p"]))
            try remote.moveNode(target, into: NodeCollection(owner: remote.node(at: NodeAddress("right")), field: "children"))
            replacement = try remote.insertNode(.object(Block.paragraph(id: "p", text: "REPLACEMENT").fields),
                into: NodeCollection(owner: remote.node(at: NodeAddress("left")), field: "children"))
            try local.receive(remote.changes())
            phase = "Remote batch submitted. Check focus and subsequent typing; composition may defer acceptance."
        } catch { phase = "Remote command failed: \(error)" }
        moveTask = nil
        record()
    }

    private func text(of node: NodeID) -> String {
        (try? local.text(at: local.textAddress(of: node))) ?? "Unavailable"
    }

    func record() {
        let textView = NSApp.keyWindow?.firstResponder as? NSTextView
        let location = (try? local.address(of: original).blockID) ?? "Unavailable"
        if originLocation != location { originLocation = location }
        let focus = textView.map { $0.string } ?? "No text view is focused"
        if nativeFocus != focus { nativeFocus = focus }
        let state: JSONValue = .object([
            "documentID": .string(local.documentID),
            "librarySourceTree": .string(Bundle.main.object(forInfoDictionaryKey: "ST45LibrarySourceTree") as? String ?? "Unqualified"),
            "phase": .string(phase),
            "originalNode": .string(String(describing: original)),
            "originalLocation": .string(location),
            "originalText": .string(text(of: original)),
            "replacementNode": replacement.map { .string(String(describing: $0)) } ?? .null,
            "replacementText": replacement.map { .string(text(of: $0)) } ?? .null,
            "focusedNativeText": textView.map { .string($0.string) } ?? .null,
            "nativeSelection": textView.map { .string(NSStringFromRange($0.selectedRange())) } ?? .null,
            "hasMarkedText": .bool(textView?.hasMarkedText() ?? false),
            "nativeMarkedRange": textView.map { .string(NSStringFromRange($0.markedRange())) } ?? .null,
            "modelError": model.error.map(JSONValue.string) ?? .null
        ])
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            if data != lastRecord {
                try data.write(to: directory.appendingPathComponent("latest-state.json"), options: .atomic)
                try local.save().write(to: directory.appendingPathComponent("accepted-snapshot.json"), options: .atomic)
                let history = directory.appendingPathComponent("events.jsonl")
                if !FileManager.default.fileExists(atPath: history.path) {
                    _ = FileManager.default.createFile(atPath: history.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: history)
                defer { try? handle.close() }
                encoder.outputFormatting = [.sortedKeys]
                let event: JSONValue = .object(["time": .string(ISO8601DateFormatter().string(from: Date())), "state": state])
                try handle.seekToEnd()
                try handle.write(contentsOf: encoder.encode(event))
                try handle.write(contentsOf: Data([10]))
                lastRecord = data
            }
        } catch { phase = "Evidence persistence failed: \(error)" }
    }
}

@MainActor final class IdentityFocusDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor @main struct MacIdentityFocus: App {
    @NSApplicationDelegateAdaptor(IdentityFocusDelegate.self) private var delegate
    @State private var state = IdentityFocusState()
    var body: some Scene {
        WindowGroup("ST-45 merged-source identity acceptance") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Move ORIGINAL and reuse its old label in 45 seconds") { state.scheduleMove() }
                    .disabled(state.phase.hasPrefix("Remote"))
                Text(state.phase).font(.callout)
                Text("Original location: \(state.originLocation)")
                Text("Focused native text: \(state.nativeFocus)").lineLimit(2).font(.caption)
                Divider()
                BlockEditorView(model: state.model)
            }.padding().frame(minWidth: 720, minHeight: 560)
        }
    }
}
#endif
