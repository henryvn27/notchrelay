import Foundation
import XCTest

@testable import Cowlick

@MainActor
final class ProviderAccountsControllerTests: XCTestCase {
  func testMultipleSameProviderAccountsKeepBillingCredentialsAndSelectionSeparate() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    let first = try await fixture.controller.addAccount(
      provider: .openAIAPI, alias: "Work", credential: Data("work-key".utf8))
    let second = try await fixture.controller.addAccount(
      provider: .openAIAPI, alias: "Personal", credential: Data("personal-key".utf8))

    await fixture.controller.refreshAll()

    XCTAssertEqual(fixture.controller.accounts.map(\.id), [first.id, second.id])
    XCTAssertEqual(fixture.billing.snapshots.count, 2)
    let receivedCredentials = await fixture.costService.receivedCredentials
    XCTAssertEqual(receivedCredentials[first.id], Data("work-key".utf8))
    XCTAssertEqual(receivedCredentials[second.id], Data("personal-key".utf8))
    try await fixture.controller.replaceCredential(
      for: first.id, credential: Data("replacement-key".utf8))
    XCTAssertNil(fixture.billing.snapshots[first.id])
    XCTAssertNotNil(fixture.billing.snapshots[second.id])
    let replacementCredential = try await fixture.credentials.secret(
      for: first.credentialReference)
    XCTAssertEqual(replacementCredential, Data("replacement-key".utf8))
    XCTAssertTrue(fixture.controller.selectAccount(id: first.id))
    XCTAssertEqual(fixture.settings.selectedProviderAccountID, first.id)

    try await fixture.controller.removeAccount(id: first.id)

