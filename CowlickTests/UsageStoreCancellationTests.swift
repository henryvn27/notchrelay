import Foundation
import XCTest

@testable import Cowlick

private final class WeakReference<Value: AnyObject> {
  weak var value: Value?

  init(_ value: Value?) {
    self.value = value
  }
}

private actor SuspendedFetch<Value: Sendable> {
  private var nextCall = 0
  private var continuations: [Int: CheckedContinuation<Value, Error>] = [:]
  private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var cancelledCalls = Set<Int>()
  private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func value() async throws -> Value {
    let call = nextCall
    nextCall += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        continuations[call] = continuation
        resumeSatisfiedCallWaiters()
      }
    } onCancel: {
      Task { await self.recordCancellation(of: call) }
    }
  }

  func waitForCalls(_ count: Int) async {
    guard nextCall < count else { return }
    await withCheckedContinuation { callWaiters.append((count, $0)) }
  }

  func waitForCancellation(of call: Int) async {
    guard !cancelledCalls.contains(call) else { return }
    await withCheckedContinuation { cancellationWaiters.append((call, $0)) }
  }

  func resume(call: Int, returning value: Value) {
    continuations.removeValue(forKey: call)?.resume(returning: value)
  }

  func resume(call: Int, throwing error: Error) {
    continuations.removeValue(forKey: call)?.resume(throwing: error)
  }

  private func recordCancellation(of call: Int) {
    cancelledCalls.insert(call)
    let waiters = cancellationWaiters.filter { $0.0 == call }
    cancellationWaiters.removeAll { $0.0 == call }
    for (_, waiter) in waiters { waiter.resume() }
  }

  private func resumeSatisfiedCallWaiters() {
    let waiters = callWaiters.filter { nextCall >= $0.0 }
    callWaiters.removeAll { nextCall >= $0.0 }
    for (_, waiter) in waiters { waiter.resume() }
  }
}

private struct SuspendedUsageService: CodexUsageFetching {
  let fetch: SuspendedFetch<CodexUsageSnapshot>

  func fetchUsage() async throws -> CodexUsageSnapshot {
    try await fetch.value()
  }
}

private struct SuspendedForecastService: ResetForecastFetching {
  let fetch: SuspendedFetch<ResetForecast>

  func fetchForecast() async throws -> ResetForecast {
    try await fetch.value()
  }
}

private struct UnusedUsageService: CodexUsageFetching {
  func fetchUsage() async throws -> CodexUsageSnapshot {
    throw SuspendedFetchError.unexpectedCall
  }
}

private struct UnusedForecastService: ResetForecastFetching {
  func fetchForecast() async throws -> ResetForecast {
    throw SuspendedFetchError.unexpectedCall
  }
}

