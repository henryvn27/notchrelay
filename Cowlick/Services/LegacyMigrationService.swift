import Foundation

enum LegacyMigrationService {
  static let preferencesMigrationKey = "migration.notchRelayToCowlick.v1"

  @MainActor
  static func migratePreferencesIfNeeded(
    destination: UserDefaults = .standard,
    destinationDomain: String = ProductIdentity.bundleIdentifier,
    sourceDomain: String = ProductIdentity.legacyBundleIdentifier,
    sourceValues: [String: Any]? = nil
  ) {
    guard !destination.bool(forKey: preferencesMigrationKey) else { return }

    let persistedDestination = destination.persistentDomain(forName: destinationDomain) ?? [:]
    if let legacyValues = sourceValues ?? destination.persistentDomain(forName: sourceDomain) {
      for key in SettingsStore.allKeys where persistedDestination[key] == nil {
        if let value = legacyValues[key] {
          destination.set(value, forKey: key)
        }
      }
    }

    destination.set(true, forKey: preferencesMigrationKey)
  }
}
