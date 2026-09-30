import XCTest

final class LocalEditingTests: XCTestCase {
    @MainActor func testStandaloneTypingAndHistorySurviveRestart() {
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_LOCAL_DOCUMENT"] = UUID().uuidString
        app.launch()
        app.buttons["Open local document"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("Offline document")
        XCTAssertEqual(text.value as? String, "Offline document")
        XCTAssertTrue(app.staticTexts["Saved locally"].exists)
        app.terminate()
        app.launch()
        app.buttons["Open local document"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.value as? String, "Offline document")
        app.buttons["Undo"].tap()
        XCTAssertNotEqual(text.value as? String, "Offline document")
        app.buttons["Redo"].tap()
        XCTAssertEqual(text.value as? String, "Offline document")
        XCTAssertFalse(app.secureTextFields["Local demo token"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restored standalone document"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
