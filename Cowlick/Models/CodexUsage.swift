import Foundation

struct CodexUsageLimit: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let usedPercent: Double
  let resetsAt: Date?
  let windowDurationMinutes: Int?

  func displayedPercent(for preference: UsageMetricPreference) -> Double {
    preference.displayedPercent(forUsedPercent: usedPercent) ?? 0
  }

  func pace(now: Date = Date()) -> QuotaPace? {
    QuotaPaceCalculator.pace(
      for: QuotaWindow(
        usedPercent: usedPercent,
        duration: windowDurationMinutes.map { TimeInterval($0 * 60) },
        resetsAt: resetsAt
      ),
      now: now
    )
  }
}

struct CodexUsageSnapshot: Equatable, Sendable {
  let limits: [CodexUsageLimit]
  let planType: String?
  let fetchedAt: Date

  var highestUsedPercent: Double? { limits.map(\.usedPercent).max() }
  var primaryLimit: CodexUsageLimit? { limits.first }
}
