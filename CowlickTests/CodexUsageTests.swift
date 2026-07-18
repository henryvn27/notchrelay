import Foundation
import XCTest

@testable import Cowlick

final class CodexUsageTests: XCTestCase {
  func testParsesSingleCurrentSchemaBucket() throws {
    let data = Data(
      #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"planType":"plus","primary":{"usedPercent":23.4,"windowDurationMins":300,"resetsAt":1770000000},"secondary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1770500000}}}}"#
        .utf8)

    let snapshot = try CodexUsageService.parseResponse(data, fetchedAt: .distantPast)

    XCTAssertEqual(snapshot.planType, "plus")
    XCTAssertEqual(snapshot.fetchedAt, .distantPast)
    XCTAssertEqual(snapshot.limits.map(\.name), ["5-hour window", "Weekly window"])
    XCTAssertEqual(snapshot.limits.map(\.usedPercent), [23.4, 62])
  }

  func testParsesMultipleNamedBucketsWithoutMixingWindows() throws {
    let data = Data(
      #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":null},"secondary":null},"model_x":{"limitId":"model_x","limitName":"Model X","planType":"plus","primary":{"usedPercent":80,"windowDurationMins":10080,"resetsAt":null},"secondary":null}}}}"#
        .utf8)

    let snapshot = try CodexUsageService.parseResponse(data)

    XCTAssertEqual(snapshot.limits.count, 2)
    XCTAssertEqual(snapshot.limits[0].id, "codex.primary")
    XCTAssertEqual(snapshot.limits[0].name, "5-hour window · Codex")
    XCTAssertEqual(snapshot.limits[1].id, "model_x.primary")
    XCTAssertEqual(snapshot.limits[1].name, "Weekly window · Model X")
  }

  func testClampsUntrustedPercentages() throws {
    let data = Data(
      #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":-4,"windowDurationMins":300},"secondary":{"usedPercent":150,"windowDurationMins":10080}}}}"#
        .utf8)

    let snapshot = try CodexUsageService.parseResponse(data)
    XCTAssertEqual(snapshot.limits.map(\.usedPercent), [0, 100])
  }

  func testRejectsUnknownOrMalformedResponse() {
    XCTAssertThrowsError(
      try CodexUsageService.parseResponse(Data(#"{"id":7,"result":{}}"#.utf8)))
    XCTAssertThrowsError(try CodexUsageService.parseResponse(Data("not json".utf8)))
  }

  func testResponseLimitIsOneMegabyte() {
    XCTAssertEqual(CodexUsageService.maximumResponseSize, 1_048_576)
  }

  func testLimitDisplaysSelectedMetric() {
    let limit = CodexUsageLimit(
      id: "codex.primary", name: "5-hour window", usedPercent: 24,
      resetsAt: nil, windowDurationMinutes: 300)

    XCTAssertEqual(limit.displayedPercent(for: .used), 24)
    XCTAssertEqual(limit.displayedPercent(for: .remaining), 76)
  }

  func testLimitCalculatesPaceFromResetAndDuration() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let limit = CodexUsageLimit(
      id: "codex.primary", name: "5-hour window", usedPercent: 40,
      resetsAt: now.addingTimeInterval(50 * 60), windowDurationMinutes: 100)

    let pace = try XCTUnwrap(limit.pace(now: now))
    XCTAssertEqual(pace.status, .reserve)
    XCTAssertEqual(pace.expectedUsedPercent, 50, accuracy: 0.001)
    XCTAssertEqual(pace.balancePercent, 10, accuracy: 0.001)
  }

  func testExecutableLocatorUsesFirstExecutableCandidate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data()))
    XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path)

    XCTAssertEqual(
      try CodexExecutableLocator(candidates: [first, second]).locate().standardizedFileURL,
      second.standardizedFileURL
    )
  }
}

private actor UsageFetchRecorder: CodexUsageFetching {
  private(set) var calls = 0

  func fetchUsage() async throws -> CodexUsageSnapshot {
    calls += 1
    return CodexUsageSnapshot(
      limits: [
        CodexUsageLimit(
          id: "codex.primary", name: "5-hour window", usedPercent: 25, resetsAt: nil,
          windowDurationMinutes: 300)
      ],
      planType: "plus",
      fetchedAt: Date()
    )
  }

  func callCount() -> Int { calls }
}

private actor ForecastFetchRecorder: ResetForecastFetching {
  private(set) var calls = 0

  func fetchForecast() async throws -> ResetForecast {
    calls += 1
    return ResetForecast(
      score: 75, resetAnnounced: false, fetchedAt: Date(), nextRefreshAt: nil)
  }

  func callCount() -> Int { calls }
}

@MainActor
final class UsageStoreTests: XCTestCase {
  func testForecastIsNeverFetchedWhileDisabled() async {
    let settings = makeTestSettings()
    settings.showResetForecast = false
    let usage = UsageFetchRecorder()
    let forecast = ForecastFetchRecorder()
    let store = UsageStore(settings: settings, usageService: usage, forecastService: forecast)

    store.refreshIfNeeded(force: true)
    let usageLoaded = await waitUntil { !store.isRefreshing && store.snapshot != nil }
    XCTAssertTrue(usageLoaded)

    let usageCallCount = await usage.callCount()
    let forecastCallCount = await forecast.callCount()
    XCTAssertEqual(usageCallCount, 1)
    XCTAssertEqual(forecastCallCount, 0)
    XCTAssertNil(store.forecast)
  }

  func testEnablingForecastFetchesAndResetClearsMemory() async {
    let settings = makeTestSettings()
    settings.showResetForecast = true
    let store = UsageStore(
      settings: settings,
      usageService: UsageFetchRecorder(),
      forecastService: ForecastFetchRecorder()
    )

    store.refreshIfNeeded(force: true)
    let forecastLoaded = await waitUntil { !store.isRefreshing && store.forecast != nil }
    XCTAssertTrue(forecastLoaded)
    store.reset()

    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.forecast)
    XCTAssertNil(store.lastOfficialRefresh)
    XCTAssertNil(store.lastForecastRefresh)
  }

  func testMenuPresentationRefreshesForecastAfterThirtySeconds() async {
    let settings = makeTestSettings()
    settings.showCodexUsage = false
    settings.showResetForecast = true
    let forecast = ForecastFetchRecorder()
    let store = UsageStore(
      settings: settings,
      usageService: UsageFetchRecorder(),
      forecastService: forecast
    )

    store.refreshIfNeeded(force: true)
    let initiallyLoaded = await waitUntil { !store.isRefreshing && store.forecast != nil }
    XCTAssertTrue(initiallyLoaded)
    guard let firstRefresh = store.lastForecastRefresh else {
      return XCTFail("Expected forecast refresh time")
    }

    store.refreshForMenuPresentation(now: firstRefresh.addingTimeInterval(29))
    let callsBeforeThreshold = await forecast.callCount()
    XCTAssertEqual(callsBeforeThreshold, 1)

    store.refreshForMenuPresentation(now: firstRefresh.addingTimeInterval(31))
    let refreshed = await waitUntil { !store.isRefreshing }
    let callsAfterThreshold = await forecast.callCount()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(callsAfterThreshold, 2)
  }
}
