import SwiftUI

struct CollapsedIslandView: View {
  let session: AgentSession?
  let completionStatus: AgentStatus?
  let usageStore: UsageStore
  let activeCount: Int
  let activeSubagentCount: Int
  let notchGapWidth: CGFloat?
  let isAttached: Bool
  let height: CGFloat
  let reducedAnimation: Bool
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false
  @State private var presentationDate = Date()

  var body: some View {
    Group {
      if let session {
        Button(action: action) {
          header(session: session, showsHoverFeedback: true)
        }
        .buttonStyle(IslandPressButtonStyle(reduceMotion: motionReduced))
        .accessibilityHint(Self.accessibilityHint(for: session.presentationStatus))
        .accessibilityIdentifier(
          showsCompletionIndicator
            ? "compact-completion-indicator" : "compact-notch-button"
        )
        .onHover { isHovering = $0 }
        .animation(
          motionReduced ? nil : .easeOut(duration: NotchTheme.hoverFeedbackDuration),
          value: isHovering
        )
      } else {
        Button(action: action) {
          header(session: nil, showsHoverFeedback: true)
        }
        .buttonStyle(IslandPressButtonStyle(reduceMotion: motionReduced))
        .accessibilityHint("Open Cowlick controls")
        .accessibilityIdentifier("compact-notch-button")
        .onHover { isHovering = $0 }
        .animation(
          motionReduced ? nil : .easeOut(duration: NotchTheme.hoverFeedbackDuration),
          value: isHovering
        )
      }
    }
    .accessibilityLabel(
      Self.accessibilityLabel(
        session: session,
        activeCount: activeCount,
        activeSubagentCount: activeSubagentCount,
        usageLabel: leftUsageValue?.accessibilityLabel,
        secondaryUsageLabel: showsCompletionIndicator
          ? nil : rightUsageValue?.accessibilityLabel
      )
    )
    .background {
      MenuPresentationObserver {
        let now = Date()
        presentationDate = now
        usageStore.refreshForMenuPresentation(now: now)
      }
      .frame(width: 0, height: 0)
    }
  }

  private func header(session: AgentSession?, showsHoverFeedback: Bool) -> some View {
    IslandHeaderView(
      leftUsageValue: leftUsageValue,
      rightUsageValue: rightUsageValue,
      leftMetric: usageStore.settings.notchLeftWingMetric,
      rightMetric: usageStore.settings.notchSecondaryMetric,
      showsCompletionIndicator: showsCompletionIndicator,
      notchGapWidth: notchGapWidth,
      isAttached: isAttached,
      reducedAnimation: reducedAnimation,
    )
    .frame(height: height)
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .opacity(showsHoverFeedback && !isHovering ? 0.94 : 1)
  }

  nonisolated static func accessibilityHint(for status: AgentStatus) -> String {
    if case .completed = status {
      return "Show recent activity and dismiss the completed indicator"
    }
    return "Show recent activity"
  }

  nonisolated static func showsCompletionIndicator(for status: AgentStatus?) -> Bool {
    guard let status, case .completed = status else { return false }
    return true
  }

  nonisolated static func accessibilityLabel(
    session: AgentSession?,
    activeCount: Int,
    activeSubagentCount: Int,
    usageLabel: String? = nil,
    secondaryUsageLabel: String? = nil
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
    if let secondaryUsageLabel { parts.append(secondaryUsageLabel) }
    return parts.joined(separator: ", ")
  }

  nonisolated static func usageText(showCodexUsage: Bool, percent: Double?) -> String? {
    guard showCodexUsage, let percent else { return nil }
    return "\(Int(percent.rounded()))%"
  }

  private var motionReduced: Bool {
    reduceMotion || reducedAnimation
  }

  private var leftUsageValue: CompactUsageSecondaryValue? {
    wingValue(for: usageStore.settings.notchLeftWingMetric)
  }

  private var rightUsageValue: CompactUsageSecondaryValue? {
    wingValue(for: usageStore.settings.notchSecondaryMetric)
  }

  private func wingValue(for metric: NotchWingMetric) -> CompactUsageSecondaryValue? {
    guard usageStore.settings.showCodexUsage else { return nil }
    return CompactUsageSecondaryFormatter.value(
      for: metric,
      snapshot: visibleQuotaSnapshot,
      preference: usageStore.settings.usageMetricPreference,
      forecast: usageStore.settings.showResetForecast ? usageStore.forecast : nil,
      now: presentationDate
    )
  }

  private var visibleQuotaSnapshot: CodexUsageSnapshot? {
    guard let snapshot = usageStore.snapshot else { return nil }
    return CodexUsageSnapshot(
      limits: UsageSectionView.visibleQuotaLimits(
        snapshot.limits,
        showFiveHour: usageStore.settings.showFiveHourQuotaWindow,
        showWeekly: usageStore.settings.showWeeklyQuotaWindow,
        showSpark: usageStore.settings.showSparkQuotaWindow
      ),
      planType: snapshot.planType,
      fetchedAt: snapshot.fetchedAt
    )
  }

  private var showsCompletionIndicator: Bool {
    Self.showsCompletionIndicator(for: completionStatus)
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
