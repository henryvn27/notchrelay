import Foundation

enum UsageMetricPreference: String, CaseIterable, Codable, Sendable {
  case remaining
  case used

  var label: String {
    switch self {
    case .remaining: "Remaining"
    case .used: "Used"
    }
  }

  var accessibilityLabel: String { rawValue }

  func displayedPercent(forUsedPercent usedPercent: Double) -> Double? {
    guard usedPercent.isFinite else { return nil }
    let usedPercent = min(max(usedPercent, 0), 100)
    return self == .used ? usedPercent : 100 - usedPercent
  }
}

enum NotchWingMetric: String, CaseIterable, Identifiable, Sendable {
  case quotaPercentage
  case blank
  case usageMeaning
  case windowProgress
  case paceBalance
  case resetCountdown
  case projectedRunway
  case resetProbability

  var id: String { rawValue }

  var label: String {
    switch self {
    case .quotaPercentage: "Quota percentage"
    case .blank: "Blank"
    case .usageMeaning: "Used / left label"
    case .windowProgress: "Window progress"
    case .paceBalance: "Pace balance"
    case .resetCountdown: "Time to reset"
    case .projectedRunway: "Projected runway"
    case .resetProbability: "Reset probability"
    }
  }

  var detail: String {
    switch self {
    case .quotaPercentage: "Shows the primary Codex quota percentage."
    case .blank: "Leaves this wing empty."
    case .usageMeaning: "Clarifies whether the primary percentage is used or remaining."
    case .windowProgress: "Shows how far through the longest quota window you are."
    case .paceBalance: "Shows points banked (+) or behind pace (-)."
    case .resetCountdown: "Shows the time until the longest quota window resets."
    case .projectedRunway: "Shows projected cushion (+) or shortfall (-) at reset."
    case .resetProbability: "Shows the optional Will Codex Reset? forecast."
    }
  }
}

typealias NotchSecondaryMetric = NotchWingMetric

enum CompactUsageTone: Equatable, Sendable {
  case neutral
  case positive
  case caution
  case critical
}

struct CompactUsageSecondaryValue: Equatable, Sendable {
  let text: String
  let accessibilityLabel: String
  let tone: CompactUsageTone
}

enum CompactUsageSecondaryFormatter {
  static func value(
    for metric: NotchWingMetric,
    snapshot: CodexUsageSnapshot?,
    preference: UsageMetricPreference,
    forecast: ResetForecast?,
    now: Date = .init()
  ) -> CompactUsageSecondaryValue? {
    switch metric {
    case .quotaPercentage:
      guard let limit = snapshot?.primaryLimit else { return nil }
      let percent = Int(limit.displayedPercent(for: preference).rounded())
      return .init(
        text: "\(percent)%",
        accessibilityLabel: "Codex quota, \(percent) percent \(preference.accessibilityLabel)",
        tone: .neutral
      )
    case .blank:
      return nil
    case .usageMeaning:
      guard snapshot?.primaryLimit != nil else { return nil }
      let text = preference == .remaining ? "left" : "used"
      return .init(
        text: text,
        accessibilityLabel: "Primary quota percentage shows \(text)",
        tone: .neutral
      )
    case .windowProgress:
      guard let pace = planningContext(snapshot: snapshot, now: now)?.pace else { return nil }
      let percent = Int(pace.expectedUsedPercent.rounded())
      return .init(
        text: "\(percent)% thru",
        accessibilityLabel: "\(percent) percent through the quota window",
        tone: .neutral
      )
    case .paceBalance:
      guard let pace = planningContext(snapshot: snapshot, now: now)?.pace else { return nil }
      let points = Int(abs(pace.balancePercent).rounded())
      if points == 0 {
        return .init(text: "on pace", accessibilityLabel: "Usage is on pace", tone: .neutral)
      }
      if pace.balancePercent > 0 {
        return .init(
          text: "+\(points)%",
          accessibilityLabel: "\(points) percentage points ahead of usage pace",
          tone: .positive
        )
      }
      return .init(
        text: "-\(points)%",
        accessibilityLabel: "\(points) percentage points behind usage pace",
        tone: points >= 15 ? .critical : .caution
      )
    case .resetCountdown:
      guard let resetsAt = planningLimit(snapshot: snapshot)?.resetsAt,
        let duration = compactDuration(resetsAt.timeIntervalSince(now))
      else { return nil }
      return .init(
        text: duration,
        accessibilityLabel: "Quota resets in \(duration)",
        tone: .neutral
      )
    case .projectedRunway:
      guard
        let exhaustion = planningContext(snapshot: snapshot, now: now)?.pace.exhaustionForecast
      else { return nil }
      if exhaustion.willLastThroughReset {
        guard let duration = compactDuration(exhaustion.timeAfterReset) else {
          return .init(
            text: "on pace",
            accessibilityLabel: "Current usage is projected to last until reset",
            tone: .neutral
          )
        }
        return .init(
          text: "+\(duration)",
          accessibilityLabel: "Usage is projected to last \(duration) beyond reset",
          tone: .positive
        )
      }
      guard let duration = compactDuration(exhaustion.timeBeforeReset) else { return nil }
      return .init(
        text: "-\(duration)",
        accessibilityLabel: "Usage is projected to run out \(duration) before reset",
        tone: exhaustion.timeBeforeReset >= 86_400 ? .critical : .caution
      )
    case .resetProbability:
      guard let forecast else { return nil }
      if forecast.resetAnnounced {
        return .init(
          text: "reset",
          accessibilityLabel: "A Codex quota reset has been announced",
          tone: .positive
        )
      }
      let score = Int(forecast.score.clamped(to: 0...100).rounded())
      return .init(
        text: "\(score)% reset",
        accessibilityLabel: "\(score) percent reset probability in the next 48 hours",
        tone: .neutral
      )
    }
  }

