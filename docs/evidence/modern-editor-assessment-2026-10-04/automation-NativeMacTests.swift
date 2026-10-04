import XCTest

final class LocalEditingTests: XCTestCase {
    @MainActor func testStandaloneTypingAndHistorySurviveRestart() {
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_LOCAL_DOCUMENT"] = UUID().uuidString
        app.launch()
        app.buttons["Open local document"].click()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.click()
        text.typeText("Offline document")
        XCTAssertEqual(text.value as? String, "Offline document")
        XCTAssertTrue(app.staticTexts["Saved locally"].exists)
        app.terminate()
        app.launch()
        app.buttons["Open local document"].click()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.value as? String, "Offline document")
        app.buttons["Undo"].click()
        XCTAssertNotEqual(text.value as? String, "Offline document")
        app.buttons["Redo"].click()
        XCTAssertEqual(text.value as? String, "Offline document")
        XCTAssertFalse(app.secureTextFields["Local demo token"].exists)
        let frame = app.windows.firstMatch.frame
        let receipt = XCTAttachment(string: "WINDOW_FRAME \(frame.origin.x) \(frame.origin.y) \(frame.size.width) \(frame.size.height)")
        receipt.name = "Task-owned window bounds"
        receipt.lifetime = .keepAlways
        add(receipt)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Restored standalone document"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
