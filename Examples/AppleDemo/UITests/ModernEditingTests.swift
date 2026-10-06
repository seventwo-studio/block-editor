import XCTest

final class ModernEditingTests: XCTestCase {
    @MainActor func testModernTitleBodyCodeAndPairedReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_MODERN"] = "1"
        app.launchEnvironment["EDITOR_LAB_MODERN_DOCUMENT"] = UUID().uuidString
        app.launch()
        let title = app.textViews["Document title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap(); title.typeText(" Updated\n")
        let body = app.textViews["Block text"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.typeText("Modern body")
        app.buttons["Format"].tap()
        XCTAssertTrue(app.buttons["Bold"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        body.typeText(" after menu")
        let code = app.textViews["Code"]
        code.tap(); code.typeText("  literal\nline")
        app.buttons["Save locally"].tap()
        XCTAssertTrue(app.staticTexts["Saved with recovery and author history"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Modern integrated candidate"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue((body.value as? String)?.contains("Modern body after menu") == true)
        XCTAssertTrue((code.value as? String)?.contains("  literal\nline") == true)
    }
}
