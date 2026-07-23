import SwiftUI

enum UsageSectionDensity {
  case detailed
  case compact
}

struct UsageSectionView: View {
  enum QuotaWindowKind: Equatable {
    case fiveHour
    case weekly
    case spark
    case other
  }

  let store: UsageStore
  let showOfficialUsage: Bool
  let showAPICostEstimate: Bool
  let showForecast: Bool
  let metricPreference: UsageMetricPreference
  let density: UsageSectionDensity
  @State private var presentationDate = Date()

  var body: some View {
    VStack(alignment: .leading, spacing: density == .compact ? 6 : 12) {
      if showOfficialUsage {
        if density == .compact { compactOfficialUsage } else { officialUsage }
      }
      if showAPICostEstimate {
        if density == .compact { compactAPICost } else { apiEquivalentCost }
      }
      if showForecast {
        if density == .compact { compactForecast } else { thirdPartyForecast }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, density == .compact ? 6 : 12)
    .background {
      MenuPresentationObserver { presentationDate = Date() }
        .frame(width: 0, height: 0)
    }
  }

  private var compactOfficialUsage: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Codex quota")
          .font(.caption.weight(.semibold))
        if let snapshot = store.snapshot {
          Text("· \(officialFreshness(snapshot))")
            .font(.caption2)
            .foregroundStyle(store.officialError == nil ? Color.secondary : Color.orange)
            .lineLimit(1)
        } else {
          Text("· Local Codex")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      if let snapshot = store.snapshot {
        ForEach(visibleQuotaLimits(snapshot.limits)) { limit in
          compactQuotaWindow(limit, observedAt: snapshot.fetchedAt)
        }
      } else if let error = store.officialError {
        unavailableRow(error)
      } else {
        loadingRow("Reading local quota…")
      }
    }
  }

