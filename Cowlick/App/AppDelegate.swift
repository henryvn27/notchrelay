import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let automaticTerminationReason = "Listening for local Codex activity"
  private var socketServer: LocalSocketServer?
  private var terminating = false
  private var sleepObservers: [NSObjectProtocol] = []

  func applicationWillFinishLaunching(_ notification: Notification) {
    let processInfo = ProcessInfo.processInfo
    processInfo.automaticTerminationSupportEnabled = true
    processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
    processInfo.disableSuddenTermination()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let isUITesting = CommandLine.arguments.contains("--ui-testing")
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
      !isUITesting
    {
      return
    }
    let services = AppServices.shared
    WindowCoordinator.shared.configure(services: services)
    configureUITestingIfNeeded(services)
    services.presentationCoordinator.start()
    guard !isUITesting else { return }
    do {
      try services.hookInstaller.refreshInstalledHelperIfNeeded()
      try services.hookInstaller.repairExistingIntegrationIfNeeded(
        intentionallyRemoved: services.settings.integrationIntentionallyRemoved)
    } catch {
      services.eventLogger.error("Integration refresh failed: \(error.localizedDescription)")
    }

    let timeoutDefaults = UserDefaults.standard
    let server = LocalSocketServer(
      approvalTimeout: {
        let value = timeoutDefaults.double(forKey: SettingsStore.Key.approvalTimeout)
        return max(5, min(60, value == 0 ? 60 : value))
      },
      eventHandler: { event in
        if Self.shouldRefreshUsage(after: event.event) {
          await services.usageStore.refreshAfterActivity()
        }
        return await services.sessionStore.receive(event)
      }
    )
    do {
      try server.start()
      socketServer = server
    } catch {
      services.eventLogger.error("Socket startup failed: \(error.localizedDescription)")
    }
    installSleepObservers(services)
    services.localLifecycleObserver.start()
    services.usageStore.refreshIfNeeded()
    Task {
      let recovered = await Task.detached(priority: .utility) {
        LifecycleLedger.load()
      }.value
      await services.sessionStore.restoreLifecycleSessions(recovered)
    }

    let integrationHealthy = services.hookInstaller.status().isHealthy
    if services.settings.integrationIntentionallyRemoved, integrationHealthy {
      services.settings.integrationIntentionallyRemoved = false
    }
    if Self.shouldOpenOnboarding(
      onboardingComplete: services.settings.onboardingComplete,
      integrationIntentionallyRemoved: services.settings.integrationIntentionallyRemoved,
      integrationHealthy: integrationHealthy)
    {
      WindowCoordinator.shared.openOnboarding()
    }
  }

  static func shouldOpenOnboarding(
    onboardingComplete: Bool,
    integrationIntentionallyRemoved: Bool,
    integrationHealthy: Bool
  ) -> Bool {
    !onboardingComplete || (!integrationIntentionallyRemoved && !integrationHealthy)
  }

  nonisolated static func shouldRefreshUsage(after event: BridgeEventName) -> Bool {
    event != .ping
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    terminating = true
    Task {
      await AppServices.shared.capsLockService.cancelAndRestore()
      AppServices.shared.approvalCoordinator.deferAll()
      socketServer?.stop()
      AppServices.shared.localLifecycleObserver.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    socketServer?.stop()
    AppServices.shared.localLifecycleObserver.stop()
    let processInfo = ProcessInfo.processInfo
    processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
    processInfo.enableSuddenTermination()
  }

  private func configureUITestingIfNeeded(_ services: AppServices) {
    guard CommandLine.arguments.contains("--ui-testing") else { return }
    services.settings.presentationPreference =
      CommandLine.arguments.contains("--menu-bar") ? .menuBar : .automatic
    services.settings.showChatNames = !CommandLine.arguments.contains("--hide-chat-names")
    services.settings.showPromptPreviews =
      CommandLine.arguments.contains("--show-prompt-previews")
    services.settings.showResultPreviews = CommandLine.arguments.contains("--show-result-previews")
    services.settings.showNotchCurrentWork =
      !CommandLine.arguments.contains("--hide-notch-current-work")
    services.settings.showNotchIntegrationAlerts =
      !CommandLine.arguments.contains("--hide-notch-integration-alerts")
    services.settings.showNotchCodexUsage =
      !CommandLine.arguments.contains("--hide-notch-codex-usage")
    services.settings.showNotchAPICostEstimate =
      !CommandLine.arguments.contains("--hide-notch-api-cost")
    services.settings.showNotchResetForecast =
      !CommandLine.arguments.contains("--hide-notch-reset-forecast")
    services.settings.showNotchProviderBilling =
      !CommandLine.arguments.contains("--hide-notch-provider-billing")
    if ProcessInfo.processInfo.environment["COWLICK_ASSET_CAPTURE"] == "1" {
      services.settings.reducedAnimation = true
    }
    if CommandLine.arguments.contains("--usage-demo") {
      services.settings.showCodexUsage = true
      services.settings.showAPICostEstimate = true
      services.settings.showResetForecast = true
      services.settings.usageMetricPreference = .remaining
      services.usageStore.refreshIfNeeded(force: true)
    }
    let stateName = CommandLine.arguments.first(where: { $0.hasPrefix("--state=") })
      .map { String($0.dropFirst("--state=".count)) }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      if CommandLine.arguments.contains("--billing-demo") {
        _ = try? await services.providerAccountsController.addAccount(
          provider: .openAIAPI,
          alias: "Platform",
          credential: Data("ui-testing-admin-key".utf8)
        )
      }
      if stateName == "multiple" {
        services.sessionStore.testState(.working)
        try? await Task.sleep(for: .milliseconds(500))
        services.sessionStore.testMultipleSessions()
      } else if stateName == "overflow" {
        services.sessionStore.testOverflowSessions()
      } else if let stateName, let state = BridgeEventName(rawValue: stateName) {
        if state == .approvalRequested {
          services.sessionStore.testState(.working)
          try? await Task.sleep(for: .milliseconds(500))
        }
        services.sessionStore.testState(state)
      }
      if CommandLine.arguments.contains("--expanded"), !services.sessionStore.isExpanded {
        services.sessionStore.toggleExpanded()
      }
      if CommandLine.arguments.contains("--demo-sequence") {
        try? await Task.sleep(for: .seconds(4))
        services.sessionStore.expand()
        try? await Task.sleep(for: .seconds(3))
        services.sessionStore.collapse()
        try? await Task.sleep(for: .seconds(1.5))
        services.sessionStore.expand()
      }
      if CommandLine.arguments.contains("--open-settings") {
        WindowCoordinator.shared.openSettingsForTesting()
      }
      if CommandLine.arguments.contains("--open-diagnostics") {
        WindowCoordinator.shared.openDiagnostics()
      }
      if CommandLine.arguments.contains("--open-usage-demo") {
        services.usageStore.refreshIfNeeded(force: true)
        WindowCoordinator.shared.openUsageForTesting()
      }
      if CommandLine.arguments.contains("--open-onboarding") {
        WindowCoordinator.shared.openOnboarding()
      }
    }
  }

  private func installSleepObservers(_ services: AppServices) {
    let center = NSWorkspace.shared.notificationCenter
    sleepObservers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        _ in
        Task { @MainActor in
          await services.capsLockService.cancelAndRestore()
        }
      })
    sleepObservers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        _ in
        Task { @MainActor in
          services.localLifecycleObserver.stop()
          services.localLifecycleObserver.start()
          services.usageStore.refreshForMenuPresentation()
          services.sessionStore.refreshCapsLockAttention(force: true)
        }
      })
  }
}
