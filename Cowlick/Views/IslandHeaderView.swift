import SwiftUI

struct IslandHeaderView: View {
  let usageText: String?
  let secondaryUsageValue: CompactUsageSecondaryValue?
  let showsCompletionIndicator: Bool
  let notchGapWidth: CGFloat?
  let isAttached: Bool
  let reducedAnimation: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    Group {
      if let notchGapWidth {
        HStack(spacing: 0) {
          statusGroup
            .frame(maxWidth: .infinity, alignment: .center)
            .clipped()
          Color.clear.frame(width: notchGapWidth)
          secondaryGroup
            .frame(maxWidth: .infinity, alignment: .center)
            .clipped()
        }
        // Keep the two compact usage wings physically attached to the hardware notch while the
        // activity drawer opens below them. Wider approval surfaces may grow around this header,
        // but the metrics themselves never slide sideways during the transition.
        .frame(width: notchGapWidth + NotchTheme.attachedWingWidth * 2)
        .offset(y: -1)
      } else {
        HStack(spacing: 9) {
          statusGroup
          secondaryGroup
        }
        .padding(.horizontal, 13)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var statusGroup: some View {
    Group {
      if let usageText {
        Text(usageText)
          .font(.system(size: 11, weight: .semibold))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .foregroundStyle(primaryTextColor)
      }
    }
  }

  private var secondaryGroup: some View {
    ZStack {
      if showsCompletionIndicator {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(NotchTheme.success)
          .transition(statusTransition)
      } else if let secondaryUsageValue {
        Text(secondaryUsageValue.text)
          .font(.system(size: 11, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(color(for: secondaryUsageValue.tone))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .allowsTightening(true)
          .transition(statusTransition)
      }
    }
    .animation(statusAnimation, value: showsCompletionIndicator)
  }

  private var motionReduced: Bool { reduceMotion || reducedAnimation }

  private var statusAnimation: Animation {
    motionReduced ? NotchTheme.reducedMotion : NotchTheme.statusChange
  }

  private var statusTransition: AnyTransition {
    motionReduced ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
  }

  private var primaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 1 : 0.94) : .primary
  }

  private var secondaryTextColor: Color {
    isAttached ? .white.opacity(increasedContrast ? 0.84 : 0.60) : .secondary
  }

  private func color(for tone: CompactUsageTone) -> Color {
    switch tone {
    case .neutral: secondaryTextColor
    case .positive: NotchTheme.success
    case .caution: NotchTheme.warning
    case .critical: NotchTheme.failure
    }
  }

  private var increasedContrast: Bool { colorSchemeContrast == .increased }
}
