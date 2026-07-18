import XCTest

@testable import Cowlick

@MainActor
final class SettingsStoreTests: XCTestCase {
  func testPrivacyDefaultsAndPersistence() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let first = SettingsStore(defaults: defaults)
    XCTAssertFalse(first.showPromptPreviews)
    XCTAssertFalse(first.showResultPreviews)
    XCTAssertFalse(first.capsLockEnabled)
    XCTAssertTrue(first.automaticUpdateChecks)
    XCTAssertTrue(first.showCodexUsage)
    XCTAssertFalse(first.showResetForecast)
    XCTAssertEqual(first.usageMetricPreference, .remaining)
    first.showPromptPreviews = true
    first.approvalTimeout = 35
    first.usageMetricPreference = .used

    let second = SettingsStore(defaults: defaults)
    XCTAssertTrue(second.showPromptPreviews)
    XCTAssertEqual(second.approvalTimeout, 35)
    XCTAssertEqual(second.usageMetricPreference, .used)
  }

  func testResetRestoresSafeDefaults() {
    let settings = makeTestSettings()
    settings.showPromptPreviews = true
    settings.showResultPreviews = true
    settings.capsLockEnabled = true
    settings.showCodexUsage = false
    settings.showResetForecast = true
    settings.usageMetricPreference = .used
    settings.reset()

    XCTAssertFalse(settings.showPromptPreviews)
    XCTAssertFalse(settings.showResultPreviews)
    XCTAssertFalse(settings.capsLockEnabled)
    XCTAssertTrue(settings.showCodexUsage)
    XCTAssertFalse(settings.showResetForecast)
    XCTAssertEqual(settings.usageMetricPreference, .remaining)
  }

  func testInvalidMetricPreferenceFallsBackToRemaining() {
    let suite = "com.henryvn27.CowlickTests.Settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set("sideways", forKey: SettingsStore.Key.usageMetricPreference)

    XCTAssertEqual(SettingsStore(defaults: defaults).usageMetricPreference, .remaining)
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