    XCTAssertEqual(fixture.controller.accounts, [second])
    XCTAssertEqual(fixture.controller.selectedAccountID, second.id)
    XCTAssertEqual(fixture.settings.selectedProviderAccountID, second.id)
    XCTAssertNil(fixture.billing.snapshots[first.id])
    XCTAssertNotNil(fixture.billing.snapshots[second.id])
    let removedCredential = try await fixture.credentials.secret(for: first.credentialReference)
    let survivingCredential = try await fixture.credentials.secret(
      for: second.credentialReference)
    XCTAssertNil(removedCredential)
    XCTAssertEqual(survivingCredential, Data("personal-key".utf8))
  }

  func testLoadUsesPersistedSelectionAndFallsBackDeterministically() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    let first = try await fixture.controller.addAccount(
      provider: .openAIAPI, alias: "First", credential: Data("first".utf8))
    let second = try await fixture.controller.addAccount(
      provider: .anthropicAPI, alias: "Second", credential: Data("second".utf8))
    XCTAssertTrue(fixture.controller.selectAccount(id: first.id))
    let reloadedSettings = SettingsStore(defaults: fixture.defaults)
    XCTAssertEqual(reloadedSettings.selectedProviderAccountID, first.id)

    let reloaded = ProviderAccountsController(
      accountStore: fixture.accountStore,
      billingStore: fixture.billing,
      settings: reloadedSettings,
      now: { fixture.now }
    )
    await reloaded.load()
    XCTAssertEqual(reloaded.selectedAccountID, first.id)

    fixture.settings.selectedProviderAccountID = UUID()
    let invalidSelection = ProviderAccountsController(
      accountStore: fixture.accountStore,
      billingStore: fixture.billing,
      settings: fixture.settings,
      now: { fixture.now }
    )
    await invalidSelection.load()

    XCTAssertEqual(invalidSelection.accounts.map(\.id), [first.id, second.id])
    XCTAssertEqual(invalidSelection.selectedAccountID, first.id)
    XCTAssertEqual(fixture.settings.selectedProviderAccountID, first.id)
  }

  func testRefreshUsesMonthToDateInterval() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    let account = try await fixture.controller.addAccount(
      provider: .anthropicAPI, alias: "Team", credential: Data("admin-key".utf8))

    await fixture.controller.refreshSelected()

    let receivedIntervals = await fixture.costService.receivedIntervals
    let interval = try XCTUnwrap(receivedIntervals[account.id])
    XCTAssertEqual(interval.end, fixture.now)
    XCTAssertEqual(
      ProviderBillingCalendar.utc.dateComponents([.year, .month, .day], from: interval.start),
      DateComponents(year: 2026, month: 7, day: 1)
    )
  }

  func testMonthToDateUsesUTCBoundaryWhenLocalCalendarIsInPriorMonth() throws {
    var localCalendar = Calendar(identifier: .gregorian)
    localCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(
      ProviderBillingCalendar.utc.date(
        from: DateComponents(year: 2026, month: 8, day: 1, hour: 0, minute: 30)
      )
    )
    XCTAssertEqual(localCalendar.component(.month, from: now), 7)

    let interval = ProviderAccountsController.monthToDateInterval(
      endingAt: now,
      calendar: localCalendar
    )

    XCTAssertEqual(
      ProviderBillingCalendar.utc.dateComponents(
        [.year, .month, .day, .hour, .minute],
        from: interval.start
      ),
      DateComponents(year: 2026, month: 8, day: 1, hour: 0, minute: 0)
    )
    XCTAssertEqual(interval.end, now)
  }

  func testUnsupportedProvidersAreNotAccountOptions() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }

    XCTAssertEqual(UsageProvider.supportedBillingAccounts, [.openAIAPI, .anthropicAPI])
    do {
      _ = try await fixture.controller.addAccount(
        provider: .codex, alias: "Local", credential: Data("unused".utf8))
      XCTFail("Expected unsupported provider rejection")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .unsupportedProvider)
    }
    XCTAssertTrue(fixture.controller.accounts.isEmpty)
  }

  func testResetClearsBillingAndReloadsAccountsWithoutDeletingCredentials() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    let first = try await fixture.controller.addAccount(
      provider: .openAIAPI, alias: "First", credential: Data("first-key".utf8))
    let second = try await fixture.controller.addAccount(
      provider: .openAIAPI, alias: "Second", credential: Data("second-key".utf8))
    await fixture.controller.refreshAll()
    XCTAssertFalse(fixture.billing.snapshots.isEmpty)
    XCTAssertEqual(fixture.controller.selectedAccountID, second.id)

    fixture.settings.reset()
    await fixture.controller.resetTransientState()

    XCTAssertTrue(fixture.billing.snapshots.isEmpty)
    XCTAssertTrue(fixture.billing.errors.isEmpty)
    XCTAssertEqual(fixture.controller.accounts, [first, second])
    XCTAssertEqual(fixture.controller.selectedAccountID, first.id)
    XCTAssertEqual(fixture.settings.selectedProviderAccountID, first.id)
    let firstCredential = try await fixture.credentials.secret(for: first.credentialReference)
    let secondCredential = try await fixture.credentials.secret(for: second.credentialReference)
    XCTAssertEqual(firstCredential, Data("first-key".utf8))
    XCTAssertEqual(secondCredential, Data("second-key".utf8))
  }

  func testRefreshAllOverlapsFetchesWithFourAccountLimit() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    for index in 0..<6 {
      _ = try await fixture.controller.addAccount(
        provider: .openAIAPI,
        alias: "Account \(index)",
        credential: Data("key-\(index)".utf8)
      )
    }
    await fixture.costService.beginBlocking()

    let refresh = Task { await fixture.controller.refreshAll() }
    await fixture.costService.waitForCalls(4)

    let callsWhileBlocked = await fixture.costService.callCount
    let maximumWhileBlocked = await fixture.costService.maximumActiveCallCount
    XCTAssertEqual(callsWhileBlocked, 4)
    XCTAssertEqual(maximumWhileBlocked, 4)

    await fixture.costService.unblock()
    await refresh.value

    let finalCallCount = await fixture.costService.callCount
    let finalMaximum = await fixture.costService.maximumActiveCallCount
    XCTAssertEqual(finalCallCount, 6)
    XCTAssertEqual(finalMaximum, 4)
  }

  func testResetCancelsQueuedRefreshesAndInvalidatesInFlightResults() async throws {
    let fixture = try ControllerFixture()
    defer { fixture.remove() }
    for index in 0..<6 {
      _ = try await fixture.controller.addAccount(
        provider: .openAIAPI,
        alias: "Account \(index)",
        credential: Data("key-\(index)".utf8)
      )
    }
    await fixture.costService.beginBlocking()

    let refresh = Task { await fixture.controller.refreshAll() }
    await fixture.costService.waitForCalls(4)
    fixture.settings.reset()
    await fixture.controller.resetTransientState()
    await fixture.costService.unblock()
    await refresh.value

    let callCount = await fixture.costService.callCount
    XCTAssertEqual(callCount, 4)
    XCTAssertTrue(fixture.billing.snapshots.isEmpty)
    XCTAssertTrue(fixture.billing.errors.isEmpty)
    XCTAssertTrue(fixture.billing.refreshingAccountIDs.isEmpty)
  }
}