private actor FetchCallCounter {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private struct CountingForecastService: ResetForecastFetching {
  let counter: FetchCallCounter

  func fetchForecast() async throws -> ResetForecast {
    await counter.record()
    throw SuspendedFetchError.unexpectedCall
  }
}

private enum SuspendedFetchError: LocalizedError {
  case unavailable
  case unexpectedCall

  var errorDescription: String? { "Suspended fetch failed." }
}

private func usageSnapshot(usedPercent: Double, fetchedAt: Date = Date()) -> CodexUsageSnapshot {
  CodexUsageSnapshot(
    limits: [
      CodexUsageLimit(
        id: "codex.primary", name: "5-hour window", usedPercent: usedPercent, resetsAt: nil,
        windowDurationMinutes: 300)
    ],
    planType: "plus",
    fetchedAt: fetchedAt
  )
}

@MainActor
final class UsageStoreCancellationTests: XCTestCase {
  func testOfficialOnlyRefreshDoesNotContactForecastSource() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = true
    settings.showResetForecast = true
    let usageFetch = SuspendedFetch<CodexUsageSnapshot>()
    let forecastCalls = FetchCallCounter()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: usageFetch),
      forecastService: CountingForecastService(counter: forecastCalls)
    )

    let refresh = store.refreshOfficial(force: true)
    await usageFetch.waitForCalls(1)
    await usageFetch.resume(call: 0, returning: usageSnapshot(usedPercent: 25))
    await refresh?.value

    let forecastCallCount = await forecastCalls.count
    XCTAssertEqual(forecastCallCount, 0)
    XCTAssertEqual(store.snapshot?.primaryLimit?.usedPercent, 25)
    XCTAssertNil(store.forecast)
  }

  func testBlockedOfficialFetchDoesNotDelayForecastApplication() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = true
    settings.showResetForecast = true
    let usageFetch = SuspendedFetch<CodexUsageSnapshot>()
    let forecastFetch = SuspendedFetch<ResetForecast>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: usageFetch),
      forecastService: SuspendedForecastService(fetch: forecastFetch)
    )
    let expectedForecast = ResetForecast(
      score: 72, resetAnnounced: false, fetchedAt: Date(), nextRefreshAt: nil)

    let refresh = store.refreshIfNeeded(force: true)
    await usageFetch.waitForCalls(1)
    await forecastFetch.waitForCalls(1)
    await forecastFetch.resume(call: 0, returning: expectedForecast)

    let forecastApplied = await waitUntil { store.forecast == expectedForecast }
    XCTAssertTrue(forecastApplied)
    XCTAssertTrue(store.isOfficialRefreshing)
    XCTAssertFalse(store.isForecastRefreshing)

    await store.reset()
    await usageFetch.waitForCancellation(of: 0)
    await usageFetch.resume(call: 0, throwing: CancellationError())
    await refresh?.value
  }

  func testFailedRefreshRetainsLastSuccessfulForecastAsStale() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showResetForecast = true
    let fetch = SuspendedFetch<ResetForecast>()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedUsageService(),
      forecastService: SuspendedForecastService(fetch: fetch)
    )
    let successfulForecast = ResetForecast(
      score: 64, resetAnnounced: false, fetchedAt: Date(), nextRefreshAt: nil)

    let firstRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    await fetch.resume(call: 0, returning: successfulForecast)
    await firstRefresh?.value

    let failedRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(2)
    await fetch.resume(call: 1, throwing: SuspendedFetchError.unavailable)
    await failedRefresh?.value

    XCTAssertEqual(store.forecast, successfulForecast)
    XCTAssertNotNil(store.forecastError)
    XCTAssertTrue(store.forecastStatus.hasPrefix("stale:"))
  }

  func testResetInvalidatesPendingOfficialSuccess() async {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )

    let refresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    await store.reset()
    await fetch.waitForCancellation(of: 0)
    await fetch.resume(call: 0, returning: usageSnapshot(usedPercent: 25))
    await refresh?.value

    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.officialError)
    XCTAssertNil(store.lastOfficialRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testResetInvalidatesPendingForecastError() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showResetForecast = true
    let fetch = SuspendedFetch<ResetForecast>()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedUsageService(),
      forecastService: SuspendedForecastService(fetch: fetch)
    )

    let refresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    await store.reset()
    await fetch.waitForCancellation(of: 0)
    await fetch.resume(call: 0, throwing: SuspendedFetchError.unavailable)
    await refresh?.value

    XCTAssertNil(store.forecast)
    XCTAssertNil(store.forecastError)
    XCTAssertNil(store.lastForecastRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testDisablingOfficialUsageInvalidatesPendingError() async {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )

    let refresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    settings.showCodexUsage = false
    store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    await fetch.resume(call: 0, throwing: SuspendedFetchError.unavailable)
    await refresh?.value

    XCTAssertEqual(store.officialStatus, "disabled")
    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.officialError)
    XCTAssertNil(store.lastOfficialRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testDisablingForecastInvalidatesPendingSuccess() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showResetForecast = true
    let fetch = SuspendedFetch<ResetForecast>()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedUsageService(),
      forecastService: SuspendedForecastService(fetch: fetch)
    )

    let refresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    settings.showResetForecast = false
    store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    await fetch.resume(
      call: 0,
      returning: ResetForecast(
        score: 75, resetAnnounced: false, fetchedAt: Date(), nextRefreshAt: nil))
    await refresh?.value

    XCTAssertEqual(store.forecastStatus, "disabled")
    XCTAssertNil(store.forecast)
    XCTAssertNil(store.forecastError)
    XCTAssertNil(store.lastForecastRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testNewerOfficialRefreshOwnsStateWhenCancelledRefreshSucceedsLate() async throws {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )
    let newerSnapshot = usageSnapshot(usedPercent: 80, fetchedAt: .distantFuture)

    let olderRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    let newerRefresh = store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    await fetch.waitForCalls(2)
    await fetch.resume(call: 1, returning: newerSnapshot)
    await newerRefresh?.value
    let newerRefreshDate = try XCTUnwrap(store.lastOfficialRefresh)

    await fetch.resume(
      call: 0, returning: usageSnapshot(usedPercent: 10, fetchedAt: .distantPast))
    await olderRefresh?.value

    XCTAssertEqual(store.snapshot, newerSnapshot)
    XCTAssertNil(store.officialError)
    XCTAssertEqual(store.lastOfficialRefresh, newerRefreshDate)
    XCTAssertFalse(store.isRefreshing)
  }

  func testNewerOfficialRefreshOwnsStateWhenCancelledRefreshFailsLate() async throws {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )
    let newerSnapshot = usageSnapshot(usedPercent: 80, fetchedAt: .distantFuture)

    let olderRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    let newerRefresh = store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    await fetch.waitForCalls(2)
    await fetch.resume(call: 1, returning: newerSnapshot)
    await newerRefresh?.value
    let newerRefreshDate = try XCTUnwrap(store.lastOfficialRefresh)

    await fetch.resume(call: 0, throwing: SuspendedFetchError.unavailable)
    await olderRefresh?.value

    XCTAssertEqual(store.snapshot, newerSnapshot)
    XCTAssertNil(store.officialError)
    XCTAssertEqual(store.lastOfficialRefresh, newerRefreshDate)
    XCTAssertFalse(store.isRefreshing)
  }

  func testCancelledOfficialRefreshFinishingFirstDoesNotClearNewerRefresh() async {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    let store = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )

    let olderRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    let newerRefresh = store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    await fetch.waitForCalls(2)

    await fetch.resume(call: 0, returning: usageSnapshot(usedPercent: 10))
    await olderRefresh?.value

    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.officialError)
    XCTAssertNil(store.lastOfficialRefresh)
    XCTAssertTrue(store.isRefreshing)

    let newerSnapshot = usageSnapshot(usedPercent: 80)
    await fetch.resume(call: 1, returning: newerSnapshot)
    await newerRefresh?.value

    XCTAssertEqual(store.snapshot, newerSnapshot)
    XCTAssertNil(store.officialError)
    XCTAssertNotNil(store.lastOfficialRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testReenabledForecastOwnsStateWhenDisabledRefreshFinishesFirst() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showResetForecast = true
    let fetch = SuspendedFetch<ResetForecast>()
    let store = UsageStore(
      settings: settings,
      usageService: UnusedUsageService(),
      forecastService: SuspendedForecastService(fetch: fetch)
    )

    let olderRefresh = store.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    settings.showResetForecast = false
    store.settingsDidChange()
    await fetch.waitForCancellation(of: 0)
    settings.showResetForecast = true
    let newerRefresh = store.settingsDidChange()
    await fetch.waitForCalls(2)

    await fetch.resume(
      call: 0,
      returning: ResetForecast(
        score: 10, resetAnnounced: false, fetchedAt: .distantPast, nextRefreshAt: nil))
    await olderRefresh?.value

    XCTAssertNil(store.forecast)
    XCTAssertNil(store.forecastError)
    XCTAssertNil(store.lastForecastRefresh)
    XCTAssertTrue(store.isRefreshing)

    let newerForecast = ResetForecast(
      score: 80, resetAnnounced: true, fetchedAt: .distantFuture, nextRefreshAt: nil)
    await fetch.resume(call: 1, returning: newerForecast)
    await newerRefresh?.value

    XCTAssertEqual(store.forecast, newerForecast)
    XCTAssertNil(store.forecastError)
    XCTAssertNotNil(store.lastForecastRefresh)
    XCTAssertFalse(store.isRefreshing)
  }

  func testResetDoesNotRetainStoreWhileCancelledFetchRemainsSuspended() async {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let fetch = SuspendedFetch<CodexUsageSnapshot>()
    var store: UsageStore? = UsageStore(
      settings: settings,
      usageService: SuspendedUsageService(fetch: fetch),
      forecastService: UnusedForecastService()
    )
    let weakStore = WeakReference(store)

    let refresh = store?.refreshIfNeeded(force: true)
    await fetch.waitForCalls(1)
    await store?.reset()
    await fetch.waitForCancellation(of: 0)
    store = nil

    XCTAssertNil(weakStore.value)
    await fetch.resume(call: 0, returning: usageSnapshot(usedPercent: 25))
    await refresh?.value
  }
}
