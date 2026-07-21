import SwiftUI

struct CollapsedIslandView: View {
  let session: AgentSession
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
    Button(action: action) {
      IslandHeaderView(
        session: session,
        activeCount: activeCount,
        activeSubagentCount: activeSubagentCount,
        notchGapWidth: notchGapWidth,
        isAttached: isAttached,
        reducedAnimation: reducedAnimation,
        namespace: namespace
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .opacity(isHovering ? 1 : 0.94)
    }
    .buttonStyle(IslandPressButtonStyle(reduceMotion: motionReduced))
    .onHover { isHovering = $0 }
    .animation(
      motionReduced ? nil : .easeOut(duration: NotchTheme.hoverFeedbackDuration),
      value: isHovering
    )
    .accessibilityLabel(
      Self.accessibilityLabel(
        session: session,
        activeCount: activeCount,
        activeSubagentCount: activeSubagentCount
      )
    )
    .accessibilityHint(Self.accessibilityHint(for: session.presentationStatus))
  }

  static func accessibilityHint(for status: AgentStatus) -> String {
    if case .completed = status { return "Dismiss the completed status" }
    return "Expand the status island"
  }

  static func accessibilityLabel(
    session: AgentSession,
    activeCount: Int,
    activeSubagentCount: Int
  ) -> String {
    var parts = [session.displayName]
    if let project = session.projectContext { parts.append(project) }
    parts.append(session.statusLabel)
    if activeCount > 1 { parts.append("\(activeCount) active sessions") }
    if activeSubagentCount > 0 {
      parts.append(
        "\(activeSubagentCount) active \(activeSubagentCount == 1 ? "agent" : "agents")")
    }
    return parts.joined(separator: ", ")
  }

  private var motionReduced: Bool {
    reduceMotion || reducedAnimation
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
