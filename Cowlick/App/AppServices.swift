import Foundation
import Observation

@MainActor
@Observable
final class AppServices {
  static let shared = AppServices()

  let settings: SettingsStore
  let presentationCoordinator: PresentationCoordinator
  let eventLogger: EventLogger
  let approvalCoordinator: ApprovalCoordinator
  let capsLockService: NativeCapsLockSignalService
  let sessionStore: SessionStore
  let usageStore: UsageStore
  let credentialStore: any CredentialSecretStore
  let providerAccountStore: ProviderAccountStore
  let providerBillingStore: ProviderBillingStore
  let providerAccountsController: ProviderAccountsController
  let hookInstaller: HookInstaller
  let hookTrustService: CodexHookTrustService
  let updateService: UpdateService
  let localLifecycleObserver: CodexSessionObserver

  private init() {
    if CommandLine.arguments.contains("--ui-testing") {
      settings = Self.makeUITestingSettingsStore()
    } else {
      LegacyMigrationService.migratePreferencesIfNeeded()
      settings = SettingsStore()
    }
    presentationCoordinator = PresentationCoordinator(settings: settings)
    eventLogger = EventLogger()
    approvalCoordinator = ApprovalCoordinator()
    capsLockService = NativeCapsLockSignalService()
    let pinnedThreadResolver: @Sendable () -> Set<String>?
    if CommandLine.arguments.contains("--ui-testing") {
      pinnedThreadResolver = { Set(["demo-primary"]) }
    } else {
      pinnedThreadResolver = { CodexPinnedThreadReader().threadIDs() }
    }
    let store = SessionStore(
      settings: settings,
      eventLogger: eventLogger,
      approvalCoordinator: approvalCoordinator,
      capsLockService: capsLockService,
      resolvePinnedThreadIDs: pinnedThreadResolver
    )
    sessionStore = store
    let resolvedUsageStore: UsageStore
    if CommandLine.arguments.contains("--usage-demo") {
      resolvedUsageStore = UsageStore(
        settings: settings,
        usageService: UITestingCodexUsageService(),
        apiCostService: UITestingLocalCodexCostService(),
        forecastService: UITestingResetForecastService()
      )
    } else {
      let apiCostService = LocalCodexCostService(
        roots: CommandLine.arguments.contains("--ui-testing") ? [] : nil)
      resolvedUsageStore = UsageStore(settings: settings, apiCostService: apiCostService)
    }
    usageStore = resolvedUsageStore
    localLifecycleObserver = CodexSessionObserver(
      pinnedThreadsDidChange: {
        Task { @MainActor in await store.refreshPinnedThreadIDs() }
      },
      handler: { event in
        Task { @MainActor in
          if event.kind == .stale, event.parentSessionID == nil {
            store.expireLocalObservation(sessionID: event.sessionID, turnID: event.turnID)
          } else if let bridgeEvent = event.bridgeEvent {
            _ = await store.receive(bridgeEvent)
          }
          if event.shouldRefreshUsage {
            resolvedUsageStore.refreshAfterActivity()
          }
        }
      })
    let providerServices = Self.makeProviderAccountServices(arguments: CommandLine.arguments)
    credentialStore = providerServices.credentialStore
    providerAccountStore = providerServices.accountStore
    providerBillingStore = providerServices.billingStore
    providerAccountsController = ProviderAccountsController(
      accountStore: providerServices.accountStore,
      billingStore: providerServices.billingStore,
      settings: settings
    )
    hookInstaller = HookInstaller()
    hookTrustService = CodexHookTrustService()
    updateService = UpdateService()
    updateService.configure(
      automaticChecks: settings.automaticUpdateChecks,
      automaticDownloads: settings.automaticUpdateDownloads
    )
    Task { await store.refreshPinnedThreadIDs() }
  }

  static func makeUITestingSettingsStore(
    suiteName: String = "com.henryvn27.Cowlick.UITesting"
  ) -> SettingsStore {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Could not create isolated Cowlick UI-testing defaults")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return SettingsStore(defaults: defaults)
  }

  static func makeProviderAccountServices(
    arguments: [String],
    applicationSupportDirectory: URL = AppSupportPaths.applicationSupportDirectory,
    uiTestingMetadataURL: URL? = nil
  ) -> (
    credentialStore: any CredentialSecretStore,
    accountStore: ProviderAccountStore,
    billingStore: ProviderBillingStore
  ) {
    if arguments.contains("--ui-testing") {
      let credentialStore = InMemoryCredentialSecretStore()
      let billingService = NoNetworkProviderCostService()
      let metadataURL =
        uiTestingMetadataURL
        ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("CowlickUITesting-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("provider-accounts.json")
      return (
        credentialStore,
        ProviderAccountStore(metadataURL: metadataURL, credentialStore: credentialStore),
        ProviderBillingStore(
          credentialStore: credentialStore,
          openAIService: billingService,
          anthropicService: billingService
        )
      )
    }

    let credentialStore = KeychainCredentialSecretStore()
    return (
      credentialStore,
      ProviderAccountStore(
        metadataURL: applicationSupportDirectory.appendingPathComponent("provider-accounts.json"),
        credentialStore: credentialStore
      ),
      ProviderBillingStore(credentialStore: credentialStore)
    )
  }
}
