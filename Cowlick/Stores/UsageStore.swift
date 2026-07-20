import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
  static let officialRefreshInterval: TimeInterval = 5 * 60
  static let forecastRefreshInterval: TimeInterval = 15 * 60
  static let menuForecastRefreshInterval: TimeInterval = 30
  static let activityRefreshInterval: TimeInterval = 60

  private(set) var snapshot: CodexUsageSnapshot?
  private(set) var forecast: ResetForecast?
  private(set) var officialError: String?
  private(set) var forecastError: String?
  private(set) var isOfficialRefreshing = false
  private(set) var isForecastRefreshing = false
  private(set) var lastOfficialRefresh: Date?
  private(set) var lastForecastRefresh: Date?

  let settings: SettingsStore
  private let usageService: any CodexUsageFetching
  private let forecastService: any ResetForecastFetching
  private var officialRefreshTask: Task<Void, Never>?
  private var forecastRefreshTask: Task<Void, Never>?
  private var currentOfficialRefreshToken: UUID?
  private var currentForecastRefreshToken: UUID?

  init(
    settings: SettingsStore,
    usageService: any CodexUsageFetching = CodexUsageService(),
    forecastService: any ResetForecastFetching = ResetForecastService()
  ) {
    self.settings = settings
    self.usageService = usageService
    self.forecastService = forecastService
  }

  var primaryDisplayedPercent: Double? {
    guard let limit = snapshot?.primaryLimit else { return nil }
    return limit.displayedPercent(for: settings.usageMetricPreference)
  }

  var isRefreshing: Bool {
    isOfficialRefreshing || isForecastRefreshing
  }

  var primaryMetricAccessibilityLabel: String? {
    guard let percent = primaryDisplayedPercent else { return nil }
    return
      "Codex, \(Int(percent.rounded())) percent \(settings.usageMetricPreference.accessibilityLabel)"
  }

  var officialStatus: String {
    if !settings.showCodexUsage { return "disabled" }
    if let error = officialError {
      return snapshot == nil ? "unavailable: \(error)" : "stale: \(error)"
    }
    if let snapshot { return "available (\(snapshot.limits.count) windows)" }
    return isOfficialRefreshing ? "refreshing" : "not loaded"
  }

  var forecastStatus: String {
    if !settings.showResetForecast { return "disabled" }
    if let error = forecastError {
      return forecast == nil ? "unavailable: \(error)" : "stale: \(error)"
    }
    return forecast == nil ? (isForecastRefreshing ? "refreshing" : "not loaded") : "available"
  }

  @discardableResult
  func refreshIfNeeded(force: Bool = false, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()

    let refreshOfficial =
      settings.showCodexUsage
      && (force || isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now))
    let refreshForecast =
      settings.showResetForecast
      && (force || isStale(lastForecastRefresh, interval: Self.forecastRefreshInterval, now: now))

    return startRefresh(official: refreshOfficial, forecast: refreshForecast)
  }

  func refreshForMenuPresentation(now: Date = Date()) {
    clearDisabledSources()

    let refreshOfficial =
      settings.showCodexUsage
      && isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now)
    let refreshForecast =
      settings.showResetForecast
      && isStale(lastForecastRefresh, interval: Self.menuForecastRefreshInterval, now: now)

    startRefresh(official: refreshOfficial, forecast: refreshForecast)
  }

  @discardableResult
  func refreshForecast(force: Bool = true, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showResetForecast else { return nil }
    let shouldRefresh =
      force || isStale(lastForecastRefresh, interval: Self.forecastRefreshInterval, now: now)
    return startRefresh(official: false, forecast: shouldRefresh)
  }

  @discardableResult
  func refreshOfficial(force: Bool = true, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showCodexUsage else { return nil }
    let shouldRefresh =
      force || isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now)
    return startRefresh(official: shouldRefresh, forecast: false)
  }

  @discardableResult
  private func startRefresh(official refreshOfficial: Bool, forecast refreshForecast: Bool)
    -> Task<Void, Never>?
  {
    var startedTasks: [Task<Void, Never>] = []
    let usageService = usageService
    let forecastService = forecastService

    if refreshOfficial, officialRefreshTask == nil {
      let token = UUID()
      currentOfficialRefreshToken = token
      isOfficialRefreshing = true
      let task = Task { [weak self] in
        defer { self?.finishOfficialRefresh(token: token) }
        let result: Result<CodexUsageSnapshot, Error>
        do {
          result = .success(try await usageService.fetchUsage())
        } catch {
          result = .failure(error)
        }
        _ = self?.applyOfficial(result, token: token)
      }
      officialRefreshTask = task
      startedTasks.append(task)
    }

    if refreshForecast, forecastRefreshTask == nil {
      let token = UUID()
      currentForecastRefreshToken = token
      isForecastRefreshing = true
      let task = Task { [weak self] in
        defer { self?.finishForecastRefresh(token: token) }
        let result: Result<ResetForecast, Error>
        do {
          result = .success(try await forecastService.fetchForecast())
        } catch {
          result = .failure(error)
        }
        _ = self?.applyForecast(result, token: token)
      }
      forecastRefreshTask = task
      startedTasks.append(task)
    }

    guard !startedTasks.isEmpty else { return nil }
    let tasks = startedTasks
    return Task {
      await withTaskCancellationHandler {
        for task in tasks {
          await task.value
        }
      } onCancel: {
        for task in tasks {
          task.cancel()
        }
      }
    }
  }

  @discardableResult
  func refreshAfterActivity(now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showCodexUsage,
      isStale(lastOfficialRefresh, interval: Self.activityRefreshInterval, now: now)
    else {
      return nil
    }
    return startRefresh(official: true, forecast: false)
  }

  @discardableResult
  func settingsDidChange() -> Task<Void, Never>? {
    invalidateRefresh()
    return refreshIfNeeded(force: true)
  }

  func reset() {
    invalidateRefresh()
    snapshot = nil
    forecast = nil
    officialError = nil
    forecastError = nil
    lastOfficialRefresh = nil
    lastForecastRefresh = nil
  }

  private func invalidateRefresh() {
    currentOfficialRefreshToken = nil
    currentForecastRefreshToken = nil
    officialRefreshTask?.cancel()
    forecastRefreshTask?.cancel()
    officialRefreshTask = nil
    forecastRefreshTask = nil
    isOfficialRefreshing = false
    isForecastRefreshing = false
  }

  private func applyOfficial(
    _ result: Result<CodexUsageSnapshot, Error>,
    token: UUID
  ) -> Bool {
    guard currentOfficialRefreshToken == token else { return false }
    guard settings.showCodexUsage else { return true }
    switch result {
    case .success(let fetchedSnapshot):
      snapshot = fetchedSnapshot
      officialError = nil
    case .failure(let error):
      officialError = EventLogger.sanitizeError(error.localizedDescription)
    }
    lastOfficialRefresh = Date()
    return true
  }

  private func applyForecast(
    _ result: Result<ResetForecast, Error>,
    token: UUID
  ) -> Bool {
    guard currentForecastRefreshToken == token else { return false }
    guard settings.showResetForecast else { return true }
    switch result {
    case .success(let fetchedForecast):
      forecast = fetchedForecast
      forecastError = nil
    case .failure(let error):
      forecastError = EventLogger.sanitizeError(error.localizedDescription)
    }
    lastForecastRefresh = Date()
    return true
  }

  private func finishOfficialRefresh(token: UUID) {
    guard currentOfficialRefreshToken == token else { return }
    currentOfficialRefreshToken = nil
    officialRefreshTask = nil
    isOfficialRefreshing = false
  }

  private func finishForecastRefresh(token: UUID) {
    guard currentForecastRefreshToken == token else { return }
    currentForecastRefreshToken = nil
    forecastRefreshTask = nil
    isForecastRefreshing = false
  }

  private func isStale(_ date: Date?, interval: TimeInterval, now: Date) -> Bool {
    guard let date else { return true }
    return now.timeIntervalSince(date) >= interval
  }

  private func clearDisabledSources() {
    if !settings.showCodexUsage {
      snapshot = nil
      officialError = nil
    }
    if !settings.showResetForecast {
      forecast = nil
      forecastError = nil
    }
  }
}
