import BlockEditorCore
import BlockEditorLocalDemo
import XCTest

final class CollaborativeEditingTests: XCTestCase {
    @MainActor func testOfflineTypingMergesAndRecoversAcrossRestart() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["BLOCK_EDITOR_RELAY_URL"], let root = URL(string: value),
              let token = environment["BLOCK_EDITOR_RELAY_TOKEN"] else {
            throw XCTSkip("Run bun run test:apple:ui with an iOS simulator destination")
        }
        XCTAssertTrue(["localhost", "127.0.0.1"].contains(root.host ?? ""))
        let endpoint = root.appendingPathComponent("rooms/ui-\(UUID().uuidString)")
        let remote = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "ui-remote")
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_RELAY_ENDPOINT"] = endpoint.absoluteString
        app.launch()
        app.buttons["Open collaborative lab"].tap()
        let tokenField = app.secureTextFields["Local demo token"]
        tokenField.tap(); tokenField.typeText(token)
        app.buttons["Open editor"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let connected = app.switches["Connected to local server"]
        XCTAssertTrue(connected.waitForExistence(timeout: 5))
        connected.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(connected.value as? String, "0")
        text.tap(); text.typeText(" offline ")
        XCTAssertTrue((text.value as? String)?.contains(" offline ") == true)
        try remote.session.replaceText(at: TextAddress("p"), range: 0..<0, with: "remote ")
        try await remote.exchange()
        XCTAssertFalse((text.value as? String)?.contains("remote ") == true)
        connected.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let merged = NSPredicate(format: "value CONTAINS %@", "remote ")
        let mergedExpectation = XCTNSPredicateExpectation(predicate: merged, object: text)
        await fulfillment(of: [mergedExpectation], timeout: 10)
        XCTAssertTrue((text.value as? String)?.contains(" offline ") == true)
        let acknowledged = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0 unacknowledged changes")).firstMatch
        XCTAssertTrue(acknowledged.waitForExistence(timeout: 5))
        let presence = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 other clients")).firstMatch
        XCTAssertTrue(presence.waitForExistence(timeout: 3))
        let mergedText = try XCTUnwrap(text.value as? String)
        app.buttons["Undo"].tap()
        XCTAssertTrue((text.value as? String)?.contains("remote ") == true)
        XCTAssertNotEqual(text.value as? String, mergedText)
        app.buttons["Redo"].tap()
        XCTAssertEqual(text.value as? String, mergedText)
        app.terminate()
        app.launch()
        app.buttons["Open collaborative lab"].tap()
        app.buttons["Open editor"].tap() // Saved drafts reopen without a token.
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.value as? String, mergedText)
        XCTAssertEqual(connected.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Recovered collaborative document"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
