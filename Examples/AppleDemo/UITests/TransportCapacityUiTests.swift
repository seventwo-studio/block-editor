import Foundation
import XCTest

/// Separate process phases: the runner stops the real relay between them.
final class TransportCapacityUiTests: XCTestCase {
    @MainActor func testCapacityProcessPhase() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["BLOCK_EDITOR_CAPACITY_PHASE"],
              let endpoint = environment["BLOCK_EDITOR_CAPACITY_ENDPOINT"],
              let draftID = environment["BLOCK_EDITOR_CAPACITY_DRAFT_ID"],
              let token = environment["BLOCK_EDITOR_CAPACITY_TOKEN"],
              let control = environment["BLOCK_EDITOR_CAPACITY_CONTROL"], let root = URL(string: control) else {
            throw XCTSkip("Run the reserved native capacity harness")
        }
        let app = XCUIApplication()
        app.launchEnvironment["EDITOR_LAB_RELAY_ENDPOINT"] = endpoint
        app.launchEnvironment["EDITOR_LAB_RESUME_DRAFT"] = draftID
        app.launch()
        app.buttons["Open collaborative lab"].tap()
        app.buttons["Open editor"].tap()
        let accepted = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Retained café 😀")).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches["Connected to local server"].value as? String, "0")
        let emptyToken = app.secureTextFields["Local demo token"].value as? String
        XCTAssertTrue(emptyToken == nil || emptyToken == "" || emptyToken == "Local demo token")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)

        if phase == "offline" {
            XCTAssertFalse(app.staticTexts["transport-capacity"].exists)
            attach(app, "Retained local history after offline app and relay termination")
        } else if phase == "failed-save" {
            try await controlStorage(root, action: "block", token: token)
            accepted.tap(); accepted.typeText(" local save retry")
            let retry = app.buttons["retry-local-save"]
            XCTAssertTrue(retry.waitForExistence(timeout: 10))
            app.buttons["export-retained-history"].tap()
            XCTAssertTrue(app.staticTexts["retained-history-exported"].waitForExistence(timeout: 10))
            attach(app, "Failed local persistence retains visible content and export")
            try await controlStorage(root, action: "restore", token: token)
            retry.tap()
            let saved = app.staticTexts["Saved locally"]
            XCTAssertTrue(saved.waitForExistence(timeout: 10))
            XCTAssertFalse(retry.exists)
            XCTAssertTrue((accepted.value as? String)?.contains("local save retry") == true)
        } else {
            XCTAssertTrue(["prepare", "retry"].contains(phase))
            let field = app.secureTextFields["Local demo token"]
            field.tap(); field.typeText(token)
            app.switches["Connected to local server"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["transport-capacity"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synchronization: Retrying:")).firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@", "8000000", "8,000,000", "8.000.000")).firstMatch.exists)
            app.buttons["export-retained-history"].tap()
            XCTAssertTrue(app.staticTexts["retained-history-exported"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Share retained history"].exists)
            // Pause polling and drain the prior request before observing this tap.
            app.switches["Connected to local server"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertEqual(app.switches["Connected to local server"].value as? String, "0")
            // The host publishes this after its previous awaited exchange returns.
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synchronization: Offline;")).firstMatch.waitForExistence(timeout: 15))
            let armed = try await retryObservation(root, action: "arm-retry", token: token)
            app.buttons["Retry synchronization"].tap()
            XCTAssertEqual(app.switches["Connected to local server"].value as? String, "1")
            let completed = try await retryObservation(root, action: "await-retry", token: token, id: armed.id)
            XCTAssertGreaterThan(completed.completion?.sequence ?? 0, armed.afterSequence)
            XCTAssertEqual(completed.completion?.status, 413)
            XCTAssertEqual(completed.completion?.authenticated, true)
            XCTAssertEqual(completed.completion?.capacityError, true)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Synchronization: Retrying:")).firstMatch.waitForExistence(timeout: 15))
            let proof = XCTAttachment(data: try JSONEncoder().encode(completed), uniformTypeIdentifier: "public.json")
            proof.name = "Authenticated completed capacity POST after explicit retry"; proof.lifetime = .keepAlways; add(proof)
            XCTAssertTrue(app.staticTexts["transport-capacity"].exists)
            attach(app, "Transport capacity with retained content and visible export retry")
        }
        app.terminate()
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func controlStorage(_ root: URL, action: String, token: String) async throws {
        var request = URLRequest(url: root.appendingPathComponent(action))
        request.httpMethod = "POST"; request.setValue(token, forHTTPHeaderField: "X-Test-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private struct RetryObservation: Codable {
        struct Completion: Codable {
            let sequence: Int
            let status: Int
            let authenticated: Bool
            let capacityError: Bool
        }
        let id: String
        let afterSequence: Int
        let completion: Completion?
    }
    @MainActor private func retryObservation(_ root: URL, action: String, token: String, id: String? = nil) async throws -> RetryObservation {
        var request = URLRequest(url: root.appendingPathComponent(action))
        request.httpMethod = "POST"; request.setValue(token, forHTTPHeaderField: "X-Test-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["id": id])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(RetryObservation.self, from: data)
    }
}
