import Foundation
import Observation

@MainActor
@Observable
final class ProviderAccountsController {
  private(set) var accounts: [ProviderAccount] = []
  private(set) var selectedAccountID: UUID?
  private(set) var errorMessage: String?

  private let accountStore: ProviderAccountStore
  private let billingStore: ProviderBillingStore
  private let settings: SettingsStore
  private let now: () -> Date
  private var refreshGeneration = 0
  private var refreshAllTask: Task<Void, Never>?

  var selectedAccount: ProviderAccount? {
    guard let selectedAccountID else { return nil }
    return accounts.first { $0.id == selectedAccountID }
  }

  init(
    accountStore: ProviderAccountStore,
    billingStore: ProviderBillingStore,
    settings: SettingsStore,
    now: @escaping () -> Date = Date.init
  ) {
    self.accountStore = accountStore
    self.billingStore = billingStore
    self.settings = settings
    self.now = now
    selectedAccountID = settings.selectedProviderAccountID
  }

  func load() async {
    do {
      accounts = try await accountStore.accounts()
      reconcileSelection()
      errorMessage = nil
    } catch {
      errorMessage = EventLogger.sanitizeError(error.localizedDescription)
    }
  }

  func resetTransientState() async {
    invalidateRefreshes()
    billingStore.reset()
    selectedAccountID = settings.selectedProviderAccountID
    await load()
  }

  @discardableResult
  func addAccount(provider: UsageProvider, alias: String, credential: Data) async throws
    -> ProviderAccount
  {
    do {
      let account = try await accountStore.create(
        provider: provider, alias: alias, credential: credential)
      accounts = try await accountStore.accounts()
      setSelection(account.id)
      errorMessage = nil
      return account
    } catch {
      record(error)
      throw error
    }
  }

  func renameAccount(id: UUID, alias: String) async throws {
    do {
      try await accountStore.rename(accountID: id, alias: alias)
      accounts = try await accountStore.accounts()
      reconcileSelection()
      errorMessage = nil
    } catch {
      record(error)
      throw error
    }
  }

  func replaceCredential(for id: UUID, credential: Data) async throws {
    do {
      try await accountStore.replaceCredential(accountID: id, credential: credential)
      billingStore.remove(accountID: id)
      errorMessage = nil
    } catch {
      record(error)
      throw error
    }
  }

  func removeAccount(id: UUID) async throws {
    do {
      _ = try await accountStore.remove(accountID: id)
      billingStore.remove(accountID: id)
      accounts = try await accountStore.accounts()
      reconcileSelection()
      errorMessage = nil
    } catch {
      if let reloadedAccounts = try? await accountStore.accounts() {
        accounts = reloadedAccounts
        reconcileSelection()
      }
      record(error)
      throw error
    }
  }

  @discardableResult
  func selectAccount(id: UUID) -> Bool {
    guard accounts.contains(where: { $0.id == id }) else { return false }
    setSelection(id)
    return true
  }

  func refreshSelected() async {
    guard let selectedAccount else { return }
    await billingStore.refresh(
      account: selectedAccount,
      interval: Self.monthToDateInterval(endingAt: now())
    )
  }

  func refreshAll() async {
    invalidateRefreshes()
    let generation = refreshGeneration
    let interval = Self.monthToDateInterval(endingAt: now())
    let accounts = accounts
    let task = Task { await runRefreshAll(accounts, interval: interval, generation: generation) }
    refreshAllTask = task
    await task.value
    if refreshGeneration == generation {
      refreshAllTask = nil
    }
  }

  static func monthToDateInterval(
    endingAt date: Date,
    calendar _: Calendar = ProviderBillingCalendar.utc
  ) -> DateInterval {
    let start = ProviderBillingCalendar.utc.dateInterval(of: .month, for: date)?.start ?? date
    return DateInterval(start: start, end: max(date, start.addingTimeInterval(1)))
  }

  private func runRefreshAll(
    _ accounts: [ProviderAccount],
    interval: DateInterval,
    generation: Int
  ) async {
    let concurrencyLimit = 4
    await withTaskGroup(of: Void.self) { group in
      var remainingAccounts = accounts.makeIterator()
      for _ in 0..<min(concurrencyLimit, accounts.count) {
        guard let account = remainingAccounts.next() else { break }
        group.addTask {
          guard await self.shouldContinueRefresh(generation) else { return }
          await self.billingStore.refresh(account: account, interval: interval)
        }
      }
      while await group.next() != nil {
        guard shouldContinueRefresh(generation) else {
          group.cancelAll()
          return
        }
        guard let account = remainingAccounts.next() else { continue }
        group.addTask {
          guard await self.shouldContinueRefresh(generation) else { return }
          await self.billingStore.refresh(account: account, interval: interval)
        }
      }
    }
  }

  private func invalidateRefreshes() {
    refreshGeneration &+= 1
    refreshAllTask?.cancel()
    refreshAllTask = nil
  }

  private func shouldContinueRefresh(_ generation: Int) -> Bool {
    !Task.isCancelled && refreshGeneration == generation
  }

  private func reconcileSelection() {
    let selection =
      selectedAccountID.flatMap { selectedID in
        accounts.first(where: { $0.id == selectedID })?.id
      } ?? accounts.first?.id
    setSelection(selection)
  }

  private func setSelection(_ id: UUID?) {
    selectedAccountID = id
    settings.selectedProviderAccountID = id
  }

  private func record(_ error: Error) {
    errorMessage = EventLogger.sanitizeError(error.localizedDescription)
  }
}
