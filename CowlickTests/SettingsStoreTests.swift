import XCTest

@testable import Cowlick

@MainActor
final class SettingsStoreTests: XCTestCase {
  @MainActor
  func testUITestingSettingsDoNotReuseTheRealApplicationDefaults() {
    let suite = "CowlickUITestingSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: SettingsStore.Key.reducedAnimation)

    let settings = AppServices.makeUITestingSettingsStore(suiteName: suite)

    XCTAssertFalse(settings.reducedAnimation)
    defaults.removePersistentDomain(forName: suite)
  }

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
    XCTAssertTrue(first.showFiveHourQuotaWindow)
    XCTAssertTrue(first.showWeeklyQuotaWindow)
    XCTAssertTrue(first.showSparkQuotaWindow)
    XCTAssertEqual(first.notchLeftWingMetric, .quotaPercentage)
    XCTAssertEqual(first.notchSecondaryMetric, .blank)
    XCTAssertTrue(first.showNotchCurrentWork)
    XCTAssertTrue(first.showNotchIntegrationAlerts)
    XCTAssertTrue(first.showNotchCodexUsage)
    XCTAssertTrue(first.showNotchAPICostEstimate)
    XCTAssertTrue(first.showNotchResetForecast)
    XCTAssertTrue(first.showNotchProviderBilling)
    XCTAssertEqual(first.presentationPreference, .automatic)
    XCTAssertEqual(first.menuBarPresentation, .percentageOnly)
    XCTAssertFalse(first.integrationIntentionallyRemoved)
    first.showPromptPreviews = true
    first.showChatNames = false
    first.approvalTimeout = 35
    first.usageMetricPreference = .used
    first.showFiveHourQuotaWindow = false
    first.showWeeklyQuotaWindow = false
    first.showSparkQuotaWindow = false
    first.notchLeftWingMetric = .resetCountdown
    first.notchSecondaryMetric = .paceBalance
    first.showAPICostEstimate = true
    first.apiCostWindow = .today
    first.menuBarPresentation = .percentageOnly
    first.presentationPreference = .menuBar
    first.integrationIntentionallyRemoved = true
    first.showNotchCurrentWork = false
    first.showNotchIntegrationAlerts = false
    first.showNotchCodexUsage = false
    first.showNotchAPICostEstimate = false
    first.showNotchResetForecast = false
    first.showNotchProviderBilling = false

    let second = SettingsStore(defaults: defaults)
    XCTAssertFalse(second.showChatNames)
    XCTAssertTrue(second.showPromptPreviews)
    XCTAssertEqual(second.approvalTimeout, 35)
    XCTAssertEqual(second.usageMetricPreference, .used)
    XCTAssertFalse(second.showFiveHourQuotaWindow)
    XCTAssertFalse(second.showWeeklyQuotaWindow)
    XCTAssertFalse(second.showSparkQuotaWindow)
    XCTAssertEqual(second.notchLeftWingMetric, .resetCountdown)
    XCTAssertEqual(second.notchSecondaryMetric, .paceBalance)
    XCTAssertTrue(second.showAPICostEstimate)
    XCTAssertEqual(second.apiCostWindow, .today)
    XCTAssertEqual(second.menuBarPresentation, .percentageOnly)
    XCTAssertEqual(second.presentationPreference, .menuBar)
    XCTAssertTrue(second.integrationIntentionallyRemoved)
    XCTAssertFalse(second.showNotchCurrentWork)
    XCTAssertFalse(second.showNotchIntegrationAlerts)
    XCTAssertFalse(second.showNotchCodexUsage)
    XCTAssertFalse(second.showNotchAPICostEstimate)
    XCTAssertFalse(second.showNotchResetForecast)
    XCTAssertFalse(second.showNotchProviderBilling)
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
    settings.showFiveHourQuotaWindow = false
    settings.showWeeklyQuotaWindow = false
    settings.showSparkQuotaWindow = false
    settings.notchLeftWingMetric = .projectedRunway
    settings.notchSecondaryMetric = .resetProbability
    settings.menuBarPresentation = .statusAndPercentage
    settings.integrationIntentionallyRemoved = true
    settings.showNotchCurrentWork = false
    settings.showNotchIntegrationAlerts = false
    settings.showNotchCodexUsage = false
    settings.showNotchAPICostEstimate = false
    settings.showNotchResetForecast = false
    settings.showNotchProviderBilling = false
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
    XCTAssertTrue(settings.showFiveHourQuotaWindow)
    XCTAssertTrue(settings.showWeeklyQuotaWindow)
    XCTAssertTrue(settings.showSparkQuotaWindow)
    XCTAssertEqual(settings.notchLeftWingMetric, .quotaPercentage)
    XCTAssertEqual(settings.notchSecondaryMetric, .blank)
    XCTAssertEqual(settings.presentationPreference, .automatic)
    XCTAssertEqual(settings.menuBarPresentation, .percentageOnly)
    XCTAssertFalse(settings.integrationIntentionallyRemoved)
    XCTAssertTrue(settings.showNotchCurrentWork)
    XCTAssertTrue(settings.showNotchIntegrationAlerts)
    XCTAssertTrue(settings.showNotchCodexUsage)
    XCTAssertTrue(settings.showNotchAPICostEstimate)
    XCTAssertTrue(settings.showNotchResetForecast)
    XCTAssertTrue(settings.showNotchProviderBilling)
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

  func testInvalidNotchSecondaryMetricFallsBackToBlank() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set("horoscope", forKey: SettingsStore.Key.notchSecondaryMetric)

    XCTAssertEqual(SettingsStore(defaults: defaults).notchSecondaryMetric, .blank)
  }

  func testExistingRightWingPreferenceIsPreservedWhenLeftWingPreferenceIsIntroduced() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(
      NotchWingMetric.paceBalance.rawValue,
      forKey: SettingsStore.Key.notchSecondaryMetric)

    let settings = SettingsStore(defaults: defaults)

    XCTAssertEqual(settings.notchLeftWingMetric, .quotaPercentage)
    XCTAssertEqual(settings.notchSecondaryMetric, .paceBalance)
  }

  func testInvalidMenuBarPresentationFallsBackToPercentageOnly() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set("hologram", forKey: SettingsStore.Key.menuBarPresentation)

    XCTAssertEqual(SettingsStore(defaults: defaults).menuBarPresentation, .percentageOnly)
  }

  func testLegacyHiddenNonNotchOverlayMigratesToMenuBar() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(false, forKey: SettingsStore.Key.legacyShowOnNonNotch)

    let settings = SettingsStore(defaults: defaults)

    XCTAssertEqual(settings.presentationPreference, .menuBar)
    XCTAssertEqual(defaults.string(forKey: SettingsStore.Key.presentationPreference), "menuBar")
  }

  func testLegacyShownNonNotchOverlayMigratesToAutomatic() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(true, forKey: SettingsStore.Key.legacyShowOnNonNotch)

    XCTAssertEqual(SettingsStore(defaults: defaults).presentationPreference, .automatic)
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
