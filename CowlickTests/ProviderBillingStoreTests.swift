import Foundation
import XCTest

@testable import Cowlick

@MainActor
final class ProviderBillingStoreTests: XCTestCase {
  func testCredentialReferencesKeepSameProviderAccountsSeparated() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = RecordingProviderCostService(provider: .openAIAPI)
    let first = makeAccount(provider: .openAIAPI, alias: "Work")
    let second = makeAccount(provider: .openAIAPI, alias: "Personal")
    try await credentials.store(Data("first-key".utf8), for: first.credentialReference)
    try await credentials.store(Data("second-key".utf8), for: second.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    await store.refresh(account: first, interval: testInterval)
    await store.refresh(account: second, interval: testInterval)
    let received = await service.receivedCredentials

    XCTAssertEqual(received[first.id], Data("first-key".utf8))
    XCTAssertEqual(received[second.id], Data("second-key".utf8))
    XCTAssertNotNil(store.snapshots[first.id])
    XCTAssertNotNil(store.snapshots[second.id])
    XCTAssertTrue(store.errors.isEmpty)
  }

  func testFailurePreservesLastGoodSnapshotAndStoresOnlySanitizedError() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = RecordingProviderCostService(provider: .openAIAPI)
    let account = makeAccount(provider: .openAIAPI, alias: "Work")
    try await credentials.store(Data("admin-key".utf8), for: account.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    await store.refresh(account: account, interval: testInterval)
    let first = store.snapshots[account.id]
    await service.setFailure(.unavailable)
    await store.refresh(account: account, interval: testInterval)

    XCTAssertEqual(store.snapshots[account.id], first)
    XCTAssertEqual(store.errors[account.id], "Provider billing data is unavailable.")
    XCTAssertFalse(store.errors[account.id]?.contains("admin-key") ?? true)
  }

  func testUnsupportedPersonalProviderNeverCallsBillingAdapter() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = RecordingProviderCostService(provider: .openAIAPI)
    let account = makeAccount(provider: .codex, alias: "Codex")
    try await credentials.store(Data("unused".utf8), for: account.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    await store.refresh(account: account, interval: testInterval)
    let callCount = await service.callCount

    XCTAssertEqual(callCount, 0)
    XCTAssertEqual(
      store.errors[account.id],
      "This provider does not expose supported organization billing data.")
  }

  func testRemoveInvalidatesPendingRefreshResult() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = ControlledProviderCostService(provider: .openAIAPI)
    let account = makeAccount(provider: .openAIAPI, alias: "Work")
    try await credentials.store(Data("admin-key".utf8), for: account.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    let refresh = Task { await store.refresh(account: account, interval: testInterval) }
    await service.waitForCalls(1)
    store.remove(accountID: account.id)
    await service.complete(call: 0, amount: 4)
    await refresh.value

    XCTAssertNil(store.snapshots[account.id])
    XCTAssertNil(store.errors[account.id])
    XCTAssertFalse(store.refreshingAccountIDs.contains(account.id))
  }

  func testResetInvalidatesPendingRefreshError() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = ControlledProviderCostService(provider: .openAIAPI)
    let account = makeAccount(provider: .openAIAPI, alias: "Work")
    try await credentials.store(Data("admin-key".utf8), for: account.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    let refresh = Task { await store.refresh(account: account, interval: testInterval) }
    await service.waitForCalls(1)
    store.reset()
    await service.fail(call: 0, error: .unavailable)
    await refresh.value

    XCTAssertTrue(store.snapshots.isEmpty)
    XCTAssertTrue(store.errors.isEmpty)
    XCTAssertTrue(store.refreshingAccountIDs.isEmpty)
  }

