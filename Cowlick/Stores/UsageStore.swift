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
  private(set) var isRefreshing = false
  private(set) var lastOfficialRefresh: Date?
  private(set) var lastForecastRefresh: Date?

  let settings: SettingsStore
  private let usageService: any CodexUsageFetching
  private let forecastService: any ResetForecastFetching
  private var refreshTask: Task<Void, Never>?

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

  var primaryMetricAccessibilityLabel: String? {
    guard let percent = primaryDisplayedPercent else { return nil }
    return
      "Codex, \(Int(percent.rounded())) percent \(settings.usageMetricPreference.accessibilityLabel)"
  }

  var officialStatus: String {
    if !settings.showCodexUsage { return "disabled" }
    if let error = officialError { return "unavailable: \(error)" }
    if let snapshot { return "available (\(snapshot.limits.count) windows)" }
    return isRefreshing ? "refreshing" : "not loaded"
  }

  var forecastStatus: String {
    if !settings.showResetForecast { return "disabled" }
    if let error = forecastError { return "unavailable: \(error)" }
    return forecast == nil ? (isRefreshing ? "refreshing" : "not loaded") : "available"
  }

  func refreshIfNeeded(force: Bool = false, now: Date = Date()) {
    clearDisabledSources()

    let refreshOfficial =
      settings.showCodexUsage
      && (force || isStale(lastOfficialRefresh, interval: Self.officialRefreshInterval, now: now))
    let refreshForecast =
      settings.showResetForecast
      && (force || isStale(lastForecastRefresh, interval: Self.forecastRefreshInterval, now: now))

    startRefresh(official: refreshOfficial, forecast: refreshForecast)
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

  private func startRefresh(official refreshOfficial: Bool, forecast refreshForecast: Bool) {
    guard refreshOfficial || refreshForecast, !isRefreshing else { return }

    isRefreshing = true
    refreshTask = Task { [weak self] in
      guard let self else { return }
      if refreshOfficial {
        do {
          snapshot = try await usageService.fetchUsage()
          officialError = nil
        } catch {
          officialError = EventLogger.sanitizeError(error.localizedDescription)
        }
        lastOfficialRefresh = Date()
      }
      if refreshForecast {
        do {
          forecast = try await forecastService.fetchForecast()
          forecastError = nil
        } catch {
          forecastError = EventLogger.sanitizeError(error.localizedDescription)
        }
        lastForecastRefresh = Date()
      }
      isRefreshing = false
    }
  }

  func refreshAfterActivity(now: Date = Date()) {
    guard isStale(lastOfficialRefresh, interval: Self.activityRefreshInterval, now: now) else {
      return
    }
    refreshIfNeeded(force: false, now: now)
  }

  func settingsDidChange() {
    refreshIfNeeded(force: true)
  }

  func reset() {
    refreshTask?.cancel()
    refreshTask = nil
    snapshot = nil
    forecast = nil
    officialError = nil
    forecastError = nil
    lastOfficialRefresh = nil
    lastForecastRefresh = nil
    isRefreshing = false
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
