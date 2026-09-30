import XCTest

final class TextLayoutTests: XCTestCase {
    @MainActor func testWrappedParagraphGrowsAndRestoresItsHeight() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_LOCAL_DOCUMENT"] = UUID().uuidString
        app.launch()
        app.buttons["Open local document"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let emptyHeight = text.frame.height
        let content = String(repeating: "wrapped text ", count: 45)
        text.tap(); text.typeText(content)
        XCTAssertEqual(text.value as? String, content)
        XCTAssertGreaterThan(text.frame.height, emptyHeight)
        app.terminate(); app.launch()
        app.buttons["Open local document"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.value as? String, content)
        XCTAssertGreaterThan(text.frame.height, emptyHeight)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restored wrapped paragraph"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