  func testNewerRefreshWinsWhenOlderRequestFinishesLast() async throws {
    let credentials = FakeCredentialSecretStore()
    let service = ControlledProviderCostService(provider: .openAIAPI)
    let account = makeAccount(provider: .openAIAPI, alias: "Work")
    try await credentials.store(Data("admin-key".utf8), for: account.credentialReference)
    let store = ProviderBillingStore(
      credentialStore: credentials, openAIService: service,
      anthropicService: RecordingProviderCostService(provider: .anthropicAPI))

    let older = Task { await store.refresh(account: account, interval: testInterval) }
    await service.waitForCalls(1)
    let newer = Task { await store.refresh(account: account, interval: testInterval) }
    await service.waitForCalls(2)
    await service.complete(call: 1, amount: 8)
    await newer.value
    XCTAssertEqual(store.snapshots[account.id]?.amount, 8)
    XCTAssertTrue(store.refreshingAccountIDs.contains(account.id))

    await service.complete(call: 0, amount: 3)
    await older.value

    XCTAssertEqual(store.snapshots[account.id]?.amount, 8)
    XCTAssertFalse(store.refreshingAccountIDs.contains(account.id))
  }

  private var testInterval: DateInterval {
    DateInterval(start: .distantPast, duration: 86_400)
  }

  private func makeAccount(provider: UsageProvider, alias: String) -> ProviderAccount {
    ProviderAccount(
      id: UUID(), provider: provider, alias: alias,
      credentialReference: CredentialReference(id: UUID()))
  }
}

private actor FakeCredentialSecretStore: CredentialSecretStore {
  private var secrets: [CredentialReference: Data] = [:]

  func store(_ secret: Data, for reference: CredentialReference) async throws {
    secrets[reference] = secret
  }

  func secret(for reference: CredentialReference) async throws -> Data? {
    secrets[reference]
  }

  func deleteSecret(for reference: CredentialReference) async throws {
    secrets.removeValue(forKey: reference)
  }
}

private actor RecordingProviderCostService: ProviderCostFetching {
  private let provider: UsageProvider
  private(set) var receivedCredentials: [UUID: Data] = [:]
  private(set) var callCount = 0
  private var failure: ProviderCostServiceError?

  init(provider: UsageProvider) {
    self.provider = provider
  }

  func setFailure(_ failure: ProviderCostServiceError?) {
    self.failure = failure
  }

  func fetchActualCosts(
    accountID: UUID,
    credential: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot {
    callCount += 1
    receivedCredentials[accountID] = credential
    if let failure { throw failure }
    return ActualBilledSnapshot(
      accountID: accountID,
      provider: provider,
      amount: Decimal(callCount),
      currency: "USD",
      interval: interval,
      fetchedAt: Date(timeIntervalSince1970: TimeInterval(callCount))
    )
  }
}

private actor ControlledProviderCostService: ProviderCostFetching {
  private struct PendingCall {
    let accountID: UUID
    let interval: DateInterval
    let continuation: CheckedContinuation<ActualBilledSnapshot, Error>
  }

  private let provider: UsageProvider
  private var calls: [PendingCall] = []
  private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(provider: UsageProvider) {
    self.provider = provider
  }

  func fetchActualCosts(
    accountID: UUID,
    credential _: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      calls.append(
        PendingCall(accountID: accountID, interval: interval, continuation: continuation)
      )
      resumeSatisfiedWaiters()
    }
  }

  func waitForCalls(_ count: Int) async {
    guard calls.count < count else { return }
    await withCheckedContinuation { continuation in
      callWaiters.append((count, continuation))
    }
  }

  func complete(call index: Int, amount: Decimal) {
    let call = calls[index]
    call.continuation.resume(
      returning: ActualBilledSnapshot(
        accountID: call.accountID,
        provider: provider,
        amount: amount,
        currency: "USD",
        interval: call.interval,
        fetchedAt: Date()
      ))
  }

  func fail(call index: Int, error: ProviderCostServiceError) {
    calls[index].continuation.resume(throwing: error)
  }

  private func resumeSatisfiedWaiters() {
    let satisfied = callWaiters.filter { calls.count >= $0.0 }
    callWaiters.removeAll { calls.count >= $0.0 }
    for (_, continuation) in satisfied { continuation.resume() }
  }
}
