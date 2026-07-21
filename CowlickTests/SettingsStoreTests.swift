import XCTest

@testable import Cowlick

@MainActor
final class SettingsStoreTests: XCTestCase {
  func testPrivacyDefaultsAndPersistence() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let first = SettingsStore(defaults: defaults)
    XCTAssertTrue(first.showChatNames)
    XCTAssertFalse(first.showPromptPreviews)
    XCTAssertFalse(first.showResultPreviews)
    XCTAssertFalse(first.capsLockEnabled)
    XCTAssertTrue(first.automaticUpdateChecks)
    XCTAssertTrue(first.showCodexUsage)
    XCTAssertFalse(first.showAPICostEstimate)
    XCTAssertEqual(first.apiCostWindow, .last30Days)
    XCTAssertFalse(first.showResetForecast)
    XCTAssertEqual(first.usageMetricPreference, .remaining)
    XCTAssertEqual(first.menuBarPresentation, .iconAndDetails)
    XCTAssertFalse(first.integrationIntentionallyRemoved)
    first.showPromptPreviews = true
    first.showChatNames = false
    first.approvalTimeout = 35
    first.usageMetricPreference = .used
    first.showAPICostEstimate = true
    first.apiCostWindow = .today
    first.menuBarPresentation = .percentageOnly
    first.integrationIntentionallyRemoved = true

    let second = SettingsStore(defaults: defaults)
    XCTAssertFalse(second.showChatNames)
    XCTAssertTrue(second.showPromptPreviews)
    XCTAssertEqual(second.approvalTimeout, 35)
    XCTAssertEqual(second.usageMetricPreference, .used)
    XCTAssertTrue(second.showAPICostEstimate)
    XCTAssertEqual(second.apiCostWindow, .today)
    XCTAssertEqual(second.menuBarPresentation, .percentageOnly)
    XCTAssertTrue(second.integrationIntentionallyRemoved)
  }

  func testResetRestoresSafeDefaults() {
    let settings = makeTestSettings()
    settings.showChatNames = false
    settings.showPromptPreviews = true
    settings.showResultPreviews = true
    settings.capsLockEnabled = true
    settings.showCodexUsage = false
    settings.showAPICostEstimate = false
    settings.apiCostWindow = .monthToDate
    settings.showResetForecast = true
    settings.usageMetricPreference = .used
    settings.menuBarPresentation = .statusAndPercentage
    settings.integrationIntentionallyRemoved = true
    settings.reset()

    XCTAssertTrue(settings.showChatNames)
    XCTAssertFalse(settings.showPromptPreviews)
    XCTAssertFalse(settings.showResultPreviews)
    XCTAssertFalse(settings.capsLockEnabled)
    XCTAssertTrue(settings.showCodexUsage)
    XCTAssertFalse(settings.showAPICostEstimate)
    XCTAssertEqual(settings.apiCostWindow, .last30Days)
    XCTAssertFalse(settings.showResetForecast)
    XCTAssertEqual(settings.usageMetricPreference, .remaining)
    XCTAssertEqual(settings.menuBarPresentation, .iconAndDetails)
    XCTAssertFalse(settings.integrationIntentionallyRemoved)
  }

  func testUnhealthyIntegrationReopensOnboardingUntilRepair() {
    XCTAssertFalse(
      AppDelegate.shouldOpenOnboarding(
        onboardingComplete: true,
        integrationIntentionallyRemoved: true,
        integrationHealthy: false))
    XCTAssertFalse(
      AppDelegate.shouldOpenOnboarding(
        onboardingComplete: true,
        integrationIntentionallyRemoved: true,
        integrationHealthy: true))
    XCTAssertTrue(
      AppDelegate.shouldOpenOnboarding(
        onboardingComplete: true,
        integrationIntentionallyRemoved: false,
        integrationHealthy: false))
    XCTAssertTrue(
      AppDelegate.shouldOpenOnboarding(
        onboardingComplete: false,
        integrationIntentionallyRemoved: false,
        integrationHealthy: true))
  }

  func testLifecycleEventsRefreshUsageExceptTransportPing() {
    for event in BridgeEventName.allLifecycleEvents {
      XCTAssertTrue(AppDelegate.shouldRefreshUsage(after: event), event.rawValue)
    }
    XCTAssertFalse(AppDelegate.shouldRefreshUsage(after: .ping))
  }

  func testInvalidMetricPreferenceFallsBackToRemaining() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set("sideways", forKey: SettingsStore.Key.usageMetricPreference)

    XCTAssertEqual(SettingsStore(defaults: defaults).usageMetricPreference, .remaining)
  }

  func testInvalidMenuBarPresentationFallsBackToIconAndDetails() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set("hologram", forKey: SettingsStore.Key.menuBarPresentation)

    XCTAssertEqual(SettingsStore(defaults: defaults).menuBarPresentation, .iconAndDetails)
  }

  func testLegacyPreferencesMigrateOnceWithoutOverwritingCurrentValues() {
    let destinationSuite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let sourceDomain = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: destinationSuite)!
    defaults.removePersistentDomain(forName: destinationSuite)
    defaults.set(false, forKey: "showResultPreviews")
    defer {
      defaults.removePersistentDomain(forName: destinationSuite)
    }

    LegacyMigrationService.migratePreferencesIfNeeded(
      destination: defaults,
      destinationDomain: destinationSuite,
      sourceDomain: sourceDomain,
      sourceValues: [
        "showPromptPreviews": true,
        "showResultPreviews": true,
        "approvalTimeout": 55.0,
      ])

    XCTAssertTrue(defaults.bool(forKey: "showPromptPreviews"))
    XCTAssertFalse(defaults.bool(forKey: "showResultPreviews"))
    XCTAssertEqual(defaults.double(forKey: "approvalTimeout"), 55)
    XCTAssertTrue(defaults.bool(forKey: LegacyMigrationService.preferencesMigrationKey))

    LegacyMigrationService.migratePreferencesIfNeeded(
      destination: defaults,
      destinationDomain: destinationSuite,
      sourceDomain: sourceDomain,
      sourceValues: ["showPromptPreviews": false])
    XCTAssertTrue(defaults.bool(forKey: "showPromptPreviews"))
  }
}

extension BridgeEventName {
  fileprivate static let allLifecycleEvents: [Self] = [
    .sessionStart, .working, .approvalRequested, .subagentStarted, .subagentStopped, .completed,
    .failed,
  ]
}
