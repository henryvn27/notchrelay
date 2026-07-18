import AppKit
import SwiftUI

struct DiagnosticsView: View {
  let services: AppServices
  @State private var report = "Loading diagnostics…"

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

      HStack {
        Button("Copy Diagnostics") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
        }
        Button("Export…") { exportReport() }
        Button("Reveal Logs") { NSWorkspace.shared.open(AppSupportPaths.logDirectory) }
        Spacer()
        Button("Run Self-Test") {
          services.sessionStore.testState(.working)
          Task { await refresh() }
        }
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
