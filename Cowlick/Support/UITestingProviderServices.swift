import Foundation

actor InMemoryCredentialSecretStore: CredentialSecretStore {
  private var secrets: [CredentialReference: Data] = [:]

  func store(_ secret: Data, for reference: CredentialReference) throws {
    guard !secret.isEmpty, secret.count <= KeychainCredentialSecretStore.maximumSecretSize else {
      throw CredentialSecretStoreError.invalidSecret
    }
    secrets[reference] = secret
  }

  func secret(for reference: CredentialReference) -> Data? {
    secrets[reference]
  }

  func deleteSecret(for reference: CredentialReference) {
    secrets.removeValue(forKey: reference)
  }
}

struct NoNetworkProviderCostService: ProviderCostFetching {
  func fetchActualCosts(
    accountID _: UUID,
    credential _: Data,
    interval _: DateInterval
  ) async throws -> ActualBilledSnapshot {
    throw NoNetworkProviderCostServiceError.networkDisabled
  }
}

enum NoNetworkProviderCostServiceError: LocalizedError {
  case networkDisabled

  var errorDescription: String? {
    "Provider billing network access is disabled during UI testing."
  }
}

struct UITestingCodexUsageService: CodexUsageFetching {
  func fetchUsage() async throws -> CodexUsageSnapshot {
    let now = Date()
    return CodexUsageSnapshot(
      limits: [
        CodexUsageLimit(
          id: "five-hour", name: "5-hour window", usedPercent: 78,
          resetsAt: now.addingTimeInterval(90 * 60), windowDurationMinutes: 5 * 60),
        CodexUsageLimit(
          id: "weekly", name: "Weekly", usedPercent: 82,
          resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
          windowDurationMinutes: 7 * 24 * 60),
      ],
      planType: "plus",
      fetchedAt: now
    )
  }
}

struct UITestingLocalCodexCostService: LocalCodexCostEstimating {
  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate {
    let pricingDate = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2026, month: 7, day: 20))!
    return LocalCodexCostEstimate(
      measurement: CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: Decimal(string: "47.28")!,
        currency: "USD",
        interval: interval,
        coverage: .partial,
        pricingAsOf: pricingDate
      ),
      pricedTokenCount: 8_420_000,
      unpricedTokenCount: 84_000,
      excludedToolFees: true,
      exclusionReasons: [.unknownModel],
      scannedFileCount: 18,
      refreshedAt: Date()
    )
  }

  func resetCache() async {}
}

struct UITestingResetForecastService: ResetForecastFetching {
  func fetchForecast() async throws -> ResetForecast {
    let now = Date()
    return ResetForecast(
      score: 64,
      resetAnnounced: false,
      fetchedAt: now.addingTimeInterval(-8 * 60),
      nextRefreshAt: now.addingTimeInterval(7 * 60)
    )
  }
}
