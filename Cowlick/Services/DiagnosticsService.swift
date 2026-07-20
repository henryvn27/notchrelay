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
    let bridgeIsListening = FileManager.default.fileExists(atPath: AppSupportPaths.socketURL.path)
    let summary = Self.formatFields([
      ("Version", "\(ProductVersion.marketing) (\(ProductVersion.build))"),
      ("Protocol", String(ProductVersion.bridgeProtocol)),
      ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
      ("Architecture", ProcessInfo.processInfo.machineArchitecture),
      ("Launch at login", LaunchAtLoginService.statusDescription),
      ("Hook status", hook.summary),
      ("Codex hook trust", hookTrust.state.summary),
      (
        "Codex lifecycle integration",
        CodexIntegrationPresentation.diagnosticStatus(
          hookStatus: hook,
          trustState: hookTrust.state,
          bridgeIsListening: bridgeIsListening
        )
      ),
      ("Helper installed", String(hook.helperInstalled)),
      (
        "Local bridge socket",
        Self.bridgeSocketStatus(isListening: bridgeIsListening)
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

  static func bridgeSocketStatus(isListening: Bool) -> String {
    isListening ? "listening (transport only; does not prove Codex hook execution)" : "offline"
  }
}

@MainActor
enum CodexIntegrationPresentation {
  static let reviewInstruction =
    "In the Codex CLI, enter /hooks and review the four Cowlick hooks."

  static let futureEventsNote =
    "Tasks already running cannot be backfilled. Send a new prompt or start a new task after review."

  static func guidance(for state: CodexHookTrustState) -> String {
    switch state {
    case .trusted:
      "Cowlick is trusted. Tasks that started before trust cannot be backfilled. Send a new prompt or start a new task to see live activity."
    case .needsReview:
      "Codex is skipping Cowlick until you review it. \(reviewInstruction) \(futureEventsNote)"
    case .incomplete:
      "Cowlick's hooks are missing or disabled. Install or Repair them, then \(reviewInstruction.lowercased())"
    case .notChecked:
      "Cowlick has not verified Codex hook trust. Check again before expecting live sessions."
    case .unavailable(let message):
      "Cowlick could not verify Codex hook trust: \(EventLogger.sanitizeError(message)) Retry the check or open Diagnostics."
    }
  }

  static func diagnosticStatus(
    hookStatus: HookInstallationStatus,
    trustState: CodexHookTrustState,
    bridgeIsListening: Bool
  ) -> String {
    guard hookStatus.isHealthy else {
      return "NOT READY; \(hookStatus.summary)"
    }
    guard bridgeIsListening else {
      return "NOT READY; local bridge socket is offline"
    }
    return switch trustState {
    case .trusted:
      "READY for new prompts and new tasks; existing tasks are not backfilled"
    case .needsReview:
      "BLOCKED until Cowlick is reviewed in Codex /hooks; existing tasks are not backfilled"
    case .incomplete:
      "NOT READY; Cowlick hooks are missing or disabled"
    case .notChecked:
      "UNVERIFIED; hook trust has not been checked"
    case .unavailable:
      "UNVERIFIED; Cowlick could not inspect Codex hook trust"
    }
  }

  static func copyReviewCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("/hooks", forType: .string)
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
