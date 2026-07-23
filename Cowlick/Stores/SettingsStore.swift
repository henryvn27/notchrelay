import Foundation
import Observation

enum CompletionVisibility: String, CaseIterable, Identifiable, Sendable {
  case twoSeconds
  case fourSeconds
  case eightSeconds
  case untilClicked

  var id: String { rawValue }

  var label: String {
    switch self {
    case .twoSeconds: "2 seconds"
    case .fourSeconds: "4 seconds"
    case .eightSeconds: "8 seconds"
    case .untilClicked: "Until clicked"
    }
  }

  var seconds: TimeInterval? {
    switch self {
    case .twoSeconds: 2
    case .fourSeconds: 4
    case .eightSeconds: 8
    case .untilClicked: nil
    }
  }
}

enum PreferredDisplay: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case builtIn
  case main

  var id: String { rawValue }
  var label: String {
    switch self {
    case .automatic: "Automatic"
    case .builtIn: "Built-in display"
    case .main: "Main display"
    }
  }
}

@MainActor
@Observable
final class SettingsStore {
  enum Key {
    static let showChatNames = "showChatNames"
    static let showPromptPreviews = "showPromptPreviews"
    static let showResultPreviews = "showResultPreviews"
    static let completionVisibility = "completionVisibility"
    static let approvalTimeout = "approvalTimeout"
    static let autoExpandApprovals = "autoExpandApprovals"
    static let capsLockEnabled = "capsLockEnabled"
    static let capsLockFlashCount = "capsLockFlashCount"
    static let legacyShowOnNonNotch = "showOnNonNotch"
    static let presentationPreference = "presentationPreference"
    static let preferredDisplay = "preferredDisplay"
    static let reducedAnimation = "reducedAnimation"
    static let automaticUpdateChecks = "automaticUpdateChecks"
    static let automaticUpdateDownloads = "automaticUpdateDownloads"
    static let showCodexUsage = "showCodexUsage"
    static let showAPICostEstimate = "showAPICostEstimate"
    static let apiCostWindow = "apiCostWindow"
    static let showResetForecast = "showResetForecast"
    static let usageMetricPreference = "usageMetricPreference"
    static let showFiveHourQuotaWindow = "showFiveHourQuotaWindow"
    static let showWeeklyQuotaWindow = "showWeeklyQuotaWindow"
    static let showSparkQuotaWindow = "showSparkQuotaWindow"
    static let notchLeftWingMetric = "notchLeftWingMetric"
    static let notchSecondaryMetric = "notchSecondaryMetric"
    static let showNotchCurrentWork = "showNotchCurrentWork"
    static let showOnlyPinnedSessions = "showOnlyPinnedSessions"
    static let showNotchIntegrationAlerts = "showNotchIntegrationAlerts"
    static let showNotchCodexUsage = "showNotchCodexUsage"
    static let showNotchAPICostEstimate = "showNotchAPICostEstimate"
    static let showNotchResetForecast = "showNotchResetForecast"
    static let showNotchProviderBilling = "showNotchProviderBilling"
    static let menuBarPresentation = "menuBarPresentation"
    static let selectedProviderAccountID = "selectedProviderAccountID"
    static let onboardingComplete = "onboardingComplete"
    static let integrationIntentionallyRemoved = "integrationIntentionallyRemoved"
  }

  static let allKeys = [
    Key.showChatNames, Key.showPromptPreviews, Key.showResultPreviews, Key.completionVisibility,
    Key.approvalTimeout, Key.autoExpandApprovals, Key.capsLockEnabled, Key.capsLockFlashCount,
    Key.legacyShowOnNonNotch, Key.presentationPreference, Key.preferredDisplay,
    Key.reducedAnimation,
    Key.automaticUpdateChecks, Key.automaticUpdateDownloads, Key.showCodexUsage,
    Key.showAPICostEstimate, Key.apiCostWindow, Key.showResetForecast, Key.usageMetricPreference,
    Key.showFiveHourQuotaWindow, Key.showWeeklyQuotaWindow, Key.showSparkQuotaWindow,
    Key.notchLeftWingMetric, Key.notchSecondaryMetric,
    Key.showNotchCurrentWork, Key.showOnlyPinnedSessions, Key.showNotchIntegrationAlerts,
    Key.showNotchCodexUsage, Key.showNotchAPICostEstimate, Key.showNotchResetForecast,
    Key.showNotchProviderBilling,
    Key.menuBarPresentation,
    Key.selectedProviderAccountID, Key.onboardingComplete, Key.integrationIntentionallyRemoved,
  ]

