import AppKit
import SwiftUI

struct SelfTestRunState {
  private(set) var isRunning = false

  mutating func begin() -> Bool {
    guard !isRunning else { return false }
    isRunning = true
    return true
  }

  mutating func finish() {
    isRunning = false
  }
}

struct DiagnosticsView: View {
  let services: AppServices
  @State private var report = "Loading diagnostics…"
  @State private var selfTestStatus = ""
  @State private var selfTestRunState = SelfTestRunState()

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Diagnostics")
            .font(.title2.weight(.semibold))
          Text("Sanitized local health information")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Refresh") { Task { await refresh() } }
      }

      TextEditor(text: .constant(report))
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

      if !selfTestStatus.isEmpty {
        Text(selfTestStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button("Copy Diagnostics") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
        }
        Button("Export…") { exportReport() }
        Button("Reveal Logs") { NSWorkspace.shared.open(AppSupportPaths.logDirectory) }
        Spacer()
        Button(selfTestRunState.isRunning ? "Testing…" : "Run Self-Test") {
          Task { await runSelfTest() }
        }
        .disabled(selfTestRunState.isRunning)
      }
    }
    .padding(20)
    .task { await refresh() }
  }

  private func refresh() async {
    report = await DiagnosticsService(
      store: services.sessionStore,
      usageStore: services.usageStore,
      hookInstaller: services.hookInstaller
    ).report()
  }

  private func runSelfTest() async {
    guard selfTestRunState.begin() else { return }
    defer { selfTestRunState.finish() }
    let selfTest = IntegrationSelfTestService(
      helperURL: services.hookInstaller.installedHelperURL)
    do {
      try await selfTest.ping()
      selfTestStatus = "Self-test passed: the installed helper authenticated to Cowlick."
    } catch {
      selfTestStatus = "Self-test failed: \(error.localizedDescription)"
    }
    await refresh()
  }

  private func exportReport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Cowlick-Diagnostics.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try report.write(to: url, atomically: true, encoding: .utf8) } catch {
      services.eventLogger.error("Diagnostics export failed: \(error.localizedDescription)")
    }
  }
}
