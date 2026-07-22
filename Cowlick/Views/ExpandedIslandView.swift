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
          isAttached: isAttached
        )
        .layoutPriority(1)
        NotchActionBar(store: store, isAttached: isAttached)
          .frame(height: NotchTheme.actionBarHeight)
      }
    }
  }
}

private struct NotchActionBar: View {
  let store: SessionStore
  let isAttached: Bool

  var body: some View {
    HStack(spacing: 2) {
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 8)
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
      HStack(spacing: 3) {
        Image(systemName: systemImage)
        Text(title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(isAttached ? Color.white.opacity(0.72) : Color.secondary)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
