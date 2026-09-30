import BlockEditorCore
import BlockEditorLocalDemo
import Foundation

@main struct RelayExample {
    @MainActor static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = URL(string: environment["DEMO_ENDPOINT"] ?? "http://127.0.0.1:4319/rooms/shared-demo") else { throw RelayError.rejected("Invalid DEMO_ENDPOINT") }
        let token = environment["DEMO_TOKEN"] ?? ""
        let draft = try environment["DEMO_DRAFT"].map { try LocalDraft(file: URL(fileURLWithPath: $0)) }
        defer { withExtendedLifetime(draft) {} }
        let client: LocalRelayClient
        if let restored = try draft?.restore(endpoint: endpoint) {
            client = LocalRelayClient(session: restored, endpoint: endpoint, token: token)
        } else {
            guard !token.isEmpty else { throw RelayError.rejected("Set DEMO_TOKEN to open a new draft") }
            client = try await LocalRelayClient.open(endpoint: endpoint, token: token)
        }
        client.setConnected(false)
        switch environment["DEMO_ACTION"] ?? "edit" {
        case "edit":
            let text = try client.session.text(at: TextAddress("p"))
            try client.session.replaceText(at: TextAddress("p"), range: text.utf16.count..<text.utf16.count, with: environment["DEMO_TEXT"] ?? " [native offline edit]")
        case "undo": try client.session.undo()
        case "inspect", "rejoin": break
        default: throw RelayError.rejected("Use edit, undo, inspect or rejoin for DEMO_ACTION")
        }
        try draft?.save(client.session, endpoint: endpoint)
        if environment["DEMO_OFFLINE"] != "1" {
            client.setConnected(true)
            try await client.exchange()
            guard client.pendingChanges == 0 else { throw RelayError.rejected("Changes were not acknowledged") }
            try draft?.save(client.session, endpoint: endpoint)
        }
        print(try String(decoding: client.session.document.json(), as: UTF8.self))
    }
}
