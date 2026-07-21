import Foundation
import XCTest

@testable import Cowlick

private actor APICostFetchRecorder: LocalCodexCostEstimating {
  private(set) var intervals: [DateInterval] = []
  private(set) var priorities: [TaskPriority] = []
  private(set) var resetCount = 0

  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate {
    intervals.append(interval)
    priorities.append(Task.currentPriority)
    return LocalCodexCostEstimate(
      measurement: CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: Decimal(string: "4.25")!,
        currency: "USD",
        interval: interval,
        coverage: .thisMac,
        pricingAsOf: Date(timeIntervalSince1970: 1_784_505_600)
      ),
      pricedTokenCount: 1_000,
      unpricedTokenCount: 0,
      excludedToolFees: true,
      exclusionReasons: [],
      scannedFileCount: 1,
      refreshedAt: interval.end
    )
  }

  func resetCache() async { resetCount += 1 }

  func recordedIntervals() -> [DateInterval] { intervals }
  func recordedPriorities() -> [TaskPriority] { priorities }
}

private actor SuspendedAPICostRecorder: LocalCodexCostEstimating {
  private var intervals: [DateInterval] = []
  private var continuations: [Int: CheckedContinuation<LocalCodexCostEstimate, Never>] = [:]
  private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate {
    let call = intervals.count
    intervals.append(interval)
    return await withCheckedContinuation { continuation in
      continuations[call] = continuation
      resumeSatisfiedCallWaiters()
    }
  }

  func resetCache() async {}

  func waitForCalls(_ count: Int) async {
    guard intervals.count < count else { return }
    await withCheckedContinuation { callWaiters.append((count, $0)) }
  }

  func resume(call: Int) {
    guard let continuation = continuations.removeValue(forKey: call) else { return }
    let interval = intervals[call]
    continuation.resume(returning: makeEstimate(interval: interval))
  }

  func recordedIntervals() -> [DateInterval] { intervals }

  private func resumeSatisfiedCallWaiters() {
    let ready = callWaiters.filter { intervals.count >= $0.0 }
    callWaiters.removeAll { intervals.count >= $0.0 }
    for (_, waiter) in ready { waiter.resume() }
  }

  private func makeEstimate(interval: DateInterval) -> LocalCodexCostEstimate {
    LocalCodexCostEstimate(
      measurement: CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: Decimal(string: "4.25")!,
        currency: "USD",
        interval: interval,
        coverage: .thisMac,
        pricingAsOf: Date(timeIntervalSince1970: 1_784_505_600)
      ),
      pricedTokenCount: 1_000,
      unpricedTokenCount: 0,
      excludedToolFees: true,
      exclusionReasons: [],
      scannedFileCount: 1,
      refreshedAt: interval.end
    )
  }
}

private struct UnusedCodexUsageService: CodexUsageFetching {
  func fetchUsage() async throws -> CodexUsageSnapshot {
    throw UnexpectedUsageStoreServiceCall.officialQuota
  }
}

private struct UnusedResetForecastService: ResetForecastFetching {
  func fetchForecast() async throws -> ResetForecast {
    throw UnexpectedUsageStoreServiceCall.resetForecast
  }
}

private enum UnexpectedUsageStoreServiceCall: Error {
  case officialQuota
  case resetForecast
}

@MainActor
final class UsageStoreAPICostTests: XCTestCase {
  func testCostScanStartsAtUtilityPriorityWithoutForegroundDonation() async throws {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = APICostFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )

    _ = store.refreshAPICost(force: true)
    let completed = await waitUntil { !store.isAPICostRefreshing }
    let priorities = await recorder.recordedPriorities()

