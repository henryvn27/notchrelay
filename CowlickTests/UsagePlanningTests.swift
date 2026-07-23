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
    XCTAssertEqual(onPace.exhaustionForecast?.estimatedAt, reset)
    XCTAssertEqual(onPace.exhaustionForecast?.willLastThroughReset, true)

    let reserve = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 30, duration: duration, resetsAt: reset), now: now))
    XCTAssertEqual(reserve.reservePercent, 10, accuracy: 0.000_001)
    XCTAssertEqual(reserve.deficitPercent, 0)
    XCTAssertEqual(reserve.status, .reserve)
    XCTAssertGreaterThan(try XCTUnwrap(reserve.exhaustionForecast?.estimatedAt), reset)
    XCTAssertEqual(reserve.exhaustionForecast?.willLastThroughReset, true)

    let deficit = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 55, duration: duration, resetsAt: reset), now: now))
    XCTAssertEqual(deficit.reservePercent, 0)
    XCTAssertEqual(deficit.deficitPercent, 15, accuracy: 0.000_001)
    XCTAssertEqual(deficit.status, .deficit)
    XCTAssertLessThan(try XCTUnwrap(deficit.exhaustionForecast?.estimatedAt), reset)
    XCTAssertEqual(deficit.exhaustionForecast?.willLastThroughReset, false)
    XCTAssertEqual(
      try XCTUnwrap(deficit.exhaustionForecast?.timeBeforeReset),
      reset.timeIntervalSince(try XCTUnwrap(deficit.exhaustionForecast?.estimatedAt)),
      accuracy: 0.000_001
    )
  }

  func testPaceClampsFiniteUsagePercentages() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(500)

    let low = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: -20, duration: 1_000, resetsAt: reset), now: now))
    XCTAssertEqual(low.actualUsedPercent, 0)
    XCTAssertEqual(low.reservePercent, 50)
    XCTAssertNil(low.exhaustionForecast)

    let high = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 120, duration: 1_000, resetsAt: reset), now: now))
    XCTAssertEqual(high.actualUsedPercent, 100)
    XCTAssertEqual(high.deficitPercent, 50)
    XCTAssertEqual(high.exhaustionForecast?.estimatedAt, now)
  }

  func testForecastSuppressesWeakUsageButStartsAtOnePercent() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let reset = now.addingTimeInterval(500)

    for usedPercent in [0, 0.5, 0.999] {
      let pace = try XCTUnwrap(
        QuotaPaceCalculator.pace(
          for: QuotaWindow(usedPercent: usedPercent, duration: 1_000, resetsAt: reset),
          now: now
        ))
      XCTAssertNil(pace.exhaustionForecast)
    }

    let measurable = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: QuotaWindow(usedPercent: 1, duration: 1_000, resetsAt: reset), now: now))
    XCTAssertNotNil(measurable.exhaustionForecast)
  }

  func testForecastRemainsAnchoredToSnapshotObservationAsItAges() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1_000)
    let reset = fetchedAt.addingTimeInterval(600)
    let window = QuotaWindow(usedPercent: 40, duration: 1_000, resetsAt: reset)

    let fresh = try XCTUnwrap(
      QuotaPaceCalculator.pace(for: window, observedAt: fetchedAt, now: fetchedAt))
    let aged = try XCTUnwrap(
      QuotaPaceCalculator.pace(
        for: window,
        observedAt: fetchedAt,
        now: fetchedAt.addingTimeInterval(100)
      ))

    XCTAssertEqual(fresh.exhaustionForecast?.estimatedAt, reset)
    XCTAssertEqual(aged.exhaustionForecast?.estimatedAt, reset)
    XCTAssertNotEqual(fresh.expectedUsedPercent, aged.expectedUsedPercent)
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
      status: .reserve,
      exhaustionForecast: nil
    )

    XCTAssertEqual(pace.expectedDisplayedPercent(for: .used), 40)
    XCTAssertEqual(pace.expectedDisplayedPercent(for: .remaining), 60)
  }

  func testCompactSecondaryMetricsUseTheLongestQuotaWindow() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexUsageSnapshot(
      limits: [
        CodexUsageLimit(
          id: "five-hour",
          name: "5 hour",
          usedPercent: 20,
          resetsAt: now.addingTimeInterval(4 * 3_600),
          windowDurationMinutes: 5 * 60
        ),
        CodexUsageLimit(
          id: "weekly",
          name: "Weekly",
          usedPercent: 30,
          resetsAt: now.addingTimeInterval(4 * 86_400),
          windowDurationMinutes: 7 * 24 * 60
        ),
      ],
      planType: "pro",
      fetchedAt: now
    )
    let forecast = ResetForecast(
      score: 73,
      resetAnnounced: false,
      fetchedAt: now,
      nextRefreshAt: nil
    )

    XCTAssertNil(
      CompactUsageSecondaryFormatter.value(
        for: .blank,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      ))
    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .usageMeaning,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      )?.text,
      "left"
    )
    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .windowProgress,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      )?.text,
      "43% thru"
    )
    let pace = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .paceBalance,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      ))
    XCTAssertEqual(pace.text, "+13%")
    XCTAssertEqual(pace.tone, .positive)
    let behind = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .paceBalance,
        snapshot: CodexUsageSnapshot(
          limits: [
            CodexUsageLimit(
              id: "weekly",
              name: "Weekly",
              usedPercent: 55,
              resetsAt: now.addingTimeInterval(4 * 86_400),
              windowDurationMinutes: 7 * 24 * 60
            )
          ],
          planType: "pro",
          fetchedAt: now
        ),
        preference: .remaining,
        forecast: forecast,
        now: now
      ))
    XCTAssertEqual(behind.text, "-12%")
    XCTAssertEqual(behind.tone, .caution)
    let critical = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .paceBalance,
        snapshot: CodexUsageSnapshot(
          limits: [
            CodexUsageLimit(
              id: "weekly",
              name: "Weekly",
              usedPercent: 58,
              resetsAt: now.addingTimeInterval(4 * 86_400),
              windowDurationMinutes: 7 * 24 * 60
            )
          ],
          planType: "pro",
          fetchedAt: now
        ),
        preference: .remaining,
        forecast: forecast,
        now: now
      ))
    XCTAssertEqual(critical.text, "-15%")
    XCTAssertEqual(critical.tone, .critical)
    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .resetCountdown,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      )?.text,
      "4d"
    )
    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .projectedRunway,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      )?.text,
      "+3d"
    )
    let runwayShortfall = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .projectedRunway,
        snapshot: CodexUsageSnapshot(
          limits: [
            CodexUsageLimit(
              id: "weekly",
              name: "Weekly",
              usedPercent: 80,
              resetsAt: now.addingTimeInterval(4 * 86_400),
              windowDurationMinutes: 7 * 24 * 60
            )
          ],
          planType: "pro",
          fetchedAt: now
        ),
        preference: .remaining,
        forecast: forecast,
        now: now
      ))
    XCTAssertEqual(runwayShortfall.text, "-3d")
    XCTAssertEqual(runwayShortfall.tone, .critical)
    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .resetProbability,
        snapshot: snapshot,
        preference: .remaining,
        forecast: forecast,
        now: now
      )?.text,
      "73% reset"
    )
  }

  func testCompactSecondaryMetricsStayBlankWhenTheirSourceIsUnavailable() {
    for metric in NotchSecondaryMetric.allCases where metric != .blank {
      XCTAssertNil(
        CompactUsageSecondaryFormatter.value(
          for: metric,
          snapshot: nil,
          preference: .remaining,
          forecast: nil
        ),
        metric.rawValue
      )
    }
  }

  func testCompactResetCountdownDoesNotDependOnPaceConfidence() {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexUsageSnapshot(
      limits: [
        CodexUsageLimit(
          id: "weekly",
          name: "Weekly",
          usedPercent: 0,
          resetsAt: now.addingTimeInterval(7 * 86_400 - 60),
          windowDurationMinutes: 7 * 24 * 60
        )
      ],
      planType: nil,
      fetchedAt: now
    )

    XCTAssertEqual(
      CompactUsageSecondaryFormatter.value(
        for: .resetCountdown,
        snapshot: snapshot,
        preference: .remaining,
        forecast: nil,
        now: now
      )?.text,
      "7d"
    )
    XCTAssertNil(
      CompactUsageSecondaryFormatter.value(
        for: .paceBalance,
        snapshot: snapshot,
        preference: .remaining,
        forecast: nil,
        now: now
      ))
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
