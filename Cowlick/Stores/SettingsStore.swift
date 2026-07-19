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
    static let showPromptPreviews = "showPromptPreviews"
    static let showResultPreviews = "showResultPreviews"
    static let completionVisibility = "completionVisibility"
    static let approvalTimeout = "approvalTimeout"
    static let autoExpandApprovals = "autoExpandApprovals"
    static let capsLockEnabled = "capsLockEnabled"
    static let showOnNonNotch = "showOnNonNotch"
    static let preferredDisplay = "preferredDisplay"
    static let reducedAnimation = "reducedAnimation"
    static let automaticUpdateChecks = "automaticUpdateChecks"
    static let automaticUpdateDownloads = "automaticUpdateDownloads"
    static let showCodexUsage = "showCodexUsage"
    static let showResetForecast = "showResetForecast"
    static let usageMetricPreference = "usageMetricPreference"
    static let menuBarPresentation = "menuBarPresentation"
    static let selectedProviderAccountID = "selectedProviderAccountID"
    static let onboardingComplete = "onboardingComplete"
    static let integrationIntentionallyRemoved = "integrationIntentionallyRemoved"
  }

  static let allKeys = [
    Key.showPromptPreviews, Key.showResultPreviews, Key.completionVisibility,
    Key.approvalTimeout, Key.autoExpandApprovals, Key.capsLockEnabled,
    Key.showOnNonNotch, Key.preferredDisplay, Key.reducedAnimation,
    Key.automaticUpdateChecks, Key.automaticUpdateDownloads, Key.showCodexUsage,
    Key.showResetForecast, Key.usageMetricPreference, Key.menuBarPresentation,
    Key.selectedProviderAccountID, Key.onboardingComplete, Key.integrationIntentionallyRemoved,
  ]

  private let defaults: UserDefaults

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
  var showOnNonNotch: Bool { didSet { defaults.set(showOnNonNotch, forKey: Key.showOnNonNotch) } }
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
  var showResetForecast: Bool {
    didSet { defaults.set(showResetForecast, forKey: Key.showResetForecast) }
  }
  var usageMetricPreference: UsageMetricPreference {
    didSet { defaults.set(usageMetricPreference.rawValue, forKey: Key.usageMetricPreference) }
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
      Key.showPromptPreviews: false,
      Key.showResultPreviews: false,
      Key.completionVisibility: CompletionVisibility.fourSeconds.rawValue,
      Key.approvalTimeout: 60.0,
      Key.autoExpandApprovals: true,
      Key.capsLockEnabled: false,
      Key.showOnNonNotch: true,
      Key.preferredDisplay: PreferredDisplay.automatic.rawValue,
      Key.reducedAnimation: false,
      Key.automaticUpdateChecks: true,
      Key.automaticUpdateDownloads: false,
      Key.showCodexUsage: true,
      Key.showResetForecast: false,
      Key.usageMetricPreference: UsageMetricPreference.remaining.rawValue,
      Key.menuBarPresentation: MenuBarPresentation.iconAndDetails.rawValue,
      Key.onboardingComplete: false,
      Key.integrationIntentionallyRemoved: false,
    ])

    showPromptPreviews = defaults.bool(forKey: Key.showPromptPreviews)
    showResultPreviews = defaults.bool(forKey: Key.showResultPreviews)
    completionVisibility =
      CompletionVisibility(rawValue: defaults.string(forKey: Key.completionVisibility) ?? "")
      ?? .fourSeconds
    approvalTimeout = max(5, min(60, defaults.double(forKey: Key.approvalTimeout)))
    autoExpandApprovals = defaults.bool(forKey: Key.autoExpandApprovals)
    capsLockEnabled = defaults.bool(forKey: Key.capsLockEnabled)
    showOnNonNotch = defaults.bool(forKey: Key.showOnNonNotch)
    preferredDisplay =
      PreferredDisplay(rawValue: defaults.string(forKey: Key.preferredDisplay) ?? "") ?? .automatic
    reducedAnimation = defaults.bool(forKey: Key.reducedAnimation)
    automaticUpdateChecks = defaults.bool(forKey: Key.automaticUpdateChecks)
    automaticUpdateDownloads = defaults.bool(forKey: Key.automaticUpdateDownloads)
    showCodexUsage = defaults.bool(forKey: Key.showCodexUsage)
    showResetForecast = defaults.bool(forKey: Key.showResetForecast)
    usageMetricPreference =
      UsageMetricPreference(rawValue: defaults.string(forKey: Key.usageMetricPreference) ?? "")
      ?? .remaining
    menuBarPresentation =
      MenuBarPresentation(rawValue: defaults.string(forKey: Key.menuBarPresentation) ?? "")
      ?? .iconAndDetails
    selectedProviderAccountID = defaults.string(forKey: Key.selectedProviderAccountID).flatMap(
      UUID.init)
    onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
    integrationIntentionallyRemoved = defaults.bool(forKey: Key.integrationIntentionallyRemoved)
  }

  func reset() {
    for key in Self.allKeys {
      defaults.removeObject(forKey: key)
    }
    let replacement = SettingsStore(defaults: defaults)
    showPromptPreviews = replacement.showPromptPreviews
    showResultPreviews = replacement.showResultPreviews
    completionVisibility = replacement.completionVisibility
    approvalTimeout = replacement.approvalTimeout
    autoExpandApprovals = replacement.autoExpandApprovals
    capsLockEnabled = replacement.capsLockEnabled
    showOnNonNotch = replacement.showOnNonNotch
    preferredDisplay = replacement.preferredDisplay
    reducedAnimation = replacement.reducedAnimation
    automaticUpdateChecks = replacement.automaticUpdateChecks
    automaticUpdateDownloads = replacement.automaticUpdateDownloads
    showCodexUsage = replacement.showCodexUsage
    showResetForecast = replacement.showResetForecast
    usageMetricPreference = replacement.usageMetricPreference
    menuBarPresentation = replacement.menuBarPresentation
    selectedProviderAccountID = replacement.selectedProviderAccountID
    onboardingComplete = replacement.onboardingComplete
    integrationIntentionallyRemoved = replacement.integrationIntentionallyRemoved
  }
}
