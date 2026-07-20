import SwiftUI

struct UsageSectionView: View {
  let store: UsageStore
  let showOfficialUsage: Bool
  let showForecast: Bool
  let metricPreference: UsageMetricPreference
  let refresh: () -> Void
  @State private var presentationDate = Date()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if showOfficialUsage {
        officialUsage
      }
      if showForecast {
        thirdPartyForecast
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background {
      MenuPresentationObserver { presentationDate = Date() }
        .frame(width: 0, height: 0)
    }
  }

  private var officialUsage: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text("Codex quota")
            .font(.caption.weight(.semibold))
          Text("From the local Codex app")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        officialRefreshButton
      }

      if let snapshot = store.snapshot {
        Text(officialFreshness(snapshot))
          .font(.caption2)
          .foregroundStyle(store.officialError == nil ? Color.secondary : Color.orange)
        if store.officialError != nil {
          Label("Refresh failed", systemImage: "arrow.clockwise.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ForEach(snapshot.limits) { limit in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(limit.name)
                .lineLimit(1)
              Spacer()
              Text(percentLabel(for: limit))
                .monospacedDigit()
            }
            .font(.caption)
            let pace = QuotaPaceCalculator.pace(
              for: QuotaWindow(
                usedPercent: limit.usedPercent,
                duration: limit.windowDurationMinutes.map { TimeInterval($0 * 60) },
                resetsAt: limit.resetsAt
              ),
              observedAt: snapshot.fetchedAt
            )
            QuotaProgressBar(
              displayedPercent: limit.displayedPercent(for: metricPreference),
              metricPreference: metricPreference,
              pace: pace
            )
            if let pace {
              Text(paceLabel(pace, relativeTo: presentationDate))
                .font(.caption2)
                .foregroundStyle(paceColor(pace.status))
                .monospacedDigit()
            }
            if let resetsAt = limit.resetsAt {
              Text(
                "Resets \(RelativeTimeLabel.string(for: resetsAt, relativeTo: presentationDate))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      } else if let error = store.officialError {
        unavailableRow(error)
      } else {
        loadingRow("Reading local quota…")
      }
    }
  }

  private var thirdPartyForecast: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text("Unofficial reset forecast")
            .font(.caption.weight(.semibold))
          Link(ResetForecast.sourceName, destination: ResetForecast.sourceURL)
            .font(.caption2)
        }
        Spacer()
        if let forecast = store.forecast {
          if forecast.resetAnnounced {
            Label("Reset announced", systemImage: "checkmark.circle.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.green)
          } else {
            Text(forecast.scoreLabel)
              .font(.caption.weight(.medium))
              .monospacedDigit()
          }
        }
        forecastRefreshButton
      }

      if store.forecast == nil {
        if let error = store.forecastError {
          unavailableRow(error)
        } else {
          loadingRow("Loading third-party data…")
        }
      }

      if let fetchedAt = store.forecast?.fetchedAt {
        HStack(spacing: 4) {
          Text(
            "Source updated \(RelativeTimeLabel.string(for: fetchedAt, relativeTo: presentationDate))"
          )
          if let checkedAt = store.lastForecastRefresh {
            Text(
              "· checked \(RelativeTimeLabel.string(for: checkedAt, relativeTo: presentationDate))"
            )
          }
        }
        .font(.caption2)
        .foregroundStyle(store.forecastError == nil ? Color.secondary : Color.orange)
      }

      if let error = store.forecastError, store.forecast != nil {
        Label("Stale data · \(error)", systemImage: "arrow.clockwise.circle")
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if store.forecastError == ResetForecastServiceError.unavailable.errorDescription {
        Text(ResetForecast.outageNote)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(ResetForecast.disclaimer)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
  }

  private var officialRefreshButton: some View {
    Button(action: refresh) {
      if store.isOfficialRefreshing {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .buttonStyle(.plain)
    .disabled(store.isOfficialRefreshing)
    .help("Refresh quota")
    .accessibilityLabel("Refresh quota")
  }

  private var forecastRefreshButton: some View {
    Button {
      store.refreshForecast(force: true)
    } label: {
      if store.isForecastRefreshing {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .buttonStyle(.plain)
    .disabled(store.isForecastRefreshing)
    .help("Refresh unofficial reset forecast")
    .accessibilityLabel("Refresh unofficial reset forecast")
  }

  private func loadingRow(_ text: String) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      Text(text)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func unavailableRow(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(2)
  }

  private func percentLabel(for limit: CodexUsageLimit) -> String {
    let percent = Int(limit.displayedPercent(for: metricPreference).rounded())
    return "\(percent)% \(metricPreference.accessibilityLabel)"
  }

  private func officialFreshness(_ snapshot: CodexUsageSnapshot) -> String {
    let prefix = store.officialError == nil ? "Updated" : "Stale · updated"
    return
      "\(prefix) \(RelativeTimeLabel.string(for: snapshot.fetchedAt, relativeTo: presentationDate))"
  }

  private func paceLabel(_ pace: QuotaPace, relativeTo referenceDate: Date) -> String {
    let paceSummary = paceSummary(pace)
    guard let forecast = pace.exhaustionForecast else { return paceSummary }
    let forecastSummary: String
    if forecast.willLastThroughReset {
      forecastSummary = "Should last through reset"
    } else {
      let timeToEmpty = forecast.estimatedAt.timeIntervalSince(referenceDate)
      forecastSummary =
        timeToEmpty < 60
        ? "Runs out in under 1m"
        : "Runs out in \(compactDuration(timeToEmpty))"
    }
    return "\(forecastSummary) · \(paceSummary)"
  }

  private func paceSummary(_ pace: QuotaPace) -> String {
    let balance = Int(abs(pace.balancePercent).rounded())
    switch pace.status {
    case .reserve:
      return "\(balance) pp reserve"
    case .onPace:
      return "On pace"
    case .deficit:
      return "\(balance) pp deficit"
    }
  }

  private func compactDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(1, Int(max(0, interval) / 60))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(minutes)m"
  }

  private func paceColor(_ status: QuotaPaceStatus) -> Color {
    switch status {
    case .reserve: .secondary
    case .onPace: .secondary
    case .deficit: .orange
    }
  }
}

private struct QuotaProgressBar: View {
  let displayedPercent: Double
  let metricPreference: UsageMetricPreference
  let pace: QuotaPace?

  var body: some View {
    ZStack {
      ProgressView(value: displayedPercent, total: 100)
        .progressViewStyle(.linear)
        .tint(.accentColor)
      if let pace {
        GeometryReader { geometry in
          Capsule()
            .fill(.primary.opacity(0.78))
            .frame(width: 2, height: 8)
            .position(
              x: markerPosition(
                width: geometry.size.width,
                percent: pace.expectedDisplayedPercent(for: metricPreference)
              ),
              y: geometry.size.height / 2
            )
        }
        .accessibilityHidden(true)
      }
    }
    .frame(height: 8)
    .accessibilityLabel("Quota usage")
    .accessibilityValue(accessibilityValue)
    .help(helpText)
  }

  private var accessibilityValue: String {
    let displayed = Int(displayedPercent.rounded())
    guard let pace else { return "\(displayed)% \(metricPreference.accessibilityLabel)" }
    let balance = Int(abs(pace.balancePercent).rounded())
    let paceSummary =
      switch pace.status {
      case .reserve: "\(balance) percentage points in reserve"
      case .onPace: "on pace"
      case .deficit: "\(balance) percentage points in deficit"
      }
    let forecastSummary =
      switch pace.exhaustionForecast?.willLastThroughReset {
      case .some(true): ", should last through reset"
      case .some(false): ", projected to run out before reset"
      case .none: ""
      }
    return "\(displayed)% \(metricPreference.accessibilityLabel), \(paceSummary)\(forecastSummary)"
  }

  private var helpText: String {
    pace == nil ? "Quota usage" : "The marker shows an even pace through the reset window"
  }

  private func fraction(_ percent: Double) -> CGFloat {
    CGFloat(min(max(percent, 0), 100) / 100)
  }

  private func markerPosition(width: CGFloat, percent: Double) -> CGFloat {
    guard width > 2 else { return width / 2 }
    return min(max(width * fraction(percent), 1), width - 1)
  }
}
