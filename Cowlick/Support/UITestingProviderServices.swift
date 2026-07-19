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
