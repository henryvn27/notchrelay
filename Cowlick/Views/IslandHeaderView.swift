import SwiftUI

struct IslandHeaderView: View {
  let leftUsageValue: CompactUsageSecondaryValue?
  let rightUsageValue: CompactUsageSecondaryValue?
  let leftMetric: NotchWingMetric
  let rightMetric: NotchWingMetric
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
          metricGroup(leftUsageValue, metric: leftMetric)
            .frame(maxWidth: .infinity, alignment: .center)
            .clipped()
          Color.clear.frame(width: notchGapWidth)
          rightGroup
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
          metricGroup(leftUsageValue, metric: leftMetric)
          rightGroup
        }
        .padding(.horizontal, 13)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var rightGroup: some View {
    ZStack {
      if showsCompletionIndicator {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(NotchTheme.success)
          .transition(statusTransition)
      } else {
        metricGroup(rightUsageValue, metric: rightMetric)
          .transition(statusTransition)
      }
    }
    .animation(statusAnimation, value: showsCompletionIndicator)
  }

  @ViewBuilder
  private func metricGroup(_ value: CompactUsageSecondaryValue?, metric: NotchWingMetric)
    -> some View
  {
    if let value {
      HStack(spacing: 2) {
        if metric == .resetCountdown {
          Image(systemName: "clock")
            .font(.system(size: 8, weight: .semibold))
            .accessibilityHidden(true)
        }
        Text(value.text)
          .font(.system(size: 11, weight: .semibold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .allowsTightening(true)
      }
      .foregroundStyle(color(for: value.tone))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(value.accessibilityLabel)
    }
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

  private func color(for tone: CompactUsageTone) -> Color {
    switch tone {
    case .neutral: primaryTextColor
    case .positive: NotchTheme.success
    case .caution: NotchTheme.warning
    case .critical: NotchTheme.failure
    }
  }

  private var increasedContrast: Bool { colorSchemeContrast == .increased }
}
