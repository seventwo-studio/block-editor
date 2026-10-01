import BlockEditorCore
import BlockEditorLocalDemo
import XCTest

final class MergeRecoveryTests: XCTestCase {
    @MainActor func testPendingMergeSurvivesRestartAndUserRepairsOriginalContent() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["BLOCK_EDITOR_RECOVERY_RELAY_URL"], let root = URL(string: value),
              let token = environment["BLOCK_EDITOR_RELAY_TOKEN"] else {
            throw XCTSkip("Run bun run test:apple:ui with an iOS simulator destination")
        }
        let endpoint = root.appendingPathComponent("rooms/recovery-ui-\(UUID().uuidString)")
        let a = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "alice")
        let b = try await LocalRelayClient.open(endpoint: endpoint, token: token, actorID: "bob")
        XCTAssertEqual(a.session.collaborationVersion, 2)
        try a.session.insert(.paragraph(id: "same", text: "Local Alice"))
        try b.session.insert(.paragraph(id: "same", text: "Remote Bob"))
        try await a.exchange()

        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_RELAY_ENDPOINT"] = endpoint.absoluteString
        app.launch()
        app.buttons["Open collaborative lab"].tap()
        let tokenField = app.secureTextFields["Local demo token"]
        tokenField.tap(); tokenField.typeText(token)
        app.buttons["Open editor"].tap()
        let alice = app.textViews.matching(NSPredicate(format: "value == %@", "Local Alice")).firstMatch
        XCTAssertTrue(alice.waitForExistence(timeout: 10))
        do { try await b.exchange(); XCTFail("Expected the conflicting server union to require recovery") }
        catch { XCTAssertNotNil(b.session.mergeRecovery) }
        let recovery = app.staticTexts["merge-recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertEqual(alice.value as? String, "Local Alice")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        let pendingScreenshot = XCTAttachment(screenshot: app.screenshot())
        pendingScreenshot.name = "Pending merge with accepted content and explicit recovery actions"
        pendingScreenshot.lifetime = .keepAlways
        add(pendingScreenshot)
        let export = app.buttons["export-recovery"]
        if !export.isHittable { app.swipeUp() }
        export.tap()
        XCTAssertTrue(app.staticTexts["recovery-exported"].waitForExistence(timeout: 5))

        app.terminate(); app.launch()
        app.buttons["Open collaborative lab"].tap()
        app.buttons["Open editor"].tap() // Restart restores accepted and pending history without networking.
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["Connected to local server"].value as? String, "0")
        XCTAssertEqual(alice.value as? String, "Local Alice")
        let picker = app.descendants(matching: .any).matching(identifier: "recovery-block-picker").firstMatch
        picker.tap()
        app.buttons["Original paragraph: Remote Bob"].tap()
        app.buttons["repair-merge"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: recovery)
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertEqual(alice.value as? String, "Local Alice")
        let bob = app.textViews.matching(NSPredicate(format: "value == %@", "Remote Bob")).firstMatch
        XCTAssertTrue(bob.waitForExistence(timeout: 5))

        tokenField.tap(); tokenField.typeText(token)
        app.switches["Connected to local server"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let acknowledged = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0 unacknowledged changes")).firstMatch
        XCTAssertTrue(acknowledged.waitForExistence(timeout: 10))
        try await a.exchange(); try await b.exchange()
        XCTAssertEqual(try a.session.document, try b.session.document)
        XCTAssertTrue(try a.session.document.blocks.contains { $0.type == "toggle" })
        XCTAssertNil(b.session.mergeRecovery)
        XCTAssertEqual(b.pendingChanges, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Recovered original blocks after restart and repair"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