    XCTAssertTrue(completed)
    XCTAssertEqual(try XCTUnwrap(priorities.first), .utility)
  }

  func testActivityRefreshesCostWithoutOfficialQuotaAndUsesInclusiveLast30Days() async throws {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = APICostFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )
    let now = Date(timeIntervalSince1970: 1_784_640_000)

    await store.refreshAfterActivity(now: now)?.value

    let recordedIntervals = await recorder.recordedIntervals()
    let interval = try XCTUnwrap(recordedIntervals.first)
    XCTAssertEqual(interval.end, now)
    let expectedStart = Calendar.current.date(
      byAdding: .day,
      value: -29,
      to: Calendar.current.startOfDay(for: now)
    )
    XCTAssertEqual(interval.start, expectedStart)
    XCTAssertEqual(store.apiCostEstimate?.measurement.amount, Decimal(string: "4.25"))
    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.forecast)
  }

  func testSelectedCostWindowUsesTodayAndMonthToDateBoundaries() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(
      from: DateComponents(year: 2026, month: 7, day: 20, hour: 12, minute: 30))!

    let today = APICostWindow.today.interval(endingAt: now, calendar: calendar)
    let month = APICostWindow.monthToDate.interval(endingAt: now, calendar: calendar)

    XCTAssertEqual(
      calendar.dateComponents([.year, .month, .day, .hour], from: today.start),
      DateComponents(year: 2026, month: 7, day: 20, hour: 0))
    XCTAssertEqual(
      calendar.dateComponents([.year, .month, .day, .hour], from: month.start),
      DateComponents(year: 2026, month: 7, day: 1, hour: 0))
  }

  func testActivityCostRefreshIsThrottledForOneMinute() async throws {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = APICostFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )

    await store.refreshIfNeeded(force: true)?.value
    let refreshedAt = try XCTUnwrap(store.lastAPICostRefresh)
    let throttled = store.refreshAfterActivity(
      now: refreshedAt.addingTimeInterval(UsageStore.activityRefreshInterval - 1))

    XCTAssertNil(throttled)
    let recordedIntervals = await recorder.recordedIntervals()
    XCTAssertEqual(recordedIntervals.count, 1)
  }

  func testDisablingCostEstimateClearsItWithoutRefreshingOtherSources() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = APICostFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )

    await store.refreshIfNeeded(force: true)?.value
    XCTAssertNotNil(store.apiCostEstimate)

    settings.showAPICostEstimate = false
    await store.settingsDidChange()?.value

    XCTAssertNil(store.apiCostEstimate)
    XCTAssertNil(store.apiCostError)
    XCTAssertEqual(store.apiCostStatus, "disabled")
    let recordedIntervals = await recorder.recordedIntervals()
    XCTAssertEqual(recordedIntervals.count, 1)
  }

  func testActivityDuringInflightCostScanCoalescesOneTrailingRefreshAtLatestTime() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = SuspendedAPICostRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )
    let first = Date(timeIntervalSince1970: 1_784_640_000)
    let latest = first.addingTimeInterval(120)

    let initialRefresh = store.refreshAPICost(force: true, now: first)
    await recorder.waitForCalls(1)
    store.refreshAfterActivity(now: first.addingTimeInterval(61))
    store.refreshAfterActivity(now: latest)
    await recorder.resume(call: 0)
    await initialRefresh?.value

    await recorder.waitForCalls(2)
    let intervals = await recorder.recordedIntervals()
    XCTAssertEqual(intervals.count, 2)
    XCTAssertEqual(intervals[1].end, latest)

    await recorder.resume(call: 1)
    let completed = await waitUntil { !store.isAPICostRefreshing }
    XCTAssertTrue(completed)
  }

  func testResetClearsDisplayedEstimateAndServiceCache() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showAPICostEstimate = true
    settings.showResetForecast = false
    let recorder = APICostFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedCodexUsageService(),
      apiCostService: recorder,
      forecastService: UnusedResetForecastService()
    )

    await store.refreshAPICost(force: true)?.value
    XCTAssertNotNil(store.apiCostEstimate)

    await store.reset()

    XCTAssertNil(store.apiCostEstimate)
    XCTAssertNil(store.lastAPICostRefresh)
    let resetCount = await recorder.resetCount
    XCTAssertEqual(resetCount, 1)
  }
}
