import XCTest

@MainActor
final class CowlickUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testWorkingStateIsAccessible() {
    let app = launch(state: "working")
    let visible = app.buttons["Scoutly, Working"].waitForExistence(timeout: 3)
    XCTAssertTrue(visible)
  }

  func testSimulatedNotchWorkingStateIsAccessible() {
    let app = launch(arguments: ["--simulate-notch", "--state=working"])
    XCTAssertTrue(app.buttons["Scoutly, Working"].waitForExistence(timeout: 3))
  }

  func testSimulatedNotchExpandsNaturallyOnHover() {
    let app = launch(
      arguments: ["--simulate-notch", "--state=working"], autoHoverEnabled: true)
    let island = app.buttons["Scoutly, Working"]
    XCTAssertTrue(island.waitForExistence(timeout: 3))

    island.hover()

    XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 2))
  }

  func testApprovalActionsAreAccessibleAndAllowIsNotDefault() {
    let app = launch(state: "approvalRequested")
    let deny = app.buttons["Deny"]
    let open = app.buttons["Open Codex"]
    let allow = app.buttons["Allow once"]
    XCTAssertTrue(deny.waitForExistence(timeout: 3))
    XCTAssertTrue(open.exists)
    XCTAssertTrue(allow.exists)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(allow.waitForExistence(timeout: 1))
    XCTAssertTrue(deny.exists)
  }

  func testDenyClearsLocalApprovalDemo() {
    let app = launch(state: "approvalRequested")
    let deny = app.buttons["Deny"]
    XCTAssertTrue(deny.waitForExistence(timeout: 3))
    deny.click()
    XCTAssertTrue(deny.waitForNonExistence(timeout: 3))
  }

  func testAllowOnceClearsLocalApprovalDemo() {
    let app = launch(state: "approvalRequested")
    let allow = app.buttons["Allow once"]
    XCTAssertTrue(allow.waitForExistence(timeout: 3))
    allow.click()
    XCTAssertTrue(allow.waitForNonExistence(timeout: 3))
  }

  func testCompletedStateIsAccessible() {
    let app = launch(state: "completed")
    let visible = app.buttons["Meetly, Completed"].waitForExistence(timeout: 3)
    XCTAssertTrue(visible)
  }

  func testFailedStateIsAccessible() {
    let app = launch(arguments: ["--state=failed", "--expanded"])
    let failedSession = sessionRow(in: app, id: "demo-visual-state")
    XCTAssertTrue(failedSession.waitForExistence(timeout: 3))
    XCTAssertEqual(failedSession.label, "Scoutly, Failed")
    XCTAssertTrue(app.buttons["Open Diagnostics"].exists)
  }

  func testMultipleSessionListIsAccessible() {
    let app = launch(state: "multiple")
    let activityPilot = sessionRow(in: app, id: "demo-secondary")
    let scoutly = sessionRow(in: app, id: "demo-primary")
    XCTAssertTrue(activityPilot.waitForExistence(timeout: 3))
    XCTAssertEqual(activityPilot.label, "ActivityPilot, Working")
    XCTAssertTrue(scoutly.exists)
    XCTAssertEqual(scoutly.label, "Scoutly, Working")
  }

  func testOnboardingOpens() {
    let app = launch(arguments: ["--open-onboarding"])
    XCTAssertTrue(
      app.staticTexts["Codex status, at the notch."].waitForExistence(timeout: 3))
  }

  func testSettingsOpens() {
    let app = launch(arguments: ["--open-settings"])
    XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
  }

  func testDiagnosticsOpens() {
    let app = launch(arguments: ["--open-diagnostics"])
    XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 3))
  }

  private func launch(state: String) -> XCUIApplication {
    launch(arguments: ["--state=\(state)"])
  }

  private func launch(arguments: [String], autoHoverEnabled: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["--ui-testing"]
      + (autoHoverEnabled ? [] : ["--disable-auto-hover"])
      + arguments
    app.launch()
    return app
  }

  private func sessionRow(in app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "session-row-\(id)").firstMatch
  }
}
