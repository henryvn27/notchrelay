import SwiftUI

struct CollapsedIslandView: View {
  let session: AgentSession?
  let usageStore: UsageStore
  let activeCount: Int
  let activeSubagentCount: Int
  let notchGapWidth: CGFloat?
  let isAttached: Bool
  let reducedAnimation: Bool
  let namespace: Namespace.ID
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Group {
      if let session {
        Button(action: action) {
          header(session: session, showsHoverFeedback: true)
        }
        .buttonStyle(IslandPressButtonStyle(reduceMotion: motionReduced))
        .accessibilityHint(Self.accessibilityHint(for: session.presentationStatus))
        .onHover { isHovering = $0 }
        .animation(
          motionReduced ? nil : .easeOut(duration: NotchTheme.hoverFeedbackDuration),
          value: isHovering
        )
      } else {
        Button(action: action) {
          header(session: nil, showsHoverFeedback: false)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open Cowlick controls")
      }
    }
    .accessibilityLabel(
      Self.accessibilityLabel(
        session: session,
        activeCount: activeCount,
        activeSubagentCount: activeSubagentCount,
        usageLabel: usageAccessibilityLabel
      )
    )
  }

  private func header(session: AgentSession?, showsHoverFeedback: Bool) -> some View {
    IslandHeaderView(
      session: session,
      usageText: usageText,
      usageAccessibilityLabel: usageAccessibilityLabel,
      activeCount: activeCount,
      activeSubagentCount: activeSubagentCount,
      notchGapWidth: notchGapWidth,
      isAttached: isAttached,
      reducedAnimation: reducedAnimation,
      namespace: namespace
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .opacity(showsHoverFeedback && !isHovering ? 0.94 : 1)
  }

  static func accessibilityHint(for status: AgentStatus) -> String {
    if case .completed = status { return "Dismiss the completed status" }
    return "Expand the status island"
  }

  static func accessibilityLabel(
    session: AgentSession?,
    activeCount: Int,
    activeSubagentCount: Int,
    usageLabel: String? = nil
  ) -> String {
    var parts: [String] = []
    if let session {
      parts.append(session.displayName)
      if let project = session.projectContext { parts.append(project) }
      parts.append(session.statusLabel)
      if activeCount > 1 { parts.append("\(activeCount) active sessions") }
      if activeSubagentCount > 0 {
        parts.append(
          "\(activeSubagentCount) active \(activeSubagentCount == 1 ? "agent" : "agents")")
      }
    }
    if let usageLabel { parts.append(usageLabel) }
    return parts.joined(separator: ", ")
  }

  static func usageText(showCodexUsage: Bool, percent: Double?) -> String? {
    guard showCodexUsage, let percent else { return nil }
    return "\(Int(percent.rounded()))%"
  }

  private var motionReduced: Bool {
    reduceMotion || reducedAnimation
  }

  private var usageText: String? {
    Self.usageText(
      showCodexUsage: usageStore.settings.showCodexUsage,
      percent: usageStore.primaryDisplayedPercent
    )
  }

  private var usageAccessibilityLabel: String? {
    guard usageText != nil else { return nil }
    return usageStore.primaryMetricAccessibilityLabel
  }

}

private struct IslandPressButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1, anchor: .top)
      .opacity(configuration.isPressed ? 0.90 : 1)
      .animation(
        reduceMotion ? NotchTheme.reducedMotion : NotchTheme.pressFeedback,
        value: configuration.isPressed
      )
  }
}
