import SwiftUI

struct UsageSectionView: View {
  let store: UsageStore
  let showOfficialUsage: Bool
  let showForecast: Bool
  let metricPreference: UsageMetricPreference
  let refresh: () -> Void

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
        refreshButton
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
            let pace = limit.pace()
            QuotaProgressBar(
              displayedPercent: limit.displayedPercent(for: metricPreference),
              metricPreference: metricPreference,
              pace: pace
            )
            if let pace {
              Text(paceLabel(pace, preference: metricPreference))
                .font(.caption2)
                .foregroundStyle(paceColor(pace.status))
                .monospacedDigit()
            }
            if let resetsAt = limit.resetsAt {
              Text("Resets \(resetsAt, style: .relative)")
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
          Text(forecast.scoreLabel)
            .font(.caption.weight(.medium))
            .monospacedDigit()
        }
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
          Text("Source updated \(fetchedAt, style: .relative)")
          if let checkedAt = store.lastForecastRefresh {
            Text("· checked \(checkedAt, style: .relative)")
          }
        }
        .font(.caption2)
        .foregroundStyle(store.forecastError == nil ? Color.secondary : Color.orange)
        if store.forecastError != nil {
          Label("Refresh failed", systemImage: "arrow.clockwise.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Text(ResetForecast.disclaimer)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
  }

  private var refreshButton: some View {
    Button(action: refresh) {
      if store.isRefreshing {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .buttonStyle(.plain)
    .disabled(store.isRefreshing)
    .help("Refresh quota")
    .accessibilityLabel("Refresh quota")
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
    return "\(prefix) \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))"
  }

  private func paceLabel(_ pace: QuotaPace, preference: UsageMetricPreference) -> String {
    let expected = Int(pace.expectedDisplayedPercent(for: preference).rounded())
    let metric = preference.accessibilityLabel
    let balance = Int(abs(pace.balancePercent).rounded())
    switch pace.status {
    case .reserve:
      return "\(balance)% in reserve · expected \(expected)% \(metric)"
    case .onPace:
      return "On pace · expected \(expected)% \(metric)"
    case .deficit:
      return "\(balance)% deficit · expected \(expected)% \(metric)"
    }
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
    let expected = Int(pace.expectedDisplayedPercent(for: metricPreference).rounded())
    return
      "\(displayed)% \(metricPreference.accessibilityLabel), expected \(expected)% \(metricPreference.accessibilityLabel) by now"
  }

  private var helpText: String {
    guard let pace else { return "Quota usage" }
    let expected = Int(pace.expectedDisplayedPercent(for: metricPreference).rounded())
    return "Expected \(expected)% \(metricPreference.accessibilityLabel) by now"
  }

  private func fraction(_ percent: Double) -> CGFloat {
    CGFloat(min(max(percent, 0), 100) / 100)
  }

  private func markerPosition(width: CGFloat, percent: Double) -> CGFloat {
    guard width > 2 else { return width / 2 }
    return min(max(width * fraction(percent), 1), width - 1)
  }
}
