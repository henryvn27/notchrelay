import Foundation

struct ActualBilledSnapshot: Equatable, Codable, Sendable {
  let accountID: UUID
  let provider: UsageProvider
  let amount: Decimal
  let currency: String
  let interval: DateInterval
  let fetchedAt: Date

  var measurement: CostMeasurement {
    CostMeasurement(
      kind: .actualBilled,
      amount: amount,
      currency: currency,
      interval: interval,
      coverage: .accountWide,
      pricingAsOf: nil
    )
  }
}
