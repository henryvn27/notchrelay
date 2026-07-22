import SwiftUI

struct ExpandedIslandView: View {
  let store: SessionStore
  let isAttached: Bool

  var body: some View {
    if let approval = store.currentApproval {
      ApprovalView(
        request: approval,
        isAttached: isAttached,
        allow: { _ = store.decide(requestID: approval.id, decision: .allow) },
        deny: { _ = store.decide(requestID: approval.id, decision: .deny) },
        openCodex: {
          CodexActivationService.openCodex(fallbackDirectory: approval.workingDirectory)
        }
      )
    } else {
      VStack(spacing: 0) {
        SessionListView(
          sessions: store.sessionSummaries,
          showPromptPreviews: store.settings.showPromptPreviews,
          showResultPreviews: store.settings.showResultPreviews,
          isAttached: isAttached,
          openDiagnostics: { WindowCoordinator.shared.openDiagnostics() })
        NotchActionBar(store: store, isAttached: isAttached)
      }
    }
  }
}

private struct NotchActionBar: View {
  let store: SessionStore
  let isAttached: Bool

  var body: some View {
    HStack(spacing: 14) {
      action("Open Codex", systemImage: "macwindow") {
        CodexActivationService.openCodex(fallbackDirectory: store.displaySession?.workingDirectory)
      }
      action("Settings", systemImage: "gearshape") {
        WindowCoordinator.shared.openSettingsForTesting()
      }
      action("Diagnostics", systemImage: "stethoscope") {
        WindowCoordinator.shared.openDiagnostics()
      }
      action("Quit", systemImage: "power") {
        NSApplication.shared.terminate(nil)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(isAttached ? NotchTheme.hairline : Color.secondary.opacity(0.18))
        .frame(height: 0.5)
    }
  }

  private func action(
    _ title: String,
    systemImage: String,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      Label(title, systemImage: systemImage)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(isAttached ? Color.white.opacity(0.72) : Color.secondary)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
