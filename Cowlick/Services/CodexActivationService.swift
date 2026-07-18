import AppKit
import Foundation

@MainActor
enum CodexActivationService {
  static let codexBundleIdentifier = "com.openai.codex"

  static func openCodex(fallbackDirectory: String?) {
    if let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: codexBundleIdentifier
    ).first {
      running.activate(options: [.activateAllWindows])
      return
    }
    if let appURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: codexBundleIdentifier)
    {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
      return
    }
    guard let fallbackDirectory else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: fallbackDirectory, isDirectory: true))
  }
}