  private static func planningContext(
    snapshot: CodexUsageSnapshot?,
    now: Date
  ) -> (limit: CodexUsageLimit, pace: QuotaPace)? {
    guard let snapshot, let limit = planningLimit(snapshot: snapshot),
      let pace = QuotaPaceCalculator.pace(
        for: QuotaWindow(
          usedPercent: limit.usedPercent,
          duration: limit.windowDurationMinutes.map { TimeInterval($0 * 60) },
          resetsAt: limit.resetsAt
        ),
        observedAt: snapshot.fetchedAt,
        now: now
      )
    else { return nil }
    return (limit, pace)
  }

  private static func planningLimit(snapshot: CodexUsageSnapshot?) -> CodexUsageLimit? {
    snapshot?.limits
      .filter { ($0.windowDurationMinutes ?? 0) > 0 }
      .max(by: { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) })
  }

  private static func compactDuration(_ interval: TimeInterval) -> String? {
    guard interval.isFinite, interval > 0 else { return nil }
    if interval >= 86_400 { return "\(max(1, Int((interval / 86_400).rounded())))d" }
    if interval >= 3_600 { return "\(max(1, Int((interval / 3_600).rounded())))h" }
    return "\(max(1, Int((interval / 60).rounded())))m"
  }
}

struct QuotaWindow: Equatable, Codable, Sendable {
  let usedPercent: Double
  let duration: TimeInterval?
  let resetsAt: Date?
}

enum QuotaPaceStatus: String, Codable, Sendable {
  case reserve
  case onPace
  case deficit
}

struct QuotaExhaustionForecast: Equatable, Codable, Sendable {
  let estimatedAt: Date
  let resetsAt: Date

  var willLastThroughReset: Bool { estimatedAt >= resetsAt }
  var timeBeforeReset: TimeInterval { max(0, resetsAt.timeIntervalSince(estimatedAt)) }
  var timeAfterReset: TimeInterval { max(0, estimatedAt.timeIntervalSince(resetsAt)) }
}

struct QuotaPace: Equatable, Codable, Sendable {
  let expectedUsedPercent: Double
  let actualUsedPercent: Double
  /// Positive values are reserve; negative values are deficit.
  let balancePercent: Double
  let status: QuotaPaceStatus
  let exhaustionForecast: QuotaExhaustionForecast?

  var reservePercent: Double { max(balancePercent, 0) }
  var deficitPercent: Double { max(-balancePercent, 0) }

  func expectedDisplayedPercent(for preference: UsageMetricPreference) -> Double {
    preference.displayedPercent(forUsedPercent: expectedUsedPercent) ?? 0
  }
}

enum QuotaPaceCalculator {
  static let minimumElapsedFraction = 0.03
  static let minimumObservedUsagePercent = 1.0

  static func pace(
    for window: QuotaWindow,
    observedAt: Date? = nil,
    now: Date = .init()
  ) -> QuotaPace? {
    guard window.usedPercent.isFinite,
      let duration = window.duration,
      duration.isFinite,
      duration > 0,
      let resetsAt = window.resetsAt
    else { return nil }

    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining.isFinite, remaining > 0, remaining <= duration else { return nil }

    let elapsedFraction = (1 - remaining / duration).clamped(to: 0...1)
    guard elapsedFraction >= minimumElapsedFraction else { return nil }

    let expected = elapsedFraction * 100
    let actual = window.usedPercent.clamped(to: 0...100)
    let balance = expected - actual
    let status: QuotaPaceStatus =
      if abs(balance) < 0.000_001 {
        .onPace
      } else if balance > 0 {
        .reserve
      } else {
        .deficit
      }

    let observationDate = observedAt ?? now
    let observedElapsed = duration - resetsAt.timeIntervalSince(observationDate)
    let exhaustionForecast: QuotaExhaustionForecast? =
      if actual >= minimumObservedUsagePercent {
        forecast(
          actualUsedPercent: actual,
          elapsed: observedElapsed,
          observedAt: observationDate,
          resetsAt: resetsAt
        )
      } else {
        nil
      }

    return QuotaPace(
      expectedUsedPercent: expected,
      actualUsedPercent: actual,
      balancePercent: balance,
      status: status,
      exhaustionForecast: exhaustionForecast
    )
  }

  private static func forecast(
    actualUsedPercent: Double,
    elapsed: TimeInterval,
    observedAt: Date,
    resetsAt: Date
  ) -> QuotaExhaustionForecast? {
    let burnRate = actualUsedPercent / elapsed
    guard burnRate.isFinite, burnRate > 0 else { return nil }
    let timeToEmpty = (100 - actualUsedPercent) / burnRate
    guard timeToEmpty.isFinite, timeToEmpty >= 0 else { return nil }
    return QuotaExhaustionForecast(
      estimatedAt: observedAt.addingTimeInterval(timeToEmpty),
      resetsAt: resetsAt
    )
  }
}

enum CostMeasurementKind: String, Codable, Sendable {
  case actualBilled
  case apiEquivalentEstimate
}

enum CostCoverage: String, Codable, Sendable {
  case accountWide
  case thisMac
  case partial
}

struct CostMeasurement: Equatable, Codable, Sendable {
  let kind: CostMeasurementKind
  let amount: Decimal
  let currency: String
  let interval: DateInterval
  let coverage: CostCoverage
  let pricingAsOf: Date?
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
