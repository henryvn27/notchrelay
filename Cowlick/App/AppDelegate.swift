import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let automaticTerminationReason = "Listening for local Codex hook events"
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
    guard !isUITesting else { return }

    let timeoutDefaults = UserDefaults.standard
    let server = LocalSocketServer(
      approvalTimeout: {
        let value = timeoutDefaults.double(forKey: SettingsStore.Key.approvalTimeout)
        return max(5, min(60, value == 0 ? 60 : value))
      },
      eventHandler: { event in
        let decision = await services.sessionStore.receive(event)
        if event.event == .completed || event.event == .failed {
          await services.usageStore.refreshAfterActivity()
        }
        return decision
      }
    )
    do {
      try server.start()
      socketServer = server
    } catch {
      services.eventLogger.error("Socket startup failed: \(error.localizedDescription)")
    }
    installSleepObservers(services)
    services.usageStore.refreshIfNeeded()
    Task {
      let recovered = await Task.detached(priority: .utility) {
        LifecycleLedger.load()
      }.value
      await services.sessionStore.restoreLifecycleSessions(recovered)
    }

    if !services.settings.onboardingComplete && !CommandLine.arguments.contains("--ui-testing") {
      WindowCoordinator.shared.openOnboarding()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminating else { return .terminateLater }
    terminating = true
    Task {
      await AppServices.shared.capsLockService.cancelAndRestore()
      AppServices.shared.approvalCoordinator.deferAll()
      socketServer?.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    socketServer?.stop()
    let processInfo = ProcessInfo.processInfo
    processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
    processInfo.enableSuddenTermination()
  }

  private func configureUITestingIfNeeded(_ services: AppServices) {
    guard CommandLine.arguments.contains("--ui-testing") else { return }
    let stateName = CommandLine.arguments.first(where: { $0.hasPrefix("--state=") })
      .map { String($0.dropFirst("--state=".count)) }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      if stateName == "multiple" {
        services.sessionStore.testState(.working)
        try? await Task.sleep(for: .milliseconds(500))
        services.sessionStore.testMultipleSessions()
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
        Task { @MainActor in await services.capsLockService.cancelAndRestore() }
      })
    sleepObservers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        Task { @MainActor in
          if services.settings.capsLockEnabled, services.sessionStore.currentApproval != nil {
            await services.capsLockService.start(.approval)
          }
        }
      })
  }
}
