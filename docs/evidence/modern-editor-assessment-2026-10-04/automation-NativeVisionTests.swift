import XCTest
import BlockEditorCore
@testable import AssessmentVision

final class NativeVisionModelCaptureTests: XCTestCase {
    @MainActor func testRenderedTableCommandsAndSavedHistory() async throws {
        let controller = CaptureController.shared
        let model = controller.model
        let initial = try model.session.document.json()
        let address = TextAddress("table", path: ["rows", "row", "cells", "left", "content"])
        try await Task.sleep(for: .seconds(2))
        model.perform { try $0.setText(at: address, to: "Automated native table edit") }
        XCTAssertNil(model.error)
        XCTAssertTrue(String(decoding: try model.session.document.json(), as: UTF8.self).contains("Automated native table edit"))
        let edited = try model.session.document.json()
        try await Task.sleep(for: .seconds(2))
        model.perform { try $0.undo() }
        XCTAssertNil(model.error)
        XCTAssertEqual(try model.session.document.json(), initial)
        try await Task.sleep(for: .seconds(2))
        model.perform { try $0.redo() }
        XCTAssertNil(model.error)
        XCTAssertEqual(try model.session.document.json(), edited)
        let restored = try EditorSession.restore(model.session.save(), actorID: "assessment")
        XCTAssertEqual(try restored.document.json(), edited)
        try restored.undo()
        XCTAssertEqual(try restored.document.json(), initial)
        try restored.redo()
        XCTAssertEqual(try restored.document.json(), edited)
        try await Task.sleep(for: .seconds(2))
    }
}
