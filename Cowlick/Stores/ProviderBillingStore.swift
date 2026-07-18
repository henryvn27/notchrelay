import Foundation
import Observation

@MainActor
@Observable
final class ProviderBillingStore {
  private(set) var snapshots: [UUID: ActualBilledSnapshot] = [:]
  private(set) var errors: [UUID: String] = [:]
  private(set) var refreshingAccountIDs = Set<UUID>()

  private let credentialStore: any CredentialSecretStore
  private let openAIService: any ProviderCostFetching
  private let anthropicService: any ProviderCostFetching
  private var currentRefreshTokens: [UUID: UUID] = [:]
  private var inFlightRefreshTokens: [UUID: Set<UUID>] = [:]

  init(
    credentialStore: any CredentialSecretStore,
    openAIService: any ProviderCostFetching = OpenAIAdminCostService(),
    anthropicService: any ProviderCostFetching = AnthropicAdminCostService()
  ) {
    self.credentialStore = credentialStore
    self.openAIService = openAIService
    self.anthropicService = anthropicService
  }

  func refresh(account: ProviderAccount, interval: DateInterval) async {
    let token = UUID()
    currentRefreshTokens[account.id] = token
    inFlightRefreshTokens[account.id, default: []].insert(token)
    refreshingAccountIDs.insert(account.id)
    defer { finishRefresh(accountID: account.id, token: token) }

    do {
      guard let credential = try await credentialStore.secret(for: account.credentialReference)
      else {
        throw ProviderBillingStoreError.missingCredential
      }
      let service: any ProviderCostFetching =
        switch account.provider {
        case .openAIAPI: openAIService
        case .anthropicAPI: anthropicService
        default: throw ProviderBillingStoreError.unsupportedProvider
        }
      let snapshot = try await service.fetchActualCosts(
        accountID: account.id,
        credential: credential,
        interval: interval
      )
      guard snapshot.accountID == account.id, snapshot.provider == account.provider else {
        throw ProviderBillingStoreError.mismatchedResponse
      }
      guard currentRefreshTokens[account.id] == token else { return }
      snapshots[account.id] = snapshot
      errors.removeValue(forKey: account.id)
    } catch {
      guard currentRefreshTokens[account.id] == token else { return }
      errors[account.id] = EventLogger.sanitizeError(error.localizedDescription)
    }
  }

  func remove(accountID: UUID) {
    currentRefreshTokens.removeValue(forKey: accountID)
    inFlightRefreshTokens.removeValue(forKey: accountID)
    snapshots.removeValue(forKey: accountID)
    errors.removeValue(forKey: accountID)
    refreshingAccountIDs.remove(accountID)
  }

  func reset() {
    currentRefreshTokens.removeAll()
    inFlightRefreshTokens.removeAll()
    snapshots.removeAll()
    errors.removeAll()
    refreshingAccountIDs.removeAll()
  }

  private func finishRefresh(accountID: UUID, token: UUID) {
    if currentRefreshTokens[accountID] == token {
      currentRefreshTokens.removeValue(forKey: accountID)
    }
    inFlightRefreshTokens[accountID]?.remove(token)
    if inFlightRefreshTokens[accountID]?.isEmpty != false {
      inFlightRefreshTokens.removeValue(forKey: accountID)
      refreshingAccountIDs.remove(accountID)
    }
  }
}

enum ProviderBillingStoreError: LocalizedError, Equatable {
  case missingCredential
  case unsupportedProvider
  case mismatchedResponse

  var errorDescription: String? {
    switch self {
    case .missingCredential: "This account has no credential in Keychain."
    case .unsupportedProvider: "This provider does not expose supported organization billing data."
    case .mismatchedResponse: "The provider returned billing data for the wrong account."
    }
  }
}
