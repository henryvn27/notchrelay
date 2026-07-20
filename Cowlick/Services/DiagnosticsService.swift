import AppKit
import Foundation

@MainActor
struct DiagnosticsService {
  enum ReportMode: Equatable {
    case live
    case launchAssetDemo
  }

  let store: SessionStore
  let usageStore: UsageStore
  let hookInstaller: HookInstaller
  let mode: ReportMode

  init(
    store: SessionStore,
    usageStore: UsageStore,
    hookInstaller: HookInstaller,
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.store = store
    self.usageStore = usageStore
    self.hookInstaller = hookInstaller
    mode = Self.reportMode(arguments: arguments, environment: environment)
  }

  func report() async -> String {
    guard mode == .live else { return Self.launchAssetDemoReport }

    let caps = await store.capsLockService.supportStatus()
    let hook = hookInstaller.status()
    let hookTrust = await CodexHookTrustService().inspect()
    let summary = Self.formatFields([
      ("Version", "\(ProductVersion.marketing) (\(ProductVersion.build))"),
      ("Protocol", String(ProductVersion.bridgeProtocol)),
      ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
      ("Architecture", ProcessInfo.processInfo.machineArchitecture),
      ("Launch at login", LaunchAtLoginService.statusDescription),
      ("Hook status", hook.summary),
      ("Codex hook trust", hookTrust.state.summary),
      ("Helper installed", String(hook.helperInstalled)),
      (
        "Socket status",
        FileManager.default.fileExists(atPath: AppSupportPaths.socketURL.path)
          ? "listening" : "offline"
      ),
      ("Codex quota", usageStore.officialStatus),
      ("Third-party reset forecast", usageStore.forecastStatus),
      ("Caps Lock", caps.summary),
    ])
    let displays = Self.formatLines(
      NSScreen.screens.enumerated().map { index, screen in
        let notch =
          NotchGeometryResolver.resolve(
            screen: screen, contentSize: NotchTheme.compactSize, showOnNonNotch: true)?.hasNotch
          == true
        return
          "Display \(index + 1): \(Int(screen.frame.width))×\(Int(screen.frame.height)), notch=\(notch), builtIn=\(CGDisplayIsBuiltin(screen.displayID) != 0)"
      },
      empty: "No displays reported"
    )
    let eventLines = store.eventLogger.recentEvents.map(Self.formatEvent)
    let events = eventLines.isEmpty ? "None" : eventLines.joined(separator: "\n")
    let errors = Self.formatLines(store.eventLogger.recentErrors, empty: "None")

    return """
      Cowlick Diagnostics
      \(summary)

      Displays:
      \(displays)

      Recent sanitized events:
      \(events)

      Recent sanitized errors:
      \(errors)
      """
  }

  static func reportMode(arguments: [String], environment: [String: String]) -> ReportMode {
    guard arguments.contains("--ui-testing"), environment["COWLICK_ASSET_CAPTURE"] == "1"
    else { return .live }
    return .launchAssetDemo
  }

  static var launchAssetDemoReport: String {
    """
    Cowlick Diagnostics
    Report context: Launch-asset demo snapshot — not live device data
    Version: \(ProductVersion.marketing) (\(ProductVersion.build))
    Protocol: \(ProductVersion.bridgeProtocol)
    Supported macOS: 14 or newer
    Architectures: Apple silicon and Intel
    Launch at login: Available
    Hook status: Installed (demo)
    Codex hook trust: Trusted (demo)
    Helper installed: true
    Socket status: listening
    Codex quota: Ready for live account data
    Third-party reset forecast: Website data is attributed in Quota
    Caps Lock: Optional; not evaluated in this demo snapshot

    Displays:
    Display layout: Generic non-notch demo capture

    Recent sanitized events:
    Cowlick integration health accepted (demo)

    Recent sanitized errors:
    None
    """
  }

  static func formatFields(_ fields: [(label: String, value: String)]) -> String {
    fields.map { "\($0.label): \(EventLogger.sanitizeError($0.value))" }.joined(separator: "\n")
  }

  static func formatLines(_ values: [String], empty: String) -> String {
    (values.isEmpty ? [empty] : values).map { EventLogger.sanitizeError($0) }.joined(
      separator: "\n")
  }

  static func formatEvent(_ record: SanitizedBridgeRecord) -> String {
    [
      record.timestamp.formatted(.iso8601), record.event, record.project, record.outcome,
    ].map { EventLogger.sanitizeError($0) }.joined(separator: " ")
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
