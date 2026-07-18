import Foundation
import Observation

@MainActor
@Observable
final class AppServices {
  static let shared = AppServices()

  let settings: SettingsStore
  let eventLogger: EventLogger
  let approvalCoordinator: ApprovalCoordinator
  let capsLockService: NativeCapsLockSignalService
  let sessionStore: SessionStore
  let usageStore: UsageStore
  let credentialStore: any CredentialSecretStore
  let providerAccountStore: ProviderAccountStore
  let providerBillingStore: ProviderBillingStore
  let hookInstaller: HookInstaller
  let hookTrustService: CodexHookTrustService
  let updateService: UpdateService

  private init() {
    LegacyMigrationService.migratePreferencesIfNeeded()
    settings = SettingsStore()
    eventLogger = EventLogger()
    approvalCoordinator = ApprovalCoordinator()
    capsLockService = NativeCapsLockSignalService()
    sessionStore = SessionStore(
      settings: settings,
      eventLogger: eventLogger,
      approvalCoordinator: approvalCoordinator,
      capsLockService: capsLockService
    )
    usageStore = UsageStore(settings: settings)
    let credentialStore = KeychainCredentialSecretStore()
    self.credentialStore = credentialStore
    providerAccountStore = ProviderAccountStore()
    providerBillingStore = ProviderBillingStore(credentialStore: credentialStore)
    hookInstaller = HookInstaller()
    hookTrustService = CodexHookTrustService()
    updateService = UpdateService()
    updateService.configure(
      automaticChecks: settings.automaticUpdateChecks,
      automaticDownloads: settings.automaticUpdateDownloads
    )
  }
}
