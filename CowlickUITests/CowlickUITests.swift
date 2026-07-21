import XCTest

@MainActor
final class CowlickUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testWorkingStateIsAccessible() {
    let app = launch(state: "working")
    let visible = app.buttons["Polish release onboarding, Scoutly, Working"]
      .waitForExistence(timeout: 3)
    XCTAssertTrue(visible)
  }

  func testSimulatedNotchWorkingStateIsAccessible() {
    let app = launch(arguments: ["--simulate-notch", "--state=working"])
    XCTAssertTrue(
      app.buttons["Polish release onboarding, Scoutly, Working"].waitForExistence(timeout: 3))
  }

  func testSimulatedNotchExpandsNaturallyOnHover() {
    let app = launch(
      arguments: ["--simulate-notch", "--state=working"], autoHoverEnabled: true)
    let expandedSession = sessionRow(in: app, id: "demo-visual-state")
    if expandedSession.waitForExistence(timeout: 1) {
      return
    }

    let island = app.buttons["Polish release onboarding, Scoutly, Working"]
    XCTAssertTrue(island.waitForExistence(timeout: 3))

    island.hover()

    XCTAssertTrue(expandedSession.waitForExistence(timeout: 2))
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
    XCTAssertTrue(
      app.staticTexts[
        "Reason: Publish the verified branch to the configured GitHub remote"
      ].exists)
    XCTAssertTrue(
      app.staticTexts["Operation: git push -u origin agent/release-readiness"].exists)
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
    let visible = app.buttons["Verify installation flow, Meetly, Completed"]
      .waitForExistence(timeout: 3)
    XCTAssertTrue(visible)
  }

  func testCompletedResultPreviewRendersWhenEnabled() {
    let app = launch(
      arguments: ["--state=completed", "--expanded", "--show-result-previews"])
    let completed = sessionRow(in: app, id: "demo-visual-state")
    XCTAssertTrue(completed.waitForExistence(timeout: 3))
    XCTAssertEqual(
      completed.label,
      "Verify installation flow, Meetly, Completed, All checks passed")
  }

  func testFailedStateIsAccessible() {
    let app = launch(arguments: ["--state=failed", "--expanded"])
    let failedSession = sessionRow(in: app, id: "demo-visual-state")
    XCTAssertTrue(failedSession.waitForExistence(timeout: 3))
    XCTAssertEqual(
      failedSession.label,
      "Repair bridge health, Scoutly, Failed, Bridge self-test failed")
    XCTAssertTrue(app.buttons["Open Diagnostics"].exists)
  }

  func testMultipleSessionListIsAccessible() {
    let app = launch(state: "multiple")
    let activityPilot = sessionRow(in: app, id: "demo-secondary")
    let scoutly = sessionRow(in: app, id: "demo-primary")
    XCTAssertTrue(activityPilot.waitForExistence(timeout: 3))
    XCTAssertEqual(activityPilot.label, "Review diagnostics privacy, ActivityPilot, Working")
    XCTAssertTrue(scoutly.exists)
    XCTAssertEqual(scoutly.label, "Prepare the release candidate, Scoutly, Working")

  }

  func testChatNamesCanBeHiddenWithoutChangingSessionState() {
    let app = launch(arguments: ["--state=working", "--hide-chat-names"])

    XCTAssertTrue(app.buttons["Scoutly, Working"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["Polish release onboarding"].exists)
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

  func testAccountsSettingsOpens() {
    let app = launch(arguments: ["--open-settings"])
    let accountsTab = app.descendants(matching: .any).matching(identifier: "Accounts").firstMatch
    XCTAssertTrue(accountsTab.waitForExistence(timeout: 3))

    accountsTab.click()

    XCTAssertTrue(
      app.staticTexts["Organization billing accounts"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Active local Codex account"].exists)
    XCTAssertTrue(app.staticTexts["No billing accounts"].exists)
  }

  func testSystemSettingsMakesUpdatesDiagnosticsAndSignalsDiscoverable() {
    let app = launch(arguments: ["--open-settings"])
    let systemTab = app.descendants(matching: .any)
      .matching(identifier: "settings-system-tab").firstMatch
    XCTAssertTrue(systemTab.waitForExistence(timeout: 3))

    systemTab.click()

    XCTAssertTrue(app.staticTexts["Caps Lock signal"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Updates"].exists)
    XCTAssertTrue(app.buttons["Run Diagnostics"].exists)
    XCTAssertTrue(app.buttons["Reset App State"].exists)
  }

  func testDiagnosticsOpens() {
    let app = launch(arguments: ["--open-diagnostics"])
    XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 3))
  }

  func testLaunchAssetDiagnosticsUsesHealthyDemoSnapshot() {
    let app = launch(
      arguments: ["--open-diagnostics"],
      environment: ["COWLICK_ASSET_CAPTURE": "1"])
    let reportView = app.textViews.firstMatch
    XCTAssertTrue(reportView.waitForExistence(timeout: 3))
    guard let report = reportView.value as? String else {
      return XCTFail("Diagnostics report is not exposed as text.")
    }

    XCTAssertTrue(report.contains("Launch-asset demo snapshot — not live device data"))
    XCTAssertTrue(report.contains("Hook status: Installed (demo)"))
    XCTAssertTrue(report.contains("Codex hook trust: Trusted (demo)"))
    XCTAssertTrue(report.contains("Helper installed: true"))
    XCTAssertTrue(report.contains("Socket status: listening"))
    XCTAssertFalse(report.localizedCaseInsensitiveContains("hooks are not installed"))
    XCTAssertFalse(report.localizedCaseInsensitiveContains("hook trust: untrusted"))
    XCTAssertFalse(report.localizedCaseInsensitiveContains("hook trust: needs review"))
    XCTAssertFalse(report.contains("macOS: Version"))
    XCTAssertFalse(report.contains("Display 1:"))
  }

  private func launch(state: String) -> XCUIApplication {
    launch(arguments: ["--state=\(state)"])
  }

  private func launch(
    arguments: [String],
    environment: [String: String] = [:],
    autoHoverEnabled: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["--ui-testing"]
      + (autoHoverEnabled ? [] : ["--disable-auto-hover"])
      + arguments
    app.launchEnvironment.merge(environment) { _, replacement in replacement }
    app.launch()
    return app
  }

  private func sessionRow(in app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "session-row-\(id)").firstMatch
  }
}
