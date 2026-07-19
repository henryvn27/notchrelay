import Foundation
import Observation

enum ProviderBillingCalendar {
  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()
}

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

struct ProviderBillingPresentation: Equatable {
  let showsAmount: Bool
  let detail: String

  static func resolve(
    snapshot: ActualBilledSnapshot?,
    errorMessage: String?,
    now: Date = Date()
  ) -> Self {
    guard let snapshot else {
      return Self(
        showsAmount: false,
        detail: errorMessage == nil ? "Not refreshed" : "Refresh failed"
      )
    }

    let updated = "updated \(age(of: snapshot.fetchedAt, relativeTo: now))"
    guard coversCurrentMonth(snapshot.interval, now: now) else {
      return Self(
        showsAmount: false,
        detail: errorMessage == nil
          ? "No current-month data · \(updated)"
          : "No current-month data · refresh failed · \(updated)"
      )
    }
    guard errorMessage != nil else {
      return Self(
        showsAmount: true,
        detail: snapshot.measurement.coverage == .partial
          ? "Partial MTD · excludes Priority Tier" : "Month to date"
      )
    }
    let coverage =
      snapshot.measurement.coverage == .partial
      ? "Partial MTD · excludes Priority Tier" : "Month to date"
    return Self(
      showsAmount: true,
      detail: "\(coverage) · stale after failed refresh · \(updated)"
    )
  }

  private static func coversCurrentMonth(
    _ interval: DateInterval,
    now: Date
  ) -> Bool {
    guard let monthStart = ProviderBillingCalendar.utc.dateInterval(of: .month, for: now)?.start
    else {
      return false
    }
    return interval.start <= monthStart && interval.end > monthStart
  }

  private static func age(of date: Date, relativeTo now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
    return "\(Int(seconds / 86_400))d ago"
  }
}
