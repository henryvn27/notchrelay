import SwiftUI

struct SessionListView: View {
  let sessions: [AgentSession]
  let showPromptPreviews: Bool
  let showResultPreviews: Bool
  let isAttached: Bool
  var scrollsInternally = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !isAttached {
        Text("Sessions")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(secondaryTextColor)
          .padding(.bottom, 2)
      }
      sessionViewport
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 5)
  }

  @ViewBuilder
  private var sessionViewport: some View {
    if scrollsInternally && sessions.count > NotchTheme.maximumVisibleSessionCount {
      ScrollView(.vertical, showsIndicators: false) {
        sessionRows
      }
      .frame(height: NotchTheme.maximumSessionViewportHeight)
      .accessibilityIdentifier("session-scroll-view")
    } else {
      sessionRows
    }
  }

  private var sessionRows: some View {
    LazyVStack(alignment: .leading, spacing: NotchTheme.sessionRowSpacing) {
      ForEach(sessions) { session in
        sessionRow(for: session)
      }
    }
  }

  private func sessionRow(for session: AgentSession) -> some View {
    HStack(spacing: 10) {
      statusIcon(for: session)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.displayName)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(primaryTextColor)
          .lineLimit(1)
          .truncationMode(.tail)
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
    .frame(height: NotchTheme.sessionRowHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Self.accessibilityLabel(
        for: session,
        showPromptPreviews: showPromptPreviews,
        showResultPreviews: showResultPreviews)
    )
    .accessibilityIdentifier("session-row-\(session.id)")
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
    let detail: String
    if showPromptPreviews, case .working(let prompt) = session.presentationStatus, let prompt,
      !prompt.isEmpty
    {
      detail = String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(80))
    } else {
      detail =
        switch session.presentationStatus {
        case .failed(let message): message.map { String($0.prefix(80)) } ?? "Failed"
        case .completed(let message):
          if showResultPreviews {
            message.map { String($0.prefix(80)) } ?? "Completed"
          } else {
            "Completed"
          }
        default: session.statusLabel
        }
    }
    return [session.projectContext, detail].compactMap { $0 }.joined(separator: " · ")
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
    let semanticDetail: String
    if let project = session.projectContext,
      secondary.hasPrefix(project + " · ")
    {
      semanticDetail = String(secondary.dropFirst(project.count + 3))
    } else {
      semanticDetail = secondary
    }
    var parts = [session.displayName]
    if let project = session.projectContext { parts.append(project) }
    parts.append(status)
    if semanticDetail != status, semanticDetail != session.projectContext {
      parts.append(semanticDetail)
    }
    return parts.joined(separator: ", ")
  }

}
