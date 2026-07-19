import SwiftUI

struct CollapsedIslandView: View {
  let session: AgentSession
  let activeCount: Int
  let notchGapWidth: CGFloat?
  let isAttached: Bool
  let reducedAnimation: Bool
  let action: () -> Void
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Group {
        if let notchGapWidth {
          attachedContent(notchGapWidth: notchGapWidth)
        } else {
          floatingContent
        }
      }
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
    .accessibilityLabel("\(session.projectName), \(session.status.shortLabel)")
    .accessibilityHint(Self.accessibilityHint(for: session.status))
  }

  static func accessibilityHint(for status: AgentStatus) -> String {
    if case .completed = status { return "Dismiss the completed status" }
    return "Expand the status island"
  }

  private var motionReduced: Bool {
    reduceMotion || reducedAnimation
  }

  private var floatingContent: some View {
    HStack(spacing: 9) {
      statusSymbolContainer
      projectLabel
    }
    .padding(.horizontal, 13)
  }

  private func attachedContent(notchGapWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      statusSymbolContainer
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
      Color.clear.frame(width: notchGapWidth)
      projectLabel
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }
    .padding(.horizontal, 10)
  }

  private var statusSymbolContainer: some View {
    ZStack {
      statusSymbol
        .id(statusIdentity)
        .transition(statusTransition)
    }
    .frame(width: 16, height: 16)
    .animation(statusAnimation, value: statusIdentity)
  }

  private var statusAnimation: Animation {
    motionReduced
      ? .easeOut(duration: NotchTheme.reducedMotionFadeDuration)
      : NotchTheme.contentSpring
  }

  private var statusTransition: AnyTransition {
    motionReduced ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
  }

  private var statusIdentity: StatusIdentity {
    switch session.status {
    case .idle: .idle
    case .working: .working
    case .awaitingApproval: .approval
    case .completed: .completed
    case .failed: .failed
    }
  }

  private var projectLabel: some View {
    HStack(spacing: 6) {
      Text(session.projectName)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(primaryTextColor)
        .lineLimit(1)
      if activeCount > 1 {
        Text("×\(activeCount)")
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(secondaryTextColor)
          .accessibilityLabel("\(activeCount) active sessions")
      }
    }
  }

  @ViewBuilder
  private var statusSymbol: some View {
    switch session.status {
    case .working:
      ProgressView()
        .controlSize(.small)
        .tint(isAttached ? .white.opacity(increasedContrast ? 1 : 0.72) : .secondary)
        .accessibilityHidden(true)
    case .awaitingApproval:
      Image(systemName: "exclamationmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(NotchTheme.warning)
    case .completed:
      Image(systemName: "checkmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(NotchTheme.success)
    case .failed:
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(NotchTheme.failure)
    case .idle:
      Circle().fill(.secondary).frame(width: 6, height: 6)
    }
  }

  private var primaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 1 : 0.94) : .primary
  }

  private var secondaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 0.82 : 0.58) : .secondary
  }

  private var increasedContrast: Bool {
    colorSchemeContrast == .increased
  }
}

private enum StatusIdentity: Hashable {
  case idle
  case working
  case approval
  case completed
  case failed
}

private struct IslandPressButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}
