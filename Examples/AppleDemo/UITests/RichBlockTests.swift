import XCTest

final class RichBlockTests: XCTestCase {
    @MainActor func testTableAndNestedToggleEditsSurviveRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_LOCAL_DOCUMENT"] = UUID().uuidString
        app.launchEnvironment["EDITOR_LAB_FIXTURE"] = "rich-blocks"
        app.launch()
        app.buttons["Open local document"].tap()
        let cell = app.textViews["Row 1, column 1"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertEqual(cell.value as? String, "First cell")
        cell.tap(); cell.typeText(" edited")
        let cellValue = try XCTUnwrap(cell.value as? String)
        XCTAssertTrue(cellValue.contains(" edited"))
        let nested = app.textViews["Block text"]
        XCTAssertTrue(nested.exists)
        nested.tap(); nested.typeText(" changed")
        let nestedValue = try XCTUnwrap(nested.value as? String)
        XCTAssertTrue(nestedValue.contains(" changed"))
        app.buttons["Collapse toggle"].tap()
        XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value == %@", nestedValue)).firstMatch.exists)
        app.buttons["Expand toggle"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", nestedValue)).firstMatch.exists)
        let nestedList = app.textViews.matching(identifier: "List item").element(boundBy: 1)
        if !nestedList.isHittable { app.swipeUp() }
        XCTAssertTrue(nestedList.exists)
        nestedList.tap(); nestedList.typeText(" updated")
        let listValue = try XCTUnwrap(nestedList.value as? String)
        XCTAssertTrue(listValue.contains(" updated"))
        app.terminate(); app.launch()
        app.buttons["Open local document"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        XCTAssertEqual(cell.value as? String, cellValue)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", nestedValue)).firstMatch.exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", listValue)).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restored rich blocks"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