  private func compactQuotaWindow(_ limit: CodexUsageLimit, observedAt: Date) -> some View {
    let pace = QuotaPaceCalculator.pace(
      for: QuotaWindow(
        usedPercent: limit.usedPercent,
        duration: limit.windowDurationMinutes.map { TimeInterval($0 * 60) },
        resetsAt: limit.resetsAt
      ),
      observedAt: observedAt
    )
    return VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(limit.name)
          .font(.caption)
          .lineLimit(1)
        Spacer()
        Text(percentLabel(for: limit))
          .font(.caption.weight(.semibold).monospacedDigit())
      }
      QuotaProgressBar(
        displayedPercent: limit.displayedPercent(for: metricPreference),
        metricPreference: metricPreference,
        pace: pace
      )
      HStack(spacing: 4) {
        if let pace {
          Text(compactPaceLabel(pace))
            .foregroundStyle(compactPaceColor(pace))
        }
        if pace != nil, limit.resetsAt != nil {
          Text("·").foregroundStyle(.tertiary)
        }
        if let resetsAt = limit.resetsAt {
          Text("Resets \(RelativeTimeLabel.string(for: resetsAt, relativeTo: presentationDate))")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .font(.caption2)
      .monospacedDigit()
      .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private var compactAPICost: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("API-price estimate")
          .font(.caption.weight(.semibold))
        Spacer()
        if let estimate = store.apiCostEstimate {
          Text(
            estimate.measurement.amount.formatted(
              .currency(code: estimate.measurement.currency.uppercased()))
          )
          .font(.caption.weight(.semibold).monospacedDigit())
        }
      }

      if let estimate = store.apiCostEstimate {
        Text("\(store.settings.apiCostWindow.label) · \(compactAPICostStatus(estimate))")
          .font(.caption2)
          .foregroundStyle(store.apiCostError == nil ? Color.secondary : Color.orange)
          .lineLimit(1)
      } else if let error = store.apiCostError {
        unavailableRow(error)
      } else {
        loadingRow("Reading local token counters…")
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var compactForecast: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Reset likelihood")
          .font(.caption.weight(.semibold))
        Spacer()
        if let forecast = store.forecast {
          Text(Self.compactForecastPrimaryText(forecast))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(forecast.resetAnnounced ? NotchTheme.success : .primary)
        }
      }

      if let forecast = store.forecast {
        Link(compactForecastStatus(forecast), destination: ResetForecast.sourceURL)
          .font(.caption2)
          .lineLimit(1)
      } else if let error = store.forecastError {
        unavailableRow(error)
      } else {
        loadingRow("Loading third-party forecast…")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Unofficial reset forecast")
    .accessibilityValue(
      store.forecast.map(Self.compactForecastAccessibilityValue) ?? "Unavailable"
    )
  }

  nonisolated static func compactForecastPrimaryText(_ forecast: ResetForecast) -> String {
    forecast.resetAnnounced ? "Announced" : "\(Int(forecast.score.rounded()))%"
  }

  nonisolated static func compactForecastAccessibilityValue(_ forecast: ResetForecast) -> String {
    forecast.resetAnnounced
      ? "A Codex quota reset has been announced"
      : "\(Int(forecast.score.rounded())) percent likelihood in the next 48 hours"
  }

  private func compactPaceLabel(_ pace: QuotaPace) -> String {
    let balance = Int(abs(pace.balancePercent).rounded())
    return switch pace.status {
    case .reserve: "+\(balance)% vs pace"
    case .onPace: "On pace"
    case .deficit: "-\(balance)% vs pace"
    }
  }

  private func compactPaceColor(_ pace: QuotaPace) -> Color {
    switch pace.status {
    case .reserve: NotchTheme.success
    case .onPace: .secondary
    case .deficit:
      abs(pace.balancePercent) < 15 ? NotchTheme.warning : NotchTheme.failure
    }
  }

  private func compactAPICostStatus(_ estimate: LocalCodexCostEstimate) -> String {
    if store.apiCostError != nil { return "Refresh failed · last estimate · not a bill" }
    if estimate.measurement.coverage == .partial || estimate.unpricedTokenCount > 0 {
      return "Partial API-rate estimate · not a bill"
    }
    return "API-rate estimate · not a bill"
  }

  private func compactForecastStatus(_ forecast: ResetForecast) -> String {
    let freshness =
      forecast.fetchedAt.map {
        " · updated \(RelativeTimeLabel.string(for: $0, relativeTo: presentationDate))"
      } ?? ""
    return "Next 48h\(freshness)"
  }

  private var apiEquivalentCost: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text("API-price equivalent")
            .font(.caption.weight(.semibold))
          Text("This Mac · \(store.settings.apiCostWindow.label.lowercased())")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      if let estimate = store.apiCostEstimate {
        HStack(alignment: .firstTextBaseline) {
          Text(
            estimate.measurement.amount.formatted(
              .currency(code: estimate.measurement.currency.uppercased()))
          )
          .font(.title3.weight(.semibold).monospacedDigit())
          Spacer()
          VStack(alignment: .trailing, spacing: 1) {
            Text("Reviewed OpenAI rates")
            if let pricingAsOf = estimate.measurement.pricingAsOf {
              Text("as of \(pricingAsOf.formatted(date: .abbreviated, time: .omitted))")
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        Text(
          "Updated \(RelativeTimeLabel.string(for: estimate.refreshedAt, relativeTo: presentationDate))"
        )
        .font(.caption2)
        .foregroundStyle(store.apiCostError == nil ? Color.secondary : Color.orange)

        if estimate.measurement.coverage == .partial || estimate.unpricedTokenCount > 0 {
          Label("Partial estimate · some local usage was excluded", systemImage: "circle.dashed")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if store.apiCostError != nil {
          Label("Refresh failed · showing the last estimate", systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      } else if let error = store.apiCostError {
        unavailableRow(error)
      } else {
        loadingRow("Reading local token counters…")
      }

      Text(
        "Estimate only; not your subscription charge or an actual bill. Tool fees and unsupported models are excluded."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Link("OpenAI pricing", destination: Self.openAIPriceURL)
        .font(.caption2)
    }
    .accessibilityElement(children: .contain)
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
        Spacer(minLength: 0)
      }

      if let snapshot = store.snapshot {
        Text(officialFreshness(snapshot))
          .font(.caption2)
          .foregroundStyle(store.officialError == nil ? Color.secondary : Color.orange)
        if store.officialError != nil {
          Label("Refresh failed", systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ForEach(visibleQuotaLimits(snapshot.limits)) { limit in
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
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Reset likelihood")
            .font(.caption.weight(.semibold))
          Text("Unofficial · next 48h")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let forecast = store.forecast {
          Text(Self.compactForecastPrimaryText(forecast))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(forecast.resetAnnounced ? NotchTheme.success : .primary)
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
          Link(ResetForecast.sourceName, destination: ResetForecast.sourceURL)
          Text(
            "· updated \(RelativeTimeLabel.string(for: fetchedAt, relativeTo: presentationDate))"
          )
          if let checkedAt = store.lastForecastRefresh {
            Text(
              "· checked \(RelativeTimeLabel.string(for: checkedAt, relativeTo: presentationDate))"
            )
          }
        }
        .font(.caption2)
        .foregroundStyle(store.forecastError == nil ? Color.secondary : Color.orange)
        .lineLimit(1)
      } else if store.forecast != nil {
        Link(ResetForecast.sourceName, destination: ResetForecast.sourceURL)
          .font(.caption2)
      }

      if let error = store.forecastError, store.forecast != nil {
        Label("Stale data · \(error)", systemImage: "exclamationmark.circle")
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if store.forecastError == ResetForecastServiceError.unavailable.errorDescription {
        Text("Source outage · Cowlick does not use the website's fallback snapshot.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("Third-party data as provided · not a Cowlick estimate or guarantee.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Unofficial reset forecast")
    .accessibilityValue(
      store.forecast.map(Self.compactForecastAccessibilityValue) ?? "Unavailable"
    )
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

  private func visibleQuotaLimits(_ limits: [CodexUsageLimit]) -> [CodexUsageLimit] {
    Self.visibleQuotaLimits(
      limits,
      showFiveHour: store.settings.showFiveHourQuotaWindow,
      showWeekly: store.settings.showWeeklyQuotaWindow,
      showSpark: store.settings.showSparkQuotaWindow
    )
  }

  nonisolated static func visibleQuotaLimits(
    _ limits: [CodexUsageLimit],
    showFiveHour: Bool,
    showWeekly: Bool,
    showSpark: Bool
  ) -> [CodexUsageLimit] {
    limits.filter { limit in
      switch quotaWindowKind(for: limit) {
      case .fiveHour: showFiveHour
      case .weekly: showWeekly
      case .spark: showSpark
      case .other: true
      }
    }
  }

  nonisolated static func quotaWindowKind(for limit: CodexUsageLimit) -> QuotaWindowKind {
    let words = "\(limit.id) \(limit.name)".lowercased().split { !$0.isLetter && !$0.isNumber }
    let wordSet = Set(words.map(String.init))

    let compactName = words.joined()
    if wordSet.contains("spark") || compactName.contains("codexspark") { return .spark }
    if limit.windowDurationMinutes == 300 { return .fiveHour }
    if limit.windowDurationMinutes == 10_080 { return .weekly }

    if compactName.contains("5hour") || compactName.contains("fivehour")
      || compactName.contains("5hr") || compactName.contains("fivehr")
    {
      return .fiveHour
    }
    if wordSet.contains("weekly") || compactName.contains("7day")
      || compactName.contains("1week")
    {
      return .weekly
    }
    return .other
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

  private static let openAIPriceURL = URL(
    string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")!
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
