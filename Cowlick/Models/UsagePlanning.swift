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

struct QuotaPace: Equatable, Codable, Sendable {
  let expectedUsedPercent: Double
  let actualUsedPercent: Double
  /// Positive values are reserve; negative values are deficit.
  let balancePercent: Double
  let status: QuotaPaceStatus

  var reservePercent: Double { max(balancePercent, 0) }
  var deficitPercent: Double { max(-balancePercent, 0) }

  func expectedDisplayedPercent(for preference: UsageMetricPreference) -> Double {
    preference.displayedPercent(forUsedPercent: expectedUsedPercent) ?? 0
  }
}

enum QuotaPaceCalculator {
  static let minimumElapsedFraction = 0.03

  static func pace(for window: QuotaWindow, now: Date = .init()) -> QuotaPace? {
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

    return QuotaPace(
      expectedUsedPercent: expected,
      actualUsedPercent: actual,
      balancePercent: balance,
      status: status
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