@MainActor
private final class ControllerFixture {
  let directory: URL
  let credentials = ControllerCredentialStore()
  let costService = ControllerCostService()
  let defaults: UserDefaults
  let settings: SettingsStore
  let accountStore: ProviderAccountStore
  let billing: ProviderBillingStore
  let controller: ProviderAccountsController
  let now: Date

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "ProviderAccountsControllerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw CocoaError(.fileReadUnknown)
    }
    defaults.removePersistentDomain(forName: suite)
    self.defaults = defaults
    settings = SettingsStore(defaults: defaults)
    accountStore = ProviderAccountStore(
      metadataURL: directory.appendingPathComponent("provider-accounts.json"),
      credentialStore: credentials
    )
    billing = ProviderBillingStore(
      credentialStore: credentials,
      openAIService: costService,
      anthropicService: costService
    )
    let fixedNow = ProviderBillingCalendar.utc.date(
      from: DateComponents(year: 2026, month: 7, day: 18, hour: 12, minute: 30)
    )!
    now = fixedNow
    controller = ProviderAccountsController(
      accountStore: accountStore,
      billingStore: billing,
      settings: settings,
      now: { fixedNow }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private actor ControllerCredentialStore: CredentialSecretStore {
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

private actor ControllerCostService: ProviderCostFetching {
  private(set) var receivedCredentials: [UUID: Data] = [:]
  private(set) var receivedIntervals: [UUID: DateInterval] = [:]
  private(set) var callCount = 0
  private(set) var maximumActiveCallCount = 0
  private var activeCallCount = 0
  private var isBlocking = false
  private var blockers: [CheckedContinuation<Void, Never>] = []
  private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func beginBlocking() {
    isBlocking = true
  }

  func waitForCalls(_ count: Int) async {
    guard callCount < count else { return }
    await withCheckedContinuation { callWaiters.append((count, $0)) }
  }

  func unblock() {
    isBlocking = false
    let blockers = blockers
    self.blockers.removeAll()
    for blocker in blockers { blocker.resume() }
  }

  func fetchActualCosts(
    accountID: UUID,
    credential: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot {
    callCount += 1
    activeCallCount += 1
    maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
    receivedCredentials[accountID] = credential
    receivedIntervals[accountID] = interval
    let satisfiedWaiters = callWaiters.filter { callCount >= $0.0 }
    callWaiters.removeAll { callCount >= $0.0 }
    for (_, waiter) in satisfiedWaiters { waiter.resume() }
    if isBlocking {
      await withCheckedContinuation { blockers.append($0) }
    }
    activeCallCount -= 1
    return ActualBilledSnapshot(
      accountID: accountID,
      provider: credential == Data("admin-key".utf8) ? .anthropicAPI : .openAIAPI,
      amount: 1,
      currency: "USD",
      interval: interval,
      fetchedAt: interval.end
    )
  }
}
