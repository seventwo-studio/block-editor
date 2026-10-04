import XCTest

final class InteractionReviewTests:XCTestCase {
    @MainActor func interact(_ element:XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    @MainActor func attach(_ app:XCUIApplication,_ name:String) {
        #if os(macOS)
        let shot = app.windows.firstMatch.screenshot()
        #else
        let shot = app.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot:shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testTitleWritingAndContextualPicker() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launchEnvironment["EDITOR_REVIEW_RECEIPT"] = "/private/tmp/block-editor-st121-writing-receipt.json"
        app.launch()
        let body = app.textViews["Text intro"]
        XCTAssertTrue(body.waitForExistence(timeout:10))
        let title = app.textFields["Document title"].exists ? app.textFields["Document title"] : app.textViews["Document title"]
        interact(title)
        #if os(macOS)
        title.typeKey("a",modifierFlags:.command)
        #else
        title.press(forDuration:1)
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        #endif
        title.typeText("Review title")
        XCTAssertTrue((title.value as? String)?.contains("Review title") == true)
        interact(body)
        #if os(macOS)
        body.typeKey(XCUIKeyboardKey.end.rawValue,modifierFlags:.command)
        #endif
        body.typeText(" /hea")
        XCTAssertTrue(app.buttons["Heading"].waitForExistence(timeout:5))
        attach(app,"Contextual slash query")
        #if os(macOS)
        body.typeKey(XCUIKeyboardKey.escape.rawValue,modifierFlags:[])
        #else
        interact(app.buttons["Dismiss picker"])
        #endif
        XCTAssertTrue((body.value as? String)?.contains("/hea") == true)
        XCTAssertFalse(app.buttons["Heading"].exists)
        attach(app,"Cancelled query retains content")
        interact(app.buttons["Insert"])
        let search = app.textFields["Search blocks"]
        XCTAssertTrue(search.waitForExistence(timeout:5))
        interact(search); search.typeText("Heading")
        interact(app.buttons["Heading"])
        XCTAssertTrue(app.staticTexts["Insert Heading"].waitForExistence(timeout:5))
        attach(app,"Inserted heading with direct title")
        app.terminate()
    }
    @MainActor func testBlockRangeColumnsAndPersonalViews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launchEnvironment["EDITOR_REVIEW_RECEIPT"] = "/private/tmp/block-editor-st121-columns-receipt.json"
        app.launch()
        XCTAssertTrue(app.buttons["Select first"].waitForExistence(timeout:10))
        interact(app.buttons["Select first"]); interact(app.buttons["Select second"])
        XCTAssertTrue(app.staticTexts["2 blocks selected"].waitForExistence(timeout:3))
        interact(app.buttons["Create two columns"])
        XCTAssertTrue(app.buttons["Remove columns"].waitForExistence(timeout:3))
        attach(app,"Created two columns")
        interact(app.buttons["Select second"])
        interact(app.buttons["Second column"])
        attach(app,"Moved origin into second column")
        #if os(macOS)
        let slider = app.sliders["Column split"]
        XCTAssertTrue(slider.exists)
        interact(slider)
        slider.typeKey(XCUIKeyboardKey.rightArrow.rawValue,modifierFlags:[])
        if app.buttons["Apply split"].exists { interact(app.buttons["Apply split"]) }
        attach(app,"Keyboard adjusted split")
        #endif
        interact(app.buttons["Remove columns"])
        XCTAssertTrue(app.staticTexts["Remove columns in logical order"].waitForExistence(timeout:3))
        XCTAssertEqual(app.textViews["Text first"].value as? String,"First thought")
        XCTAssertEqual(app.textViews["Text second"].value as? String,"Second thought")
        interact(app.buttons["Outline"])
        XCTAssertTrue(app.staticTexts["On this page"].exists)
        interact(app.buttons["Focus"])
        XCTAssertFalse(app.staticTexts["On this page"].exists)
        XCTAssertTrue(app.buttons["Leave focus mode"].exists)
        attach(app,"Plain document in focus mode")
        interact(app.buttons["Leave focus mode"])
        app.terminate()
    }
}
