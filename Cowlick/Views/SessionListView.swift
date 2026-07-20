import SwiftUI

struct SessionListView: View {
  let sessions: [AgentSession]
  let showPromptPreviews: Bool
  let showResultPreviews: Bool
  let openDiagnostics: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Sessions")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.62))
      ForEach(sessions.prefix(5)) { session in
        HStack(spacing: 10) {
          statusIcon(for: session)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(session.projectName)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(.white.opacity(0.92))
            Text(
              Self.secondaryText(
                for: session,
                showPromptPreviews: showPromptPreviews,
                showResultPreviews: showResultPreviews)
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
          }
          Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          Self.accessibilityLabel(
            for: session,
            showPromptPreviews: showPromptPreviews,
            showResultPreviews: showResultPreviews)
        )
        .accessibilityIdentifier("session-row-\(session.id)")
      }
      if sessions.contains(where: { session in
        if case .failed = session.presentationStatus { return true }
        return false
      }) {
        Button("Open Diagnostics", action: openDiagnostics)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityHint("Open sanitized Cowlick errors and bridge health")
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private func statusIcon(for session: AgentSession) -> some View {
    if session.isRecovered {
      Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
    } else {
      switch session.presentationStatus {
      case .working: ProgressView().controlSize(.mini).tint(.white.opacity(0.68))
      case .awaitingApproval:
        Image(systemName: "exclamationmark").foregroundStyle(NotchTheme.warning)
      case .completed: Image(systemName: "checkmark").foregroundStyle(NotchTheme.success)
      case .failed: Image(systemName: "xmark").foregroundStyle(NotchTheme.failure)
      case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
      }
    }
  }

  static func secondaryText(
    for session: AgentSession,
    showPromptPreviews: Bool,
    showResultPreviews: Bool
  ) -> String {
    if showPromptPreviews, case .working(let prompt) = session.presentationStatus, let prompt,
      !prompt.isEmpty
    {
      return String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(80))
    }
    switch session.presentationStatus {
    case .failed(let message): return message.map { String($0.prefix(80)) } ?? "Failed"
    case .completed(let message):
      guard showResultPreviews else { return "Completed" }
      return message.map { String($0.prefix(80)) } ?? "Completed"
    default: return session.statusLabel
    }
  }

  static func accessibilityLabel(
    for session: AgentSession,
    showPromptPreviews: Bool,
    showResultPreviews: Bool
  ) -> String {
    let status = session.statusLabel
    let secondary = secondaryText(
      for: session,
      showPromptPreviews: showPromptPreviews,
      showResultPreviews: showResultPreviews)
    let parts =
      secondary == status
      ? [session.projectName, status]
      : [session.projectName, status, secondary]
    return parts.joined(separator: ", ")
  }
}
