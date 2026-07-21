import SwiftUI

struct SessionListView: View {
  let sessions: [AgentSession]
  let showPromptPreviews: Bool
  let showResultPreviews: Bool
  let isAttached: Bool
  let openDiagnostics: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !isAttached {
        Text("Sessions")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(secondaryTextColor)
          .padding(.bottom, 2)
      }
      ForEach(sessions.prefix(visibleSessionLimit)) { session in
        HStack(spacing: 10) {
          statusIcon(for: session)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(session.projectName)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(primaryTextColor)
            Text(
              Self.secondaryText(
                for: session,
                showPromptPreviews: showPromptPreviews,
                showResultPreviews: showResultPreviews)
            )
            .font(.system(size: 10.5))
            .foregroundStyle(secondaryTextColor)
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
      if sessions.count > visibleSessionLimit {
        Text("\(sessions.count - visibleSessionLimit) more in the menu bar")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(secondaryTextColor)
          .padding(.leading, 26)
          .accessibilityLabel(
            "\(sessions.count - visibleSessionLimit) more sessions in the menu bar")
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
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var visibleSessionLimit: Int {
    sessions.count > 3 ? 2 : min(3, sessions.count)
  }

  private var primaryTextColor: Color {
    isAttached ? .white.opacity(0.94) : .primary
  }

  private var secondaryTextColor: Color {
    isAttached ? .white.opacity(0.60) : .secondary
  }

  @ViewBuilder
  private func statusIcon(for session: AgentSession) -> some View {
    if session.isRecovered {
      Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
    } else {
      switch session.presentationStatus {
      case .working:
        ProgressView().controlSize(.mini).tint(isAttached ? .white.opacity(0.72) : .secondary)
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
