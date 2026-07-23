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

  func testSimulatedNotchHoverExpandsRecentActivity() {
    let app = launch(
      arguments: ["--simulate-notch", "--usage-demo", "--state=working"],
      autoHoverEnabled: true)
    let expandedSession = sessionRow(in: app, id: "demo-visual-state")
    let island = app.buttons["compact-notch-button"]
    XCTAssertTrue(island.waitForExistence(timeout: 3))

    // Hover a visible wing, not the physical camera housing in the center of a real notch.
    island.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).hover()
    XCTAssertTrue(expandedSession.waitForExistence(timeout: 2))
  }

  func testWorkingCompactNotchShowsQuotaWithoutVisibleTaskCopy() {
    let app = launch(
      arguments: ["--simulate-notch", "--usage-demo", "--state=working"])
    let island = app.buttons["compact-notch-button"]
    XCTAssertTrue(island.waitForExistence(timeout: 3))
    XCTAssertTrue(wait(for: island, labelContaining: "Codex quota, 22 percent remaining"))
    XCTAssertFalse(app.staticTexts["Polish release onboarding"].exists)
    XCTAssertFalse(app.staticTexts["Scoutly"].exists)
    let screenshot = XCTAttachment(screenshot: island.screenshot())
    screenshot.name = "quiet-compact-working"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testCompletedCompactNotchShowsTemporaryIndicatorAndClickRevealsDetails() {
    let app = launch(
      arguments: ["--simulate-notch", "--usage-demo", "--state=completed"])
    let indicator = app.buttons["compact-completion-indicator"]
    XCTAssertTrue(indicator.waitForExistence(timeout: 3))

    // The center of an attached surface is occupied by the physical camera housing. Exercise the
    // visible right wing where the completion mark is actually rendered.
    indicator.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()

    XCTAssertTrue(indicator.waitForNonExistence(timeout: 2))
    XCTAssertTrue(sessionRow(in: app, id: "demo-visual-state").waitForExistence(timeout: 2))
  }

  func testScrollDoesNotExpandCompactNotch() {
    let app = launch(
      arguments: ["--simulate-notch", "--usage-demo", "--state=working"])
    let island = app.buttons["compact-notch-button"]
    XCTAssertTrue(island.waitForExistence(timeout: 3))

    island.scroll(byDeltaX: 0, deltaY: 60)

    XCTAssertFalse(sessionRow(in: app, id: "demo-visual-state").waitForExistence(timeout: 0.5))
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
      arguments: ["--simulate-notch", "--state=completed", "--expanded", "--show-result-previews"])
    let completed = sessionRow(in: app, id: "demo-visual-state")
    XCTAssertTrue(completed.waitForExistence(timeout: 3))
    XCTAssertEqual(
      completed.label,
      "Verify installation flow, Meetly, Completed, All checks passed")
  }

  func testFailedStateIsAccessible() {
    let app = launch(arguments: ["--simulate-notch", "--state=failed", "--expanded"])
    let failedSession = sessionRow(in: app, id: "demo-visual-state")
    XCTAssertTrue(failedSession.waitForExistence(timeout: 3))
    XCTAssertEqual(
      failedSession.label,
      "Repair bridge health, Scoutly, Failed, Bridge self-test failed")
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

  func testPinnedOnlyPreferenceFiltersActiveSessions() {
    let app = launch(
      arguments: ["--simulate-notch", "--state=multiple", "--pinned-sessions-only"])
    let scoutly = sessionRow(in: app, id: "demo-primary")

    XCTAssertTrue(scoutly.waitForExistence(timeout: 3))
    XCTAssertFalse(sessionRow(in: app, id: "demo-secondary").exists)
    XCTAssertTrue(app.staticTexts["1 active session"].exists)

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "pinned-only-active-sessions"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testOverflowSessionListKeepsEndActionsAtTheLogicalBottom() {
    let app = launch(state: "overflow")
    let scrollView = app.scrollViews["session-scroll-view"]
    XCTAssertTrue(scrollView.waitForExistence(timeout: 3))

    scrollView.scroll(byDeltaX: 0, deltaY: 80)

    XCTAssertTrue(sessionRow(in: app, id: "demo-overflow-1").waitForExistence(timeout: 2))
    let endActions = app.descendants(matching: .any)
      .matching(identifier: "notch-end-actions").firstMatch
    XCTAssertTrue(endActions.waitForExistence(timeout: 2))
    XCTAssertGreaterThanOrEqual(endActions.frame.minY, scrollView.frame.maxY - 1)
  }

  func testExpandedNotchIncludesMenuBarInformation() {
    let app = launch(
      arguments: [
        "--simulate-notch", "--usage-demo", "--billing-demo", "--state=working", "--expanded",
      ])

    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "notch-activity-header").firstMatch
        .waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Codex quota"].exists)
    XCTAssertTrue(app.staticTexts["API-price estimate"].exists)
    XCTAssertTrue(app.staticTexts["Reset likelihood"].exists)
    XCTAssertTrue(app.staticTexts["API billing"].waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "provider-billing-account").firstMatch
        .exists)
    XCTAssertFalse(app.popUpButtons["provider-billing-account"].exists)
    XCTAssertFalse(app.staticTexts["Platform"].exists)
    let compactHeader = app.buttons["compact-notch-button"]
    let settings = app.buttons["Settings"]
    XCTAssertTrue(compactHeader.exists)
    XCTAssertTrue(settings.exists)
    let quit = app.buttons["Quit"]
    XCTAssertTrue(quit.exists)
    XCTAssertLessThanOrEqual(compactHeader.frame.width, 300)
    XCTAssertGreaterThanOrEqual(quit.frame.minY, compactHeader.frame.maxY)
  }

  func testExpandedNotchContentCanBeHidden() {
    let app = launch(
      arguments: [
        "--simulate-notch", "--usage-demo", "--billing-demo", "--state=working", "--expanded",
        "--hide-notch-current-work", "--hide-notch-integration-alerts",
        "--hide-notch-codex-usage", "--hide-notch-api-cost",
        "--hide-notch-reset-forecast", "--hide-notch-provider-billing",
      ])

    XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 3))
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "notch-activity-header").firstMatch
        .exists)
    XCTAssertFalse(sessionRow(in: app, id: "demo-visual-state").exists)
    XCTAssertFalse(app.staticTexts["Codex quota"].exists)
    XCTAssertFalse(app.staticTexts["API-price estimate"].exists)
    XCTAssertFalse(app.staticTexts["Reset likelihood"].exists)
    XCTAssertFalse(app.staticTexts["API billing"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "codex-integration-attention")
        .firstMatch.exists)
    XCTAssertTrue(app.buttons["Quit"].exists)
  }

  func testExpandedNotchActionPaddingIsClickable() {
    let app = launch(state: "multiple")
    let primarySession = sessionRow(in: app, id: "demo-primary")
    let settings = app.buttons["Settings"]
    XCTAssertTrue(primarySession.waitForExistence(timeout: 3))
    XCTAssertTrue(settings.waitForExistence(timeout: 3))
    XCTAssertLessThanOrEqual(primarySession.frame.maxY, settings.frame.minY)
    XCTAssertGreaterThanOrEqual(settings.frame.height, 27)

    settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).click()

    XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
  }

  func testChatNamesCanBeHiddenWithoutChangingSessionState() {
    let app = launch(arguments: ["--simulate-notch", "--state=working", "--hide-chat-names"])

    XCTAssertTrue(app.buttons["Scoutly, Working"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["Polish release onboarding"].exists)
  }

  func testOnboardingOpens() {
    let app = launch(arguments: ["--open-onboarding"])
    XCTAssertTrue(
      app.staticTexts["Choose where Cowlick lives."].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Step 1 of 3"].exists)
  }

  func testSettingsOpens() {
    let app = launch(arguments: ["--open-settings"])
    XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
  }

  func testSettingsExposesExpandedNotchContentControls() {
    let app = launch(arguments: ["--open-settings"])
    let identifiers = [
      "settings-notch-current-work",
      "settings-notch-integration-alerts",
      "settings-notch-codex-usage",
      "settings-notch-api-cost",
      "settings-notch-reset-forecast",
      "settings-notch-provider-billing",
      "settings-pinned-sessions-only",
    ]

    for identifier in identifiers {
      XCTAssertTrue(
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
          .waitForExistence(timeout: 3),
        "Missing expanded-notch setting: \(identifier)"
      )
    }

    let pinnedOnlyToggle = app.descendants(matching: .any)
      .matching(identifier: "settings-pinned-sessions-only").firstMatch
    app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
    XCTAssertTrue(pinnedOnlyToggle.isHittable)

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "pinned-only-setting"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testAccountsSettingsOpens() {
    let app = launch(arguments: ["--open-settings"])
    let accountsTab = app.descendants(matching: .any)
      .matching(identifier: "settings-accounts-tab").firstMatch
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
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "settings-caps-lock-flash-count").firstMatch
        .waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Updates"].exists)
    XCTAssertTrue(app.buttons["Run Diagnostics"].exists)
    XCTAssertTrue(app.buttons["Reset App State"].exists)

    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "system-settings-caps-lock-flashes"
    screenshot.lifetime = .keepAlways
    add(screenshot)
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
    launch(arguments: ["--simulate-notch", "--state=\(state)"])
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

  private func wait(
    for element: XCUIElement,
    labelContaining expectedValue: String,
    timeout: TimeInterval = 3
  ) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", expectedValue)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
