import AppKit
import SwiftUI

struct DiagnosticsView: View {
  let services: AppServices
  @State private var report = "Loading diagnostics…"
  @State private var selfTestStatus = ""
  @State private var selfTestInProgress = false

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
        Button(selfTestInProgress ? "Testing…" : "Run Self-Test") {
          Task { await runSelfTest() }
        }
        .disabled(selfTestInProgress || services.sessionStore.integrationSelfTestInProgress)
      }
    }
    .padding(20)
    .task { await refresh() }
  }

  private func refresh() async {
    report = await DiagnosticsService(
      store: services.sessionStore,
      usageStore: services.usageStore,
      hookInstaller: services.hookInstaller,
      localLifecycleObserver: services.localLifecycleObserver
    ).report()
  }

  private func runSelfTest() async {
    guard
      let lease = services.sessionStore.beginIntegrationSelfTest(owner: .diagnostics)
    else {
      selfTestStatus =
        services.sessionStore.integrationSelfTestInProgress
        ? "Another integration self-test is already running."
        : "Live activity must finish before running the integration self-test."
      return
    }
    selfTestInProgress = true
    defer {
      selfTestInProgress = false
      services.sessionStore.finishIntegrationSelfTest(lease)
    }
    do {
      let helperURL = try services.hookInstaller.currentInstalledHelperURL()
      let selfTest = IntegrationSelfTestService(helperURL: helperURL)
      try await selfTest.ping()
      guard services.sessionStore.isIntegrationSelfTestActive(lease) else {
        selfTestStatus = "Integration self-test was cancelled."
        return
      }
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
