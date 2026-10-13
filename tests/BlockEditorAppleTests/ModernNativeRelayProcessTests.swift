#if os(macOS)
import BlockEditorApple
import BlockEditorCore
import Foundation
import Testing

/// Actual URLSession and an independent relay/native bridge process. This is
/// transport/reopen evidence, not physical native-input or assistive acceptance.
@MainActor @Suite struct ModernNativeRelayProcessTests {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private final class Server {
        let process: Process
        let endpoint: URL
        private init(process: Process, endpoint: URL) { self.process = process; self.endpoint = endpoint }
        static func start(root: URL, repository: URL, document: ModernDocument) async throws -> Server {
            let ready = root.appendingPathComponent("ready-\(UUID()).json")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bun", "scripts/relay-process-fixture.ts"]; process.currentDirectoryURL = repository
            var environment = ProcessInfo.processInfo.environment
            let options: [String: Any] = ["executable": repository.appendingPathComponent(".build/debug/editor-bridge").path,
                "directory": root.appendingPathComponent("server-data").path, "token": "native-relay-test", "port": 0,
                "modern": ["document": try JSONSerialization.jsonObject(with: document.json()), "epoch": "native-process-epoch"]]
            environment["RELAY_PROCESS_OPTIONS"] = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
            environment["RELAY_READY_FILE"] = ready.path; process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
            try process.run()
            for _ in 0..<300 {
                if let bytes = try? Data(contentsOf: ready), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let url = value["url"] as? String, let endpoint = URL(string: url)?.appendingPathComponent("rooms").appendingPathComponent(document.documentID) {
                    return Server(process: process, endpoint: endpoint)
                }
                guard process.isRunning else { throw ModernNativeRelayError.rejected(status: Int(process.terminationStatus)) }
                try await Task.sleep(for: .milliseconds(50))
            }
            process.terminate(); throw ModernNativeRelayError.rejected(status: 504)
        }
        func stop() async throws {
            if process.isRunning { process.terminate() }
            for _ in 0..<300 {
                if !process.isRunning { #expect(process.terminationStatus == 0); return }
                try await Task.sleep(for: .milliseconds(50))
            }
            process.interrupt(); throw ModernNativeRelayError.rejected(status: 504)
        }
    }
    @Test func realHTTPReopensOfflineAndRejoinsAfterServerRestartWithWholeColumnsAndAuthorHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-modern-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try ModernDocument(json: Data(contentsOf: repository.appendingPathComponent("docs/acceptance/modern-editor/documents/columns-7000.json")))
        var server = try await Server.start(root: root, repository: repository, document: original)
        let storeA = ModernHostStore(url: root.appendingPathComponent("author-a.json"), documentID: original.documentID, actorID: "a")
        let storeB = ModernHostStore(url: root.appendingPathComponent("author-b.json"), documentID: original.documentID, actorID: "b")
        do {
            let a = try await ModernNativeRelayClient.open(store: storeA, endpoint: server.endpoint, relayKey: "native-room", token: "native-relay-test")
            let b = try await ModernNativeRelayClient.open(store: storeB, endpoint: server.endpoint, relayKey: "native-room", token: "native-relay-test")
            try a.persistence.model.session.replaceTitle(range: 0..<0, with: "Own ")
            try b.persistence.model.session.setAppearance(field: "fontFamily", value: "serif")
            _ = try b.persistence.model.session.resizeColumns(ModernColumnTarget(layout: b.persistence.model.session.node(at: NodeAddress("layout"))), splitBasisPoints: 3000)
            try await b.exchange(); try await a.exchange()
            var expectedFields = original.fields
            expectedFields["title"] = .string("Own Field notes")
            var appearance = try #require(expectedFields["appearance"]?.object); appearance["fontFamily"] = .string("serif")
            expectedFields["appearance"] = .object(appearance)
            var blocks = try #require(expectedFields["blocks"]?.array), layout = try #require(blocks[0].object)
            layout["splitBasisPoints"] = .number(3000); blocks[0] = .object(layout); expectedFields["blocks"] = .array(blocks)
            #expect(try a.persistence.model.document == ModernDocument(fields: expectedFields))
            a.close(); b.close(); try await server.stop()
            let offline = try await ModernNativeRelayClient.open(store: storeA, endpoint: server.endpoint, relayKey: "native-room", token: "")
            #expect(!offline.connected && offline.peers.isEmpty && offline.pendingChanges == 0)
            try offline.persistence.model.session.replaceTitle(range: 0..<0, with: "Offline ")
            try await offline.persistence.save(); offline.close()
            server = try await Server.start(root: root, repository: repository, document: original)
            let reopened = try await ModernNativeRelayClient.open(store: storeA, endpoint: server.endpoint, relayKey: "native-room", token: "native-relay-test")
            #expect(reopened.pendingChanges == 1)
            try await reopened.exchange()
            expectedFields["title"] = .string("Offline Own Field notes")
            #expect(try reopened.persistence.model.document == ModernDocument(fields: expectedFields) && reopened.pendingChanges == 0 && reopened.peers.isEmpty)
            try reopened.persistence.model.undo(); try reopened.persistence.model.undo()
            expectedFields["title"] = .string("Field notes")
            #expect(try reopened.persistence.model.document == ModernDocument(fields: expectedFields))
            try reopened.persistence.model.redo(); try reopened.persistence.model.redo()
            expectedFields["title"] = .string("Offline Own Field notes")
            #expect(try reopened.persistence.model.document == ModernDocument(fields: expectedFields))
            try await reopened.exchange(); reopened.close()
            let saved = try #require(try await storeA.load())
            #expect(try saved.relay?.receipt.received == saved.restore().session.syncState.received)
            #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("native-relay-test"))
            try await server.stop()
        } catch { try? await server.stop(); throw error }
    }
}
#endif
