import Foundation
import XCTest

@testable import Cowlick

final class UsagePlanningTests: XCTestCase {
  func testSupportedProvidersRoundTripThroughCodable() throws {
    let providers = UsageProvider.allCases
    XCTAssertEqual(
      providers,
      [.codex, .openAIAPI, .claude, .anthropicAPI, .cursor, .githubCopilot, .gemini]
    )

    let data = try JSONEncoder().encode(providers)
    XCTAssertEqual(try JSONDecoder().decode([UsageProvider].self, from: data), providers)
  }

  func testProviderAccountsRemainDistinctWithinOneProvider() throws {
    let credentialA = CredentialReference(id: UUID())
    let credentialB = CredentialReference(id: UUID())
    let accountA = ProviderAccount(
      id: UUID(), provider: .codex, alias: "Personal", credentialReference: credentialA)
    let accountB = ProviderAccount(
      id: UUID(), provider: .codex, alias: "Work", credentialReference: credentialB)

    XCTAssertNotEqual(accountA.id, accountB.id)
    XCTAssertEqual(accountA.provider, accountB.provider)
    XCTAssertNotEqual(accountA.credentialReference, accountB.credentialReference)

    let data = try JSONEncoder().encode([accountA, accountB])
    XCTAssertEqual(
      try JSONDecoder().decode([ProviderAccount].self, from: data), [accountA, accountB])
  }

  func testMetricPreferenceShowsUsedOrRemainingAndClampsFiniteInput() {
    XCTAssertEqual(UsageMetricPreference.used.displayedPercent(forUsedPercent: 35), 35)
    XCTAssertEqual(UsageMetricPreference.remaining.displayedPercent(forUsedPercent: 35), 65)
    XCTAssertEqual(UsageMetricPreference.used.displayedPercent(forUsedPercent: -5), 0)
    XCTAssertEqual(UsageMetricPreference.remaining.displayedPercent(forUsedPercent: 125), 0)
    XCTAssertNil(UsageMetricPreference.used.displayedPercent(forUsedPercent: .nan))
    XCTAssertNil(UsageMetricPreference.remaining.displayedPercent(forUsedPercent: .infinity))
  }

  func testPaceCalculatesOnPaceReserveAndDeficit() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let duration: TimeInterval = 1_000
    let reset = now.addingTimeInterval(600)

    let onPace = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 40, duration: duration, resetsAt: reset), now: now))
    XCTAssertEqual(onPace.expectedUsedPercent, 40, accuracy: 0.000_001)
    XCTAssertEqual(onPace.balancePercent, 0, accuracy: 0.000_001)
    XCTAssertEqual(onPace.status, .onPace)

    let reserve = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 30, duration: duration, resetsAt: reset), now: now))
    XCTAssertEqual(reserve.reservePercent, 10, accuracy: 0.000_001)
    XCTAssertEqual(reserve.deficitPercent, 0)
    XCTAssertEqual(reserve.status, .reserve)

    let deficit = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 55, duration: duration, resetsAt: reset), now: now))
    XCTAssertEqual(deficit.reservePercent, 0)
    XCTAssertEqual(deficit.deficitPercent, 15, accuracy: 0.000_001)
    XCTAssertEqual(deficit.status, .deficit)
  }

  func testPaceClampsFiniteUsagePercentages() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(500)

    let low = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: -20, duration: 1_000, resetsAt: reset), now: now))
    XCTAssertEqual(low.actualUsedPercent, 0)
    XCTAssertEqual(low.reservePercent, 50)

    let high = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 120, duration: 1_000, resetsAt: reset), now: now))
    XCTAssertEqual(high.actualUsedPercent, 100)
    XCTAssertEqual(high.deficitPercent, 50)
  }

  func testPaceSuppressesUnreliableTiming() {
    let now = Date(timeIntervalSince1970: 1_000)
    let validReset = now.addingTimeInterval(500)
    let unreliable: [QuotaWindow] = [
      QuotaWindow(usedPercent: 10, duration: nil, resetsAt: validReset),
      QuotaWindow(usedPercent: 10, duration: 0, resetsAt: validReset),
      QuotaWindow(usedPercent: 10, duration: -1, resetsAt: validReset),
      QuotaWindow(usedPercent: 10, duration: .nan, resetsAt: validReset),
      QuotaWindow(usedPercent: 10, duration: .infinity, resetsAt: validReset),
      QuotaWindow(usedPercent: 10, duration: 1_000, resetsAt: nil),
      QuotaWindow(usedPercent: 10, duration: 1_000, resetsAt: now),
      QuotaWindow(usedPercent: 10, duration: 1_000, resetsAt: now.addingTimeInterval(-1)),
      QuotaWindow(usedPercent: 10, duration: 1_000, resetsAt: now.addingTimeInterval(1_001)),
      QuotaWindow(usedPercent: .nan, duration: 1_000, resetsAt: validReset),
      QuotaWindow(usedPercent: .infinity, duration: 1_000, resetsAt: validReset),
    ]

    for window in unreliable {
      XCTAssertNil(QuotaPaceCalculator.pace(for: window, now: now))
    }
  }

  func testPaceRequiresAtLeastThreePercentElapsed() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertNil(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(
          usedPercent: 1, duration: 1_000, resetsAt: now.addingTimeInterval(971)),
        now: now
      ))

    let threshold = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(
          usedPercent: 1, duration: 1_000, resetsAt: now.addingTimeInterval(970)),
        now: now
      ))
    XCTAssertEqual(threshold.expectedUsedPercent, 3, accuracy: 0.000_001)
  }

  func testExpectedPaceMarkerMirrorsSelectedMetric() throws {
    let pace = QuotaPace(
      expectedUsedPercent: 40,
      actualUsedPercent: 30,
      balancePercent: 10,
      status: .reserve
    )

    XCTAssertEqual(pace.expectedDisplayedPercent(for: .used), 40)
    XCTAssertEqual(pace.expectedDisplayedPercent(for: .remaining), 60)
  }

  func testCostMeasurementsPreserveMeaningCoverageAndPricingDate() throws {
    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 1_000),
      end: Date(timeIntervalSince1970: 2_000)
    )
    let pricingDate = Date(timeIntervalSince1970: 900)
    let measurements = [
      CostMeasurement(
        kind: .actualBilled,
        amount: Decimal(string: "12.34")!,
        currency: "USD",
        interval: interval,
        coverage: .accountWide,
        pricingAsOf: nil
      ),
      CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: Decimal(string: "98.76")!,
        currency: "USD",
        interval: interval,
        coverage: .thisMac,
        pricingAsOf: pricingDate
      ),
      CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: 5,
        currency: "EUR",
        interval: interval,
        coverage: .partial,
        pricingAsOf: pricingDate
      ),
    ]

    let data = try JSONEncoder().encode(measurements)
    XCTAssertEqual(try JSONDecoder().decode([CostMeasurement].self, from: data), measurements)
    XCTAssertEqual(measurements[0].kind, .actualBilled)
    XCTAssertNil(measurements[0].pricingAsOf)
    XCTAssertEqual(measurements[1].kind, .apiEquivalentEstimate)
    XCTAssertEqual(measurements[1].coverage, .thisMac)
    XCTAssertEqual(measurements[2].coverage, .partial)
  }
}
