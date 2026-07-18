import XCTest

@MainActor
final class NotchRelayUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testWorkingStateIsAccessible() {
    let app = launch(state: "working")
    let visible = app.buttons["Scoutly, Working"].waitForExistence(timeout: 3)
    XCTAssertTrue(visible)
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
    XCTAssertTrue(app.staticTexts["Scoutly"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Open Diagnostics"].exists)
  }

  func testMultipleSessionListIsAccessible() {
    let app = launch(state: "multiple")
    XCTAssertTrue(app.staticTexts["ActivityPilot"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Scoutly"].exists)
  }

  func testOnboardingOpens() {
    let app = launch(arguments: ["--open-onboarding"])
    XCTAssertTrue(
      app.staticTexts["Codex status, where your eyes already are."].waitForExistence(timeout: 3))
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

  private func launch(arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"] + arguments
    app.launch()
    return app
  }
}
