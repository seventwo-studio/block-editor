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
    @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for:.milliseconds(100))
        }
        return condition()
    }
    @MainActor func expectValue(_ element:XCUIElement,contains text:String) async {
        _ = await waitUntil { self.plainValue(element.value)?.contains(text) == true }
        // One final native snapshot supplies both assertion and diagnostic. A
        // second diagnostic fetch can otherwise show a value the poll never saw.
        let value = element.value
        XCTAssertTrue(plainValue(value)?.contains(text) == true,"Native value: \(String(describing:value)); type: \(value.map { String(reflecting:type(of:$0)) } ?? "nil")")
    }
    func plainValue(_ value:Any?) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let attributed = value as? AttributedString { return String(attributed.characters) }
        return nil
    }
    @MainActor func testTitleWritingAndContextualPicker() async throws {
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
        await expectValue(title,contains:"Review title")
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
        interact(app.descendants(matching:.any)["Select blocks"].firstMatch)
        XCTAssertTrue(app.buttons["Select first"].waitForExistence(timeout:10))
        interact(app.buttons["Select first"]); interact(app.buttons["Select second"])
        XCTAssertTrue(app.staticTexts["2 blocks selected"].waitForExistence(timeout:3))
        interact(app.buttons["Create two columns"])
        XCTAssertTrue(app.buttons["Remove columns"].waitForExistence(timeout:3))
        attach(app,"Created two columns")
        interact(app.buttons["Select second"])
        interact(app.buttons["Second column"])
        attach(app,"Moved origin into second column")
        interact(app.buttons["Resize columns"].firstMatch)
        XCTAssertTrue(app.staticTexts["Column proportions"].waitForExistence(timeout:3))
        interact(app.buttons["70 / 30"].firstMatch)
        interact(app.buttons["Cancel resize"].firstMatch)
        XCTAssertTrue(app.staticTexts["Split 50 / 50"].waitForExistence(timeout:3))
        interact(app.buttons["Resize columns"].firstMatch)
        interact(app.buttons["70 / 30"].firstMatch)
        interact(app.buttons["Apply split"].firstMatch)
        XCTAssertTrue(app.staticTexts["Split 70 / 30"].waitForExistence(timeout:3))
        attach(app,"Touch pointer resize and cancellation")
        #if os(macOS)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue,modifierFlags:[.command,.option])
        XCTAssertTrue(app.staticTexts["Split 75 / 25"].waitForExistence(timeout:3))
        attach(app,"Keyboard adjusted split changes ratio")
        let divider = app.descendants(matching:.any)["Drag column divider"].firstMatch
        let origin = divider.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        let destination = origin.withOffset(CGVector(dx:-70,dy:0))
        origin.press(forDuration:0.2,thenDragTo:destination)
        XCTAssertFalse(app.staticTexts["Split 75 / 25"].exists)
        attach(app,"Pointer divider drag")
        #endif
        interact(app.buttons["Remove columns"])
        XCTAssertTrue(app.staticTexts["Remove columns in logical order"].waitForExistence(timeout:3))
        XCTAssertEqual(app.textViews["Text first"].value as? String,"First thought")
        XCTAssertEqual(app.textViews["Text second"].value as? String,"Second thought")
        interact(app.buttons["Outline"])
        XCTAssertTrue(app.staticTexts["On this page"].exists)
        #if os(iOS)
        interact(app.buttons["Close outline"])
        #endif
        interact(app.buttons["Focus"])
        XCTAssertFalse(app.staticTexts["On this page"].exists)
        XCTAssertTrue(app.buttons["Leave focus mode"].exists)
        attach(app,"Plain document in focus mode")
        interact(app.buttons["Leave focus mode"])
        app.terminate()
    }

    @MainActor func testKeyboardTitleToBodyAndSlashAcceptance() async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launchEnvironment["EDITOR_REVIEW_RECEIPT"] = "/private/tmp/block-editor-st121-keyboard-receipt.json"
        app.launch()
        let title = app.textFields["Document title"]
        XCTAssertTrue(title.waitForExistence(timeout:10))
        interact(title)
        title.typeText(" keyboard")
        #if os(macOS)
        title.typeKey(XCUIKeyboardKey.return.rawValue,modifierFlags:[])
        #else
        title.typeText("\n")
        #endif
        XCTAssertTrue(app.staticTexts["Title Enter to body"].waitForExistence(timeout:3))
        app.typeText("Keyboard start ")
        await expectValue(app.textViews["Text intro"],contains:"Keyboard start ")
        XCTAssertTrue((app.textViews["Text intro"].value as? String)?.hasPrefix("Keyboard start ") == true)
        #if os(macOS)
        app.typeKey(XCUIKeyboardKey.end.rawValue,modifierFlags:.command)
        #else
        app.textViews["Text intro"].tap()
        #endif
        app.typeText(" /hea")
        XCTAssertTrue(app.buttons["Heading"].waitForExistence(timeout:3))
        #if os(macOS)
        app.typeKey(XCUIKeyboardKey.return.rawValue,modifierFlags:[])
        #else
        app.typeText("\n")
        #endif
        XCTAssertTrue(app.staticTexts["Insert Heading"].waitForExistence(timeout:3))
        app.typeText("From keyboard")
        await expectValue(app.textViews["Text review-101"],contains:"From keyboard")
        XCTAssertEqual(app.textViews["Text review-101"].value as? String,"From keyboard")
        XCTAssertFalse((app.textViews["Text intro"].value as? String)?.contains("/hea") == true)
        attach(app,"Title to body and slash Return with continued input")
        app.terminate()
    }

    @MainActor func testFormattingConversionAndNestedInput() async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launchEnvironment["EDITOR_REVIEW_RECEIPT"] = "/private/tmp/block-editor-st121-rich-receipt.json"
        app.launch()
        let first = app.textViews["Text first"]
        XCTAssertTrue(first.waitForExistence(timeout:10))
        interact(first)
        #if os(macOS)
        first.typeKey("a",modifierFlags:.command)
        first.typeKey("b",modifierFlags:.command)
        #else
        first.press(forDuration:1)
        let selectAll = app.descendants(matching:.any)["Select All"].firstMatch
        if selectAll.waitForExistence(timeout:3) { interact(selectAll) } else { first.doubleTap() }
        interact(app.buttons["Accessory bold"])
        #endif
        XCTAssertTrue(app.staticTexts["Format bold"].waitForExistence(timeout:3))
        XCTAssertEqual(first.value as? String,"First thought")
        attach(app,"Native selected range bold formatting")
        let actions = app.descendants(matching:.any)["Block actions first"].firstMatch
        interact(actions)
        interact(app.descendants(matching:.any)["Convert to heading"].firstMatch)
        XCTAssertTrue(app.staticTexts["Convert heading"].waitForExistence(timeout:3))
        XCTAssertEqual(app.descendants(matching:.any)["Block actions first"].firstMatch.value as? String,"heading")
        attach(app,"Conversion retains rich text")
        interact(app.buttons["Outline"])
        interact(app.buttons["Structured notes"])
        #if os(macOS)
        interact(app.buttons["Outline"])
        #endif
        interact(app.buttons["Disclosure toggle"])
        let nested = app.textViews["Text child"]
        XCTAssertTrue(nested.waitForExistence(timeout:3))
        interact(nested)
        #if os(macOS)
        nested.typeKey(XCUIKeyboardKey.end.rawValue,modifierFlags:.command)
        #endif
        nested.typeText(" edited")
        await expectValue(nested,contains:" edited")
        let list = app.textViews["List parent"]
        interact(list)
        list.typeText(" native")
        await expectValue(list,contains:" native")
        attach(app,"Native nested toggle and list input")
        interact(app.buttons["Outline"])
        interact(app.buttons["Closing notes"])
        let closing = app.textViews["Text closing"]
        let reached = await waitUntil { closing.isHittable }
        XCTAssertTrue(reached,"Closing heading was not reached by the outline")
        attach(app,"Long document outline reaches closing heading")
        app.terminate()
    }

    @MainActor func testMultipleLayoutsAndBoundaryWriting() async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launch()
        interact(app.descendants(matching:.any)["Select blocks"].firstMatch)
        interact(app.buttons["Select first"]); interact(app.buttons["Select second"])
        interact(app.buttons["Create two columns"])
        interact(app.buttons["Select intro"])
        interact(app.buttons["Create two columns"])
        XCTAssertEqual(app.buttons.matching(identifier:"Remove columns").count,2)
        interact(app.textViews["Text intro"])
        interact(app.buttons["Insert"])
        let search = app.textFields["Search blocks"]
        interact(search); search.typeText("Two columns")
        interact(app.buttons["Insert option Two columns"])
        XCTAssertTrue(app.staticTexts["A column layout cannot contain another column layout"].waitForExistence(timeout:3))
        XCTAssertEqual(app.buttons.matching(identifier:"Remove columns").count,2)
        interact(app.buttons["Dismiss picker"])
        attach(app,"Independent layouts and explicit nesting rejection")
        interact(app.textViews["Text section"])
        interact(app.buttons["Insert"])
        interact(app.textFields["Search blocks"]); app.textFields["Search blocks"].typeText("Two columns")
        interact(app.buttons["Insert option Two columns"])
        XCTAssertEqual(app.buttons.matching(identifier:"Remove columns").count,3)
        let empty = app.textFields["Empty First column layout-103"]
        XCTAssertTrue(empty.exists)
        interact(empty); empty.typeText("F")
        XCTAssertTrue(app.textViews["Text review-104"].waitForExistence(timeout:3))
        app.typeText("resh writing")
        await expectValue(app.textViews["Text review-104"],contains:"Fresh writing")
        XCTAssertEqual(app.textViews["Text review-104"].value as? String,"Fresh writing")
        attach(app,"Boundary columns accept first real input")
        app.terminate()
    }

    @MainActor func testColumnFocusOrderAndContainment() async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launchEnvironment["EDITOR_REVIEW_RECEIPT"] = "/private/tmp/block-editor-st121-column-focus-receipt.json"
        app.launch()
        let second = app.textViews["Text second"]
        XCTAssertTrue(second.waitForExistence(timeout:10))
        interact(second); second.typeText("before ")
        await expectValue(second,contains:"before ")
        interact(app.descendants(matching:.any)["Select blocks"].firstMatch)
        interact(app.buttons["Select first"]); interact(app.buttons["Select second"])
        interact(app.buttons["Create two columns"])
        app.typeText("after create ")
        await expectValue(second,contains:"after create ")
        interact(app.buttons["Select second"])
        interact(app.buttons["Move up"])
        app.typeText("after reorder ")
        await expectValue(second,contains:"after reorder ")
        XCTAssertLessThan(second.frame.minY,app.textViews["Text first"].frame.minY)
        attach(app,"Column reorder preserves logical order and typing focus")
        interact(app.buttons["Remove columns"])
        app.typeText("after remove ")
        await expectValue(second,contains:"after remove ")
        XCTAssertLessThan(second.frame.minY,app.textViews["Text first"].frame.minY)
        attach(app,"Flattening preserves column order and typing focus")
        if app.buttons["Cancel selection"].exists { interact(app.buttons["Cancel selection"]) }
        interact(app.buttons["Outline"]); interact(app.buttons["Structured notes"])
        #if os(macOS)
        interact(app.buttons["Outline"])
        #endif
        if !app.buttons["Select toggle"].exists { interact(app.descendants(matching:.any)["Select blocks"].firstMatch) }
        interact(app.buttons["Select toggle"]); interact(app.buttons["Select list"])
        interact(app.buttons["Create two columns"])
        interact(app.buttons["Disclosure toggle"])
        let child = app.textViews["Text child"]
        interact(child); child.typeText("inside columns ")
        await expectValue(child,contains:"inside columns ")
        let list = app.textViews["List parent"]
        interact(list); list.typeText("contained list ")
        await expectValue(list,contains:"contained list ")
        XCTAssertTrue(app.textViews["List child"].exists)
        attach(app,"List and toggle remain editable inside columns")
        app.terminate()
    }

    @MainActor func testRichFieldInputAndLiteralPreservation() async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_REVIEW_PRIMARY_WINDOW"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Outline"].waitForExistence(timeout:10))
        interact(app.buttons["Outline"]); interact(app.buttons["Structured notes"])
        #if os(macOS)
        interact(app.buttons["Outline"])
        #endif
        let cell = app.textViews["Cell left"]
        interact(cell); cell.typeText("Cell edit ")
        await expectValue(cell,contains:"Cell edit ")
        await expectValue(cell,contains:"First cell")
        let caption = app.textViews["Media caption"]
        interact(caption); caption.typeText("Caption edit ")
        await expectValue(caption,contains:"Caption edit ")
        attach(app,"Native table cell and local media caption input")
        let code = app.textViews["Code review-code"]
        let original = code.value as? String
        XCTAssertEqual(original,"\tlet coast = \"世界😀\"\n    print(coast)  \n")
        interact(code); code.typeText("literal ")
        await expectValue(code,contains:"literal ")
        XCTAssertEqual((code.value as? String)?.replacingOccurrences(of:"literal ",with:""),original)
        attach(app,"Code input retains literal Unicode and whitespace")
        app.terminate()
    }
}
