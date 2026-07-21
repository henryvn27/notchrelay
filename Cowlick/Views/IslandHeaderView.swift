import SwiftUI

struct IslandHeaderView: View {
  let session: AgentSession
  let activeCount: Int
  let activeSubagentCount: Int
  let notchGapWidth: CGFloat?
  let isAttached: Bool
  let reducedAnimation: Bool
  let namespace: Namespace.ID

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    Group {
      if let notchGapWidth {
        HStack(spacing: 0) {
          statusGroup
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
          Color.clear.frame(width: notchGapWidth)
          projectLabel
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 10)
      } else {
        HStack(spacing: 9) {
          statusGroup
          projectLabel
        }
        .padding(.horizontal, 13)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      CollapsedIslandView.accessibilityLabel(
        session: session,
        activeCount: activeCount,
        activeSubagentCount: activeSubagentCount
      ))
  }

  private var statusGroup: some View {
    HStack(spacing: 5) {
      ZStack {
        statusSymbol
          .id(statusIdentity)
          .transition(statusTransition)
      }
      .frame(width: 16, height: 16)
      .matchedGeometryEffect(id: "island-status", in: namespace)
      .animation(statusAnimation, value: statusIdentity)

      if activeSubagentCount > 0 {
        HStack(spacing: 2) {
          Image(systemName: "person.2.fill")
          Text("\(activeSubagentCount)").monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(secondaryTextColor)
      }
    }
  }

  private var projectLabel: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 0) {
        Text(session.displayName)
          .font(.system(size: session.projectContext == nil ? 13 : 12.5, weight: .medium))
          .foregroundStyle(primaryTextColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .matchedGeometryEffect(id: "island-session-name", in: namespace)
        if let project = session.projectContext {
          Text(project)
            .font(.system(size: 9.5, weight: .regular))
            .foregroundStyle(secondaryTextColor)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      if activeCount > 1 {
        Text("×\(activeCount)")
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(secondaryTextColor)
      }
    }
  }

  @ViewBuilder
  private var statusSymbol: some View {
    switch session.presentationStatus {
    case .working:
      ProgressView()
        .controlSize(.small)
        .tint(isAttached ? .white.opacity(increasedContrast ? 1 : 0.72) : .secondary)
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

  private var motionReduced: Bool { reduceMotion || reducedAnimation }

  private var statusAnimation: Animation {
    motionReduced
      ? .easeOut(duration: NotchTheme.reducedMotionFadeDuration)
      : NotchTheme.contentSpring
  }

  private var statusTransition: AnyTransition {
    motionReduced ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
  }

  private var statusIdentity: StatusIdentity {
    switch session.presentationStatus {
    case .idle: .idle
    case .working: .working
    case .awaitingApproval: .approval
    case .completed: .completed
    case .failed: .failed
    }
  }

  private var primaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 1 : 0.94) : .primary
  }

  private var secondaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 0.84 : 0.60) : .secondary
  }

  private var increasedContrast: Bool { colorSchemeContrast == .increased }
}

private enum StatusIdentity: Hashable {
  case idle
  case working
  case approval
  case completed
  case failed
}
