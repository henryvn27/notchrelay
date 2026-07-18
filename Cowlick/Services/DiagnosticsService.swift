import AppKit
import Foundation

@MainActor
struct DiagnosticsService {
  let store: SessionStore
  let usageStore: UsageStore
  let hookInstaller: HookInstaller

  func report() async -> String {
    let caps = await store.capsLockService.supportStatus()
    let hook = hookInstaller.status()
    let hookTrust = await CodexHookTrustService().inspect()
    let displays = NSScreen.screens.enumerated().map { index, screen in
      let notch =
        NotchGeometryResolver.resolve(
          screen: screen, contentSize: NotchTheme.compactSize, showOnNonNotch: true)?.hasNotch
        == true
      return
        "Display \(index + 1): \(Int(screen.frame.width))×\(Int(screen.frame.height)), notch=\(notch), builtIn=\(CGDisplayIsBuiltin(screen.displayID) != 0)"
    }.joined(separator: "\n")
    let events = store.eventLogger.recentEvents.map {
      "\($0.timestamp.formatted(.iso8601)) \($0.event) \($0.project) \($0.outcome)"
    }.joined(separator: "\n")
    let errors = store.eventLogger.recentErrors.joined(separator: "\n")
    let architecture = ProcessInfo.processInfo.machineArchitecture

    return """
      Cowlick Diagnostics
      Version: \(ProductVersion.marketing) (\(ProductVersion.build))
      Protocol: \(ProductVersion.bridgeProtocol)
      macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      Architecture: \(architecture)
      Launch at login: \(LaunchAtLoginService.statusDescription)
      Hook status: \(hook.summary)
      Codex hook trust: \(hookTrust.state.summary)
      Helper installed: \(hook.helperInstalled)
      Socket status: \(FileManager.default.fileExists(atPath: AppSupportPaths.socketURL.path) ? "listening" : "offline")
      Codex quota: \(usageStore.officialStatus)
      Third-party reset forecast: \(usageStore.forecastStatus)
      Caps Lock: \(caps.summary)

      Displays:
      \(displays.isEmpty ? "No displays reported" : displays)

      Recent sanitized events:
      \(events.isEmpty ? "None" : events)

      Recent sanitized errors:
      \(errors.isEmpty ? "None" : errors)
      """
  }
}

extension ProcessInfo {
  fileprivate var machineArchitecture: String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }
}
