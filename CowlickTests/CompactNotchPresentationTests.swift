import Foundation
import XCTest

@testable import Cowlick

final class CompactNotchPresentationTests: XCTestCase {
  func testQuotaWindowClassificationUsesStableDurationsAndDisplayNameFallbacks() {
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "Whatever", minutes: 300)),
      .fiveHour
    )
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "5 hr limit", minutes: nil)),
      .fiveHour
    )
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "Five-hour window", minutes: nil)),
      .fiveHour
    )
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "Whatever", minutes: 10_080)),
      .weekly
    )
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "1 week quota", minutes: nil)),
      .weekly
    )
    XCTAssertEqual(
      UsageSectionView.quotaWindowKind(for: limit(name: "7-day window", minutes: nil)),
      .weekly
    )
  }

  func testSparkClassificationOverridesStandardWindowDuration() {
    let spark = limit(
      id: "gpt_5_3_codex_spark.primary",
      name: "5-hour window · GPT-5.3-Codex Spark",
      minutes: 300
    )

    XCTAssertEqual(UsageSectionView.quotaWindowKind(for: spark), .spark)
    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        [spark], showFiveHour: true, showWeekly: true, showSpark: false),
      []
    )
    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        [spark], showFiveHour: false, showWeekly: false, showSpark: true),
      [spark]
    )
  }

  func testEachQuotaToggleIsIndependentAndUnknownWindowsRemainVisible() {
    let fiveHour = limit(id: "codex.primary", name: "5-hour window", minutes: 300)
    let weekly = limit(id: "codex.secondary", name: "Weekly window", minutes: 10_080)
    let spark = limit(id: "codex_spark.primary", name: "GPT-5.3-Codex-Spark", minutes: 300)
    let future = limit(id: "codex.rollover", name: "12-hour rollover", minutes: 720)
    let limits = [fiveHour, weekly, spark, future]

    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        limits, showFiveHour: true, showWeekly: false, showSpark: false),
      [fiveHour, future]
    )
    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        limits, showFiveHour: false, showWeekly: true, showSpark: false),
      [weekly, future]
    )
    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        limits, showFiveHour: false, showWeekly: false, showSpark: true),
      [spark, future]
    )
    XCTAssertEqual(
      UsageSectionView.visibleQuotaLimits(
        limits, showFiveHour: false, showWeekly: false, showSpark: false),
      [future]
    )
  }

  func testSharedWingFormatterProvidesPercentageAndExplicitResetTime() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let snapshot = CodexUsageSnapshot(
      limits: [
        limit(
          id: "codex.primary",
          name: "Weekly window",
          usedPercent: 25,
          resetsAt: now.addingTimeInterval(4 * 86_400),
          minutes: 10_080
        )
      ],
      planType: "pro",
      fetchedAt: now
    )

    let percentage = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .quotaPercentage,
        snapshot: snapshot,
        preference: .remaining,
        forecast: nil,
        now: now
      ))
    XCTAssertEqual(percentage.text, "75%")
    XCTAssertEqual(percentage.accessibilityLabel, "Codex quota, 75 percent remaining")

    let reset = try XCTUnwrap(
      CompactUsageSecondaryFormatter.value(
        for: .resetCountdown,
        snapshot: snapshot,
        preference: .remaining,
        forecast: nil,
        now: now
      ))
    XCTAssertEqual(reset.text, "4d")
    XCTAssertEqual(reset.accessibilityLabel, "Quota resets in 4d")
  }

  func testCompactForecastMakesLikelihoodPrimaryAndHorizonExplicit() {
    let forecast = ResetForecast(
      score: 73,
      resetAnnounced: false,
      fetchedAt: nil,
      nextRefreshAt: nil
    )

    XCTAssertEqual(UsageSectionView.compactForecastPrimaryText(forecast), "73%")
    XCTAssertEqual(
      UsageSectionView.compactForecastAccessibilityValue(forecast),
      "73 percent likelihood in the next 48 hours"
    )

    let announced = ResetForecast(
      score: 100,
      resetAnnounced: true,
      fetchedAt: nil,
      nextRefreshAt: nil
    )
    XCTAssertEqual(UsageSectionView.compactForecastPrimaryText(announced), "Announced")
    XCTAssertEqual(
      UsageSectionView.compactForecastAccessibilityValue(announced),
      "A Codex quota reset has been announced"
    )
  }

  private func limit(
    id: String = "codex.primary",
    name: String,
    usedPercent: Double = 25,
    resetsAt: Date? = nil,
    minutes: Int?
  ) -> CodexUsageLimit {
    CodexUsageLimit(
      id: id,
      name: name,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      windowDurationMinutes: minutes
    )
  }
}
