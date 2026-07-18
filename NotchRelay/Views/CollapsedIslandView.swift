import SwiftUI

struct CollapsedIslandView: View {
  let session: AgentSession
  let activeCount: Int
  let notchGapWidth: CGFloat?
  let reducedAnimation: Bool
  let action: () -> Void
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
    .animation(motionReduced ? nil : .easeOut(duration: 0.14), value: isHovering)
    .accessibilityLabel("\(session.projectName), \(session.status.shortLabel)")
    .accessibilityHint("Expand the status island")
  }

  private var motionReduced: Bool {
    reduceMotion || reducedAnimation
  }

  private var floatingContent: some View {
    HStack(spacing: 9) {
      statusSymbol.frame(width: 16, height: 16)
      projectLabel
    }
    .padding(.horizontal, 13)
  }

  private func attachedContent(notchGapWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      statusSymbol
        .frame(width: 16, height: 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
      Color.clear.frame(width: notchGapWidth)
      projectLabel
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }
    .padding(.horizontal, 10)
  }

  private var projectLabel: some View {
    HStack(spacing: 6) {
      Text(session.projectName)
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.94))
        .lineLimit(1)
      if activeCount > 1 {
        Text("\(activeCount)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(NotchTheme.island)
          .frame(minWidth: 18, minHeight: 18)
          .background(NotchTheme.accent, in: Circle())
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
        .tint(NotchTheme.accent)
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
}

private struct IslandPressButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}
