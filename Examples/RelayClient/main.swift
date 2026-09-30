import BlockEditorCore
import BlockEditorLocalDemo
import Foundation

@main struct RelayExample {
    @MainActor static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = URL(string: environment["DEMO_ENDPOINT"] ?? "http://127.0.0.1:4319/rooms/shared-demo"),
              let token = environment["DEMO_TOKEN"], !token.isEmpty else { throw RelayError.rejected("Set DEMO_TOKEN and optionally DEMO_ENDPOINT") }
        let client = try await LocalRelayClient.open(endpoint: endpoint, token: token)
        client.setConnected(false)
        let text = try client.session.text(at: TextAddress("p"))
        try client.session.replaceText(at: TextAddress("p"), range: text.utf16.count..<text.utf16.count, with: " [native offline edit]")
        client.setConnected(true)
        try await client.exchange()
        guard client.pendingChanges == 0 else { throw RelayError.rejected("Changes were not acknowledged") }
        print(try String(decoding: client.session.document.json(), as: UTF8.self))
    }
}