  private let defaults: UserDefaults
  var showChatNames: Bool {
    didSet { defaults.set(showChatNames, forKey: Key.showChatNames) }
  }
  var showPromptPreviews: Bool {
    didSet { defaults.set(showPromptPreviews, forKey: Key.showPromptPreviews) }
  }
  var showResultPreviews: Bool {
    didSet { defaults.set(showResultPreviews, forKey: Key.showResultPreviews) }
  }
  var completionVisibility: CompletionVisibility {
    didSet { defaults.set(completionVisibility.rawValue, forKey: Key.completionVisibility) }
  }
  var approvalTimeout: TimeInterval {
    didSet { defaults.set(approvalTimeout, forKey: Key.approvalTimeout) }
  }
  var autoExpandApprovals: Bool {
    didSet { defaults.set(autoExpandApprovals, forKey: Key.autoExpandApprovals) }
  }
  var capsLockEnabled: Bool {
    didSet { defaults.set(capsLockEnabled, forKey: Key.capsLockEnabled) }
  }
  var capsLockFlashCount: Int {
    didSet { defaults.set(capsLockFlashCount, forKey: Key.capsLockFlashCount) }
  }
  var presentationPreference: PresentationPreference {
    didSet { defaults.set(presentationPreference.rawValue, forKey: Key.presentationPreference) }
  }
  var preferredDisplay: PreferredDisplay {
    didSet { defaults.set(preferredDisplay.rawValue, forKey: Key.preferredDisplay) }
  }
  var reducedAnimation: Bool {
    didSet { defaults.set(reducedAnimation, forKey: Key.reducedAnimation) }
  }
  var automaticUpdateChecks: Bool {
    didSet { defaults.set(automaticUpdateChecks, forKey: Key.automaticUpdateChecks) }
  }
  var automaticUpdateDownloads: Bool {
    didSet { defaults.set(automaticUpdateDownloads, forKey: Key.automaticUpdateDownloads) }
  }
  var showCodexUsage: Bool {
    didSet { defaults.set(showCodexUsage, forKey: Key.showCodexUsage) }
  }
  var showAPICostEstimate: Bool {
    didSet { defaults.set(showAPICostEstimate, forKey: Key.showAPICostEstimate) }
  }
  var apiCostWindow: APICostWindow {
    didSet { defaults.set(apiCostWindow.rawValue, forKey: Key.apiCostWindow) }
  }
  var showResetForecast: Bool {
    didSet { defaults.set(showResetForecast, forKey: Key.showResetForecast) }
  }
  var usageMetricPreference: UsageMetricPreference {
    didSet { defaults.set(usageMetricPreference.rawValue, forKey: Key.usageMetricPreference) }
  }
  var showFiveHourQuotaWindow: Bool {
    didSet { defaults.set(showFiveHourQuotaWindow, forKey: Key.showFiveHourQuotaWindow) }
  }
  var showWeeklyQuotaWindow: Bool {
    didSet { defaults.set(showWeeklyQuotaWindow, forKey: Key.showWeeklyQuotaWindow) }
  }
  var showSparkQuotaWindow: Bool {
    didSet { defaults.set(showSparkQuotaWindow, forKey: Key.showSparkQuotaWindow) }
  }
  var notchLeftWingMetric: NotchWingMetric {
    didSet { defaults.set(notchLeftWingMetric.rawValue, forKey: Key.notchLeftWingMetric) }
  }
  var notchSecondaryMetric: NotchWingMetric {
    didSet { defaults.set(notchSecondaryMetric.rawValue, forKey: Key.notchSecondaryMetric) }
  }
  var showNotchCurrentWork: Bool {
    didSet { defaults.set(showNotchCurrentWork, forKey: Key.showNotchCurrentWork) }
  }
  var showOnlyPinnedSessions: Bool {
    didSet { defaults.set(showOnlyPinnedSessions, forKey: Key.showOnlyPinnedSessions) }
  }
  var showNotchIntegrationAlerts: Bool {
    didSet { defaults.set(showNotchIntegrationAlerts, forKey: Key.showNotchIntegrationAlerts) }
  }
  var showNotchCodexUsage: Bool {
    didSet { defaults.set(showNotchCodexUsage, forKey: Key.showNotchCodexUsage) }
  }
  var showNotchAPICostEstimate: Bool {
    didSet { defaults.set(showNotchAPICostEstimate, forKey: Key.showNotchAPICostEstimate) }
  }
  var showNotchResetForecast: Bool {
    didSet { defaults.set(showNotchResetForecast, forKey: Key.showNotchResetForecast) }
  }
  var showNotchProviderBilling: Bool {
    didSet { defaults.set(showNotchProviderBilling, forKey: Key.showNotchProviderBilling) }
  }
  var menuBarPresentation: MenuBarPresentation {
    didSet { defaults.set(menuBarPresentation.rawValue, forKey: Key.menuBarPresentation) }
  }
  var selectedProviderAccountID: UUID? {
    didSet {
      if let selectedProviderAccountID {
        defaults.set(selectedProviderAccountID.uuidString, forKey: Key.selectedProviderAccountID)
      } else {
        defaults.removeObject(forKey: Key.selectedProviderAccountID)
      }
    }
  }
  var onboardingComplete: Bool {
    didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
  }
  var integrationIntentionallyRemoved: Bool {
    didSet {
      defaults.set(integrationIntentionallyRemoved, forKey: Key.integrationIntentionallyRemoved)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaults.register(defaults: [
      Key.showChatNames: true,
      Key.showPromptPreviews: false,
      Key.showResultPreviews: false,
      Key.completionVisibility: CompletionVisibility.fourSeconds.rawValue,
      Key.approvalTimeout: 60.0,
      Key.autoExpandApprovals: true,
      Key.capsLockEnabled: false,
      Key.capsLockFlashCount: 10,
      Key.preferredDisplay: PreferredDisplay.automatic.rawValue,
      Key.reducedAnimation: false,
      Key.automaticUpdateChecks: true,
      Key.automaticUpdateDownloads: false,
      Key.showCodexUsage: true,
      Key.showAPICostEstimate: false,
      Key.apiCostWindow: APICostWindow.last30Days.rawValue,
      Key.showResetForecast: false,
      Key.usageMetricPreference: UsageMetricPreference.remaining.rawValue,
      Key.showFiveHourQuotaWindow: true,
      Key.showWeeklyQuotaWindow: true,
      Key.showSparkQuotaWindow: true,
      Key.notchLeftWingMetric: NotchWingMetric.quotaPercentage.rawValue,
      Key.notchSecondaryMetric: NotchWingMetric.blank.rawValue,
      Key.showNotchCurrentWork: true,
      Key.showOnlyPinnedSessions: false,
      Key.showNotchIntegrationAlerts: true,
      Key.showNotchCodexUsage: true,
      Key.showNotchAPICostEstimate: true,
      Key.showNotchResetForecast: true,
      Key.showNotchProviderBilling: true,
      Key.menuBarPresentation: MenuBarPresentation.percentageOnly.rawValue,
      Key.onboardingComplete: false,
      Key.integrationIntentionallyRemoved: false,
    ])

    showChatNames = defaults.bool(forKey: Key.showChatNames)
    showPromptPreviews = defaults.bool(forKey: Key.showPromptPreviews)
    showResultPreviews = defaults.bool(forKey: Key.showResultPreviews)
    completionVisibility =
      CompletionVisibility(rawValue: defaults.string(forKey: Key.completionVisibility) ?? "")
      ?? .fourSeconds
    approvalTimeout = max(5, min(60, defaults.double(forKey: Key.approvalTimeout)))
    autoExpandApprovals = defaults.bool(forKey: Key.autoExpandApprovals)
    capsLockEnabled = defaults.bool(forKey: Key.capsLockEnabled)
    capsLockFlashCount = min(
      max(
        defaults.integer(forKey: Key.capsLockFlashCount),
        CapsLockPattern.completionFlashCountRange.lowerBound),
      CapsLockPattern.completionFlashCountRange.upperBound)
    let storedPresentation = defaults.string(forKey: Key.presentationPreference)
      .flatMap(PresentationPreference.init(rawValue:))
    let legacyShowOnNonNotch = defaults.object(forKey: Key.legacyShowOnNonNotch) as? Bool
    presentationPreference =
      storedPresentation ?? (legacyShowOnNonNotch == false ? .menuBar : .automatic)
    preferredDisplay =
      PreferredDisplay(rawValue: defaults.string(forKey: Key.preferredDisplay) ?? "") ?? .automatic
    reducedAnimation = defaults.bool(forKey: Key.reducedAnimation)
    automaticUpdateChecks = defaults.bool(forKey: Key.automaticUpdateChecks)
    automaticUpdateDownloads = defaults.bool(forKey: Key.automaticUpdateDownloads)
    showCodexUsage = defaults.bool(forKey: Key.showCodexUsage)
    showAPICostEstimate = defaults.bool(forKey: Key.showAPICostEstimate)
    apiCostWindow =
      APICostWindow(rawValue: defaults.string(forKey: Key.apiCostWindow) ?? "") ?? .last30Days
    showResetForecast = defaults.bool(forKey: Key.showResetForecast)
    usageMetricPreference =
      UsageMetricPreference(rawValue: defaults.string(forKey: Key.usageMetricPreference) ?? "")
      ?? .remaining
    showFiveHourQuotaWindow = defaults.bool(forKey: Key.showFiveHourQuotaWindow)
    showWeeklyQuotaWindow = defaults.bool(forKey: Key.showWeeklyQuotaWindow)
    showSparkQuotaWindow = defaults.bool(forKey: Key.showSparkQuotaWindow)
    notchLeftWingMetric =
      NotchWingMetric(rawValue: defaults.string(forKey: Key.notchLeftWingMetric) ?? "")
      ?? .quotaPercentage
    notchSecondaryMetric =
      NotchWingMetric(rawValue: defaults.string(forKey: Key.notchSecondaryMetric) ?? "")
      ?? .blank
    showNotchCurrentWork = defaults.bool(forKey: Key.showNotchCurrentWork)
    showOnlyPinnedSessions = defaults.bool(forKey: Key.showOnlyPinnedSessions)
    showNotchIntegrationAlerts = defaults.bool(forKey: Key.showNotchIntegrationAlerts)
    showNotchCodexUsage = defaults.bool(forKey: Key.showNotchCodexUsage)
    showNotchAPICostEstimate = defaults.bool(forKey: Key.showNotchAPICostEstimate)
    showNotchResetForecast = defaults.bool(forKey: Key.showNotchResetForecast)
    showNotchProviderBilling = defaults.bool(forKey: Key.showNotchProviderBilling)
    menuBarPresentation =
      MenuBarPresentation(rawValue: defaults.string(forKey: Key.menuBarPresentation) ?? "")
      ?? .percentageOnly
    selectedProviderAccountID = defaults.string(forKey: Key.selectedProviderAccountID).flatMap(
      UUID.init)
    onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
    integrationIntentionallyRemoved = defaults.bool(forKey: Key.integrationIntentionallyRemoved)
    defaults.set(presentationPreference.rawValue, forKey: Key.presentationPreference)
  }

  func reset() {
    for key in Self.allKeys {
      defaults.removeObject(forKey: key)
    }
    let replacement = SettingsStore(defaults: defaults)
    showChatNames = replacement.showChatNames
    showPromptPreviews = replacement.showPromptPreviews
    showResultPreviews = replacement.showResultPreviews
    completionVisibility = replacement.completionVisibility
    approvalTimeout = replacement.approvalTimeout
    autoExpandApprovals = replacement.autoExpandApprovals
    capsLockEnabled = replacement.capsLockEnabled
    capsLockFlashCount = replacement.capsLockFlashCount
    presentationPreference = replacement.presentationPreference
    preferredDisplay = replacement.preferredDisplay
    reducedAnimation = replacement.reducedAnimation
    automaticUpdateChecks = replacement.automaticUpdateChecks
    automaticUpdateDownloads = replacement.automaticUpdateDownloads
    showCodexUsage = replacement.showCodexUsage
    showAPICostEstimate = replacement.showAPICostEstimate
    apiCostWindow = replacement.apiCostWindow
    showResetForecast = replacement.showResetForecast
    usageMetricPreference = replacement.usageMetricPreference
    showFiveHourQuotaWindow = replacement.showFiveHourQuotaWindow
    showWeeklyQuotaWindow = replacement.showWeeklyQuotaWindow
    showSparkQuotaWindow = replacement.showSparkQuotaWindow
    notchLeftWingMetric = replacement.notchLeftWingMetric
    notchSecondaryMetric = replacement.notchSecondaryMetric
    showNotchCurrentWork = replacement.showNotchCurrentWork
    showOnlyPinnedSessions = replacement.showOnlyPinnedSessions
    showNotchIntegrationAlerts = replacement.showNotchIntegrationAlerts
    showNotchCodexUsage = replacement.showNotchCodexUsage
    showNotchAPICostEstimate = replacement.showNotchAPICostEstimate
    showNotchResetForecast = replacement.showNotchResetForecast
    showNotchProviderBilling = replacement.showNotchProviderBilling
    menuBarPresentation = replacement.menuBarPresentation
    selectedProviderAccountID = replacement.selectedProviderAccountID
    onboardingComplete = replacement.onboardingComplete
    integrationIntentionallyRemoved = replacement.integrationIntentionallyRemoved
  }
}
