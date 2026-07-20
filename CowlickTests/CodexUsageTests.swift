import Darwin
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

  func testProbeCompletesNormalHandshakeWithBoundedRunner() async throws {
    let fixture = try ExecutableFixture(
      script: """
        #!/bin/sh
        IFS= read -r initialize || exit 3
        case "$initialize" in *'"id":0'*) ;; *) exit 3 ;; esac
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 3 ;; esac
        printf '%s\n' '{"id":0,"result":{}}'
        IFS= read -r initialized || exit 3
        case "$initialized" in
          *'"method":"initialized"'*) ;;
          *) exit 3 ;;
        esac
        IFS= read -r request || exit 3
        case "$request" in *'"id":2'*) ;; *) exit 3 ;; esac
        case "$request" in
          *'"method":"account/rateLimits/read"'*|*'"method":"account\\/rateLimits\\/read"'*) ;;
          *) exit 3 ;;
        esac
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300}}}}'
        while IFS= read -r _; do :; done
        """)
    defer { fixture.remove() }
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }))

    let snapshot = try await service.fetchUsage()

    XCTAssertEqual(snapshot.planType, "plus")
    XCTAssertEqual(snapshot.limits.map(\.usedPercent), [25])
  }

  func testProbeMapsOversizedStreamingOutputToResponseTooLarge() async throws {
    let fixture = try ExecutableFixture(script: "#!/bin/sh\nexec /usr/bin/yes malicious\n")
    defer { fixture.remove() }
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }))

    do {
      _ = try await service.fetchUsage()
      XCTFail("Expected oversized output to fail")
    } catch {
      XCTAssertEqual(error as? CodexUsageServiceError, .responseTooLarge)
    }
  }

  func testProbeMapsEarlyAndNonzeroExitToProcessFailed() async throws {
    for status in [0, 7] {
      let fixture = try ExecutableFixture(script: "#!/bin/sh\nexit \(status)\n")
      defer { fixture.remove() }
      let service = CodexUsageService(
        locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }))

      do {
        _ = try await service.fetchUsage()
        XCTFail("Expected exit \(status) to fail")
      } catch {
        XCTAssertEqual(error as? CodexUsageServiceError, .processFailed)
      }
    }
  }

  func testProbeTimeoutMapsToProcessFailedWithinBound() async throws {
    let fixture = try ExecutableFixture(
      script: "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n")
    defer { fixture.remove() }
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      timeout: 0.05
    )
    let startedAt = Date()

    do {
      _ = try await service.fetchUsage()
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error as? CodexUsageServiceError, .processFailed)
    }

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  func testProbeCancellationKillsAppServerProcessGroup() async throws {
    let parentPIDURL = temporaryURL("usage-parent")
    let descendantPIDURL = temporaryURL("usage-descendant")
    let fixture = try ExecutableFixture(
      script: stubbornProcessTreeScript(
        parentPID: parentPIDURL, descendantPID: descendantPIDURL))
    defer { remove([fixture.url, parentPIDURL, descendantPIDURL]) }
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      timeout: 5
    )
    let task = Task { try await service.fetchUsage() }
    guard let parentPID = await waitForProcessID(at: parentPIDURL),
      let descendantPID = await waitForProcessID(at: descendantPIDURL)
    else {
      task.cancel()
      return XCTFail("Expected app-server process tree to start")
    }
    defer {
      Darwin.kill(parentPID, SIGKILL)
      Darwin.kill(descendantPID, SIGKILL)
    }
    let startedAt = Date()

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let processTreeExited = await waitForProcessesToExit([parentPID, descendantPID])
    XCTAssertTrue(processTreeExited)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  func testCancellationStopsLocatorAndSkipsLaterCandidates() async throws {
    let parentPIDURL = temporaryURL("locator-parent")
    let descendantPIDURL = temporaryURL("locator-descendant")
    let laterCandidateMarker = temporaryURL("locator-later-candidate")
    let first = try ExecutableFixture(
      script: stubbornProcessTreeScript(
        parentPID: parentPIDURL, descendantPID: descendantPIDURL))
    let second = try ExecutableFixture(
      script: "#!/bin/sh\nprintf reached > '\(laterCandidateMarker.path)'\nprintf 'codex-cli 1.0'\n"
    )
    defer {
      remove([
        first.url, second.url, parentPIDURL, descendantPIDURL, laterCandidateMarker,
      ])
    }
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [first.url, second.url]),
      timeout: 5
    )
    let task = Task { try await service.fetchUsage() }
    guard let parentPID = await waitForProcessID(at: parentPIDURL),
      let descendantPID = await waitForProcessID(at: descendantPIDURL)
    else {
      task.cancel()
      return XCTFail("Expected locator validation process tree to start")
    }
    defer {
      Darwin.kill(parentPID, SIGKILL)
      Darwin.kill(descendantPID, SIGKILL)
    }

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let processTreeExited = await waitForProcessesToExit([parentPID, descendantPID])
    XCTAssertTrue(processTreeExited)
    XCTAssertFalse(FileManager.default.fileExists(atPath: laterCandidateMarker.path))
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

  func testExecutableLocatorSkipsCandidateThatFailsValidation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data()))
    XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path)

    XCTAssertEqual(
      try CodexExecutableLocator(
        candidates: [first, second],
        validator: { $0.standardizedFileURL == second.standardizedFileURL }
      ).locate().standardizedFileURL,
      second.standardizedFileURL
    )
  }

  func testExecutableLocatorCachesUnchangedValidatedExecutable() throws {
    let directory = temporaryURL("locator-cache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = directory.appendingPathComponent("validations")
    let executable = try makeCodexExecutable(
      at: directory.appendingPathComponent("codex"), counter: counter)
    let locator = CodexExecutableLocator(candidates: [executable])

    XCTAssertEqual(try locator.locate(), executable)
    XCTAssertEqual(try locator.locate(), executable)

    XCTAssertEqual(try validationCount(at: counter), 1)
  }

  func testExecutableLocatorRevalidatesReplacedExecutable() throws {
    let directory = temporaryURL("locator-replacement")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = directory.appendingPathComponent("validations")
    let executable = directory.appendingPathComponent("codex")
    _ = try makeCodexExecutable(at: executable, counter: counter)
    let locator = CodexExecutableLocator(candidates: [executable])

    XCTAssertEqual(try locator.locate(), executable)
    try FileManager.default.removeItem(at: executable)
    _ = try makeCodexExecutable(at: executable, counter: counter)
    XCTAssertEqual(try locator.locate(), executable)

    XCTAssertEqual(try validationCount(at: counter), 2)
  }

  func testExecutableLocatorFallsThroughAfterCachedExecutableIsDeleted() throws {
    let directory = temporaryURL("locator-fallback")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = directory.appendingPathComponent("validations")
    let first = try makeCodexExecutable(
      at: directory.appendingPathComponent("first"), counter: counter)
    let second = try makeCodexExecutable(
      at: directory.appendingPathComponent("second"), counter: counter)
    let locator = CodexExecutableLocator(candidates: [first, second])

    XCTAssertEqual(try locator.locate(), first)
    try FileManager.default.removeItem(at: first)

    XCTAssertEqual(try locator.locate(), second)
    XCTAssertEqual(try validationCount(at: counter), 2)
  }

  func testExecutableLocatorStillPrefersNewHigherPriorityCandidate() throws {
    let directory = temporaryURL("locator-priority")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = directory.appendingPathComponent("validations")
    let first = directory.appendingPathComponent("first")
    let second = try makeCodexExecutable(
      at: directory.appendingPathComponent("second"), counter: counter)
    let locator = CodexExecutableLocator(candidates: [first, second])

    XCTAssertEqual(try locator.locate(), second)
    _ = try makeCodexExecutable(at: first, counter: counter)

    XCTAssertEqual(try locator.locate(), first)
    XCTAssertEqual(try validationCount(at: counter), 2)
  }

  func testExecutableLocatorDoesNotCacheCustomValidatorResults() throws {
    let directory = temporaryURL("locator-custom-validator")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex")
    let marker = directory.appendingPathComponent("valid")
    XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
    XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))
    let locator = CodexExecutableLocator(
      candidates: [executable],
      validator: { _ in FileManager.default.fileExists(atPath: marker.path) }
    )

    XCTAssertEqual(try locator.locate(), executable)
    try FileManager.default.removeItem(at: marker)

    XCTAssertThrowsError(try locator.locate()) { error in
      XCTAssertEqual(error as? CodexExecutableLocatorError, .notFound)
    }
  }

  func testExecutableLocatorPrefersRunningApplicationThenNewestInstalledApplication() throws {
    let running = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    let installed = URL(fileURLWithPath: "/Applications/Codex.app")
    let expected = running.appendingPathComponent("Contents/Resources/codex")

    let locator = CodexExecutableLocator(
      environment: [:],
      runningApplicationURLs: [running],
      installedApplicationURLs: [installed],
      validator: { $0 == expected }
    )

    XCTAssertEqual(try locator.locate(), expected)
  }

  func testExecutableLocatorSortsInstalledApplicationsByNumericBuildVersion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let older = try makeApplication(named: "Older", build: "5103", in: directory)
    let newer = try makeApplication(named: "Newer", build: "5551", in: directory)

    XCTAssertEqual(CodexExecutableLocator.newestFirst([older, newer]), [newer, older])
  }

  func testExecutableValidationRejectsExecutableThatIsNotCodex() throws {
    XCTAssertFalse(
      CodexExecutableLocator.isWorkingCodexExecutable(URL(fileURLWithPath: "/bin/true")))
  }

  private func makeApplication(named name: String, build: String, in directory: URL) throws -> URL {
    let application = directory.appendingPathComponent("\(name).app")
    let contents = application.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleVersion": build],
      format: .xml,
      options: 0
    )
    try info.write(to: contents.appendingPathComponent("Info.plist"))
    return application
  }

  private func makeCodexExecutable(at url: URL, counter: URL) throws -> URL {
    let script = """
      #!/bin/sh
      printf '1\\n' >> '\(counter.path)'
      printf 'codex-cli 1.0.0\\n'
      """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func validationCount(at url: URL) throws -> Int {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
  }

  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-\(name)-\(UUID().uuidString)")
  }

  private func remove(_ urls: [URL]) {
    for url in urls { try? FileManager.default.removeItem(at: url) }
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
  func testResetCancelsRunningUsageProcessTree() async throws {
    let parentPIDURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-store-parent-\(UUID().uuidString)")
    let descendantPIDURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-store-descendant-\(UUID().uuidString)")
    let fixture = try ExecutableFixture(
      script: stubbornProcessTreeScript(
        parentPID: parentPIDURL, descendantPID: descendantPIDURL))
    defer {
      fixture.remove()
      try? FileManager.default.removeItem(at: parentPIDURL)
      try? FileManager.default.removeItem(at: descendantPIDURL)
    }
    let settings = makeTestSettings()
    settings.showCodexUsage = true
    settings.showResetForecast = false
    let service = CodexUsageService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      timeout: 5
    )
    let store = UsageStore(
      settings: settings,
      usageService: service,
      forecastService: ForecastFetchRecorder()
    )

    store.refreshIfNeeded(force: true)
    guard let parentPID = await waitForProcessID(at: parentPIDURL),
      let descendantPID = await waitForProcessID(at: descendantPIDURL)
    else {
      store.reset()
      return XCTFail("Expected UsageStore process tree to start")
    }
    defer {
      Darwin.kill(parentPID, SIGKILL)
      Darwin.kill(descendantPID, SIGKILL)
    }

    store.reset()

    let processTreeExited = await waitForProcessesToExit([parentPID, descendantPID])
    XCTAssertTrue(processTreeExited)
  }

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
