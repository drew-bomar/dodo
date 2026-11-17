import XCTest

@MainActor
final class CompletionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletionPersistsAndUndoDoesNotOpenEditor() {
        let app = XCUIApplication()
        app.launch()
        let title = "Completion regression \(UUID().uuidString.prefix(6))"
        add(title, to: app)

        let complete = app.buttons["Complete “\(title)”"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertTrue(complete.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Task"].exists)

        // Relaunch proves the check was persisted, not just drawn locally.
        app.terminate()
        app.launch()
        expandCompleted(in: app)
        let undo = app.buttons["Mark “\(title)” not done"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Edit Task"].exists)
    }

    func testCompletionSurvivesImmediateNavigationWithLiveActivity() {
        let app = XCUIApplication()
        app.launch()
        let title = "Navigation regression \(UUID().uuidString.prefix(6))"
        add(title, to: app)
        app.buttons["Settings"].tap()
        let enabled = app.switches["Show on Lock Screen"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String != "1" {
            // SwiftUI exposes the entire labeled row as a switch. Tap the
            // trailing control rather than the noninteractive label's center.
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let confirm = app.alerts.buttons["Show on Lock Screen"]
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        XCTAssertTrue(app.staticTexts["Showing on the Lock Screen now"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Done"].tap()

        app.buttons["Complete “\(title)”"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        expandCompleted(in: app)
        XCTAssertTrue(app.buttons["Mark “\(title)” not done"].waitForExistence(timeout: 5))
    }

    private func add(_ title: String, to app: XCUIApplication) {
        let field = app.textFields["Add a task"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title + "\n")
    }

    private func expandCompleted(in app: XCUIApplication) {
        let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Completed (")).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
    }
}
