import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
  static let officialRefreshInterval: TimeInterval = 5 * 60
  static let forecastRefreshInterval: TimeInterval = 15 * 60
  static let menuForecastRefreshInterval: TimeInterval = 30
  static let costRefreshInterval: TimeInterval = 5 * 60
  static let menuCostRefreshInterval: TimeInterval = 60
  static let activityRefreshInterval: TimeInterval = 60

  private(set) var snapshot: CodexUsageSnapshot?
  private(set) var apiCostEstimate: LocalCodexCostEstimate?
  private(set) var forecast: ResetForecast?
  private(set) var officialError: String?
  private(set) var apiCostError: String?
  private(set) var forecastError: String?
  private(set) var isOfficialRefreshing = false
  private(set) var isAPICostRefreshing = false
  private(set) var isForecastRefreshing = false
  private(set) var lastOfficialRefresh: Date?
  private(set) var lastAPICostRefresh: Date?
  private(set) var lastForecastRefresh: Date?

  let settings: SettingsStore
  private let usageService: any CodexUsageFetching
  private let apiCostService: any LocalCodexCostEstimating
  private let forecastService: any ResetForecastFetching
  private var officialRefreshTask: Task<Void, Never>?
  private var apiCostRefreshTask: Task<Void, Never>?
  private var forecastRefreshTask: Task<Void, Never>?
  private var currentOfficialRefreshToken: UUID?
  private var currentAPICostRefreshToken: UUID?
  private var currentForecastRefreshToken: UUID?
  private var pendingAPICostRefreshEnd: Date?

  init(
    settings: SettingsStore,
    usageService: any CodexUsageFetching = CodexUsageService(),
    apiCostService: any LocalCodexCostEstimating = LocalCodexCostService(),
    forecastService: any ResetForecastFetching = ResetForecastService()
  ) {
    self.settings = settings
    self.usageService = usageService
    self.apiCostService = apiCostService
    self.forecastService = forecastService
  }

  var primaryDisplayedPercent: Double? {
    guard let limit = snapshot?.primaryLimit else { return nil }
    return limit.displayedPercent(for: settings.usageMetricPreference)
  }

  var isRefreshing: Bool {
    isOfficialRefreshing || isAPICostRefreshing || isForecastRefreshing
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

  var apiCostStatus: String {
    if !settings.showAPICostEstimate { return "disabled" }
    if let error = apiCostError {
      return apiCostEstimate == nil ? "unavailable: \(error)" : "stale: \(error)"
    }
    if let apiCostEstimate {
      return apiCostEstimate.measurement.coverage == .partial ? "available (partial)" : "available"
    }
    return isAPICostRefreshing ? "refreshing" : "not loaded"
  }

  @discardableResult
  func refreshIfNeeded(force: Bool = false, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()

    let refreshOfficial =
      settings.showCodexUsage
      && (force || isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now))
    let refreshAPICost =
      settings.showAPICostEstimate
      && (force || isStale(lastAPICostRefresh, interval: Self.costRefreshInterval, now: now))
    let refreshForecast =
      settings.showResetForecast
      && (force || isStale(lastForecastRefresh, interval: Self.forecastRefreshInterval, now: now))

    return startRefresh(
      official: refreshOfficial, apiCost: refreshAPICost, forecast: refreshForecast, now: now)
  }

  func refreshForMenuPresentation(now: Date = Date()) {
    clearDisabledSources()

    let refreshOfficial =
      settings.showCodexUsage
      && isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now)
    let refreshAPICost =
      settings.showAPICostEstimate
      && isStale(lastAPICostRefresh, interval: Self.menuCostRefreshInterval, now: now)
    let refreshForecast =
      settings.showResetForecast
      && isStale(lastForecastRefresh, interval: Self.menuForecastRefreshInterval, now: now)

    startRefresh(
      official: refreshOfficial, apiCost: refreshAPICost, forecast: refreshForecast, now: now)
  }

  @discardableResult
  func refreshForecast(force: Bool = true, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showResetForecast else { return nil }
    let shouldRefresh =
      force || isStale(lastForecastRefresh, interval: Self.forecastRefreshInterval, now: now)
    return startRefresh(official: false, apiCost: false, forecast: shouldRefresh, now: now)
  }

  @discardableResult
  func refreshOfficial(force: Bool = true, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showCodexUsage else { return nil }
    let shouldRefresh =
      force || isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now)
    return startRefresh(official: shouldRefresh, apiCost: false, forecast: false, now: now)
  }

  @discardableResult
  func refreshAPICost(force: Bool = true, now: Date = Date()) -> Task<Void, Never>? {
    clearDisabledSources()
    guard settings.showAPICostEstimate else { return nil }
    let shouldRefresh =
      force || isStale(lastAPICostRefresh, interval: Self.costRefreshInterval, now: now)
    return startRefresh(official: false, apiCost: shouldRefresh, forecast: false, now: now)
  }

  @discardableResult
  private func startRefresh(
    official refreshOfficial: Bool,
    apiCost refreshAPICost: Bool,
    forecast refreshForecast: Bool,
    now: Date
  ) -> Task<Void, Never>? {
    var startedTasks: [Task<Void, Never>] = []
    let usageService = usageService
    let apiCostService = apiCostService
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

    if refreshAPICost, apiCostRefreshTask == nil {
      let token = UUID()
      currentAPICostRefreshToken = token
      isAPICostRefreshing = true
      let interval = settings.apiCostWindow.interval(endingAt: now)
      let task = Task(priority: .utility) { [weak self] in
        defer { self?.finishAPICostRefresh(token: token) }
        let result: Result<LocalCodexCostEstimate, Error>
        do {
          result = .success(try await apiCostService.estimate(interval: interval))
        } catch {
          result = .failure(error)
        }
        _ = self?.applyAPICost(result, token: token)
      }
      apiCostRefreshTask = task
      startedTasks.append(task)
    } else if refreshAPICost {
      pendingAPICostRefreshEnd = maxDate(pendingAPICostRefreshEnd, now)
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
    let wrapperPriority: TaskPriority? = refreshAPICost ? .utility : nil
    return Task(priority: wrapperPriority) {
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
    let refreshOfficial =
      settings.showCodexUsage
      && isStale(lastOfficialRefresh, interval: Self.activityRefreshInterval, now: now)
    let refreshAPICost =
      settings.showAPICostEstimate
      && isStale(lastAPICostRefresh, interval: Self.activityRefreshInterval, now: now)
    return startRefresh(
      official: refreshOfficial, apiCost: refreshAPICost, forecast: false, now: now)
  }

  @discardableResult
  func settingsDidChange() -> Task<Void, Never>? {
    invalidateRefresh()
    return refreshIfNeeded(force: true)
  }

  func reset() async {
    invalidateRefresh()
    await apiCostService.resetCache()
    snapshot = nil
    apiCostEstimate = nil
    forecast = nil
    officialError = nil
    apiCostError = nil
    forecastError = nil
    lastOfficialRefresh = nil
    lastAPICostRefresh = nil
    lastForecastRefresh = nil
  }

  private func invalidateRefresh() {
    currentOfficialRefreshToken = nil
    currentAPICostRefreshToken = nil
    currentForecastRefreshToken = nil
    officialRefreshTask?.cancel()
    apiCostRefreshTask?.cancel()
    forecastRefreshTask?.cancel()
    officialRefreshTask = nil
    apiCostRefreshTask = nil
    forecastRefreshTask = nil
    isOfficialRefreshing = false
    isAPICostRefreshing = false
    isForecastRefreshing = false
    pendingAPICostRefreshEnd = nil
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

  private func applyAPICost(
    _ result: Result<LocalCodexCostEstimate, Error>,
    token: UUID
  ) -> Bool {
    guard currentAPICostRefreshToken == token else { return false }
    guard settings.showAPICostEstimate else { return true }
    switch result {
    case .success(let estimate):
      apiCostEstimate = estimate
      apiCostError = nil
    case .failure(let error):
      apiCostError = EventLogger.sanitizeError(error.localizedDescription)
    }
    lastAPICostRefresh = Date()
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

  private func finishAPICostRefresh(token: UUID) {
    guard currentAPICostRefreshToken == token else { return }
    currentAPICostRefreshToken = nil
    apiCostRefreshTask = nil
    isAPICostRefreshing = false
    guard settings.showAPICostEstimate, let pendingEnd = pendingAPICostRefreshEnd else {
      pendingAPICostRefreshEnd = nil
      return
    }
    pendingAPICostRefreshEnd = nil
    startRefresh(official: false, apiCost: true, forecast: false, now: pendingEnd)
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
    if !settings.showAPICostEstimate {
      apiCostEstimate = nil
      apiCostError = nil
      pendingAPICostRefreshEnd = nil
    }
    if !settings.showResetForecast {
      forecast = nil
      forecastError = nil
    }
  }

  private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs else { return rhs }
    return max(lhs, rhs)
  }
}
