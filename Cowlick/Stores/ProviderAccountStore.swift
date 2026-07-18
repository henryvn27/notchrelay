import Darwin
import Foundation

actor ProviderAccountStore {
  static let currentVersion = 1
  static let maximumMetadataSize = 262_144

  private let metadataURL: URL
  private let credentialStore: any CredentialSecretStore
  private var cachedAccounts: [ProviderAccount]?

  init(
    metadataURL: URL = AppSupportPaths.applicationSupportDirectory
      .appendingPathComponent("provider-accounts.json"),
    credentialStore: any CredentialSecretStore = KeychainCredentialSecretStore()
  ) {
    self.metadataURL = metadataURL
    self.credentialStore = credentialStore
  }

  func accounts() throws -> [ProviderAccount] {
    try loadIfNeeded()
  }

  @discardableResult
  func create(
    provider: UsageProvider,
    alias: String,
    credentialReference: CredentialReference = CredentialReference(id: UUID())
  ) throws -> ProviderAccount {
    var accounts = try loadIfNeeded()
    guard !accounts.contains(where: { $0.credentialReference == credentialReference }) else {
      throw ProviderAccountStoreError.duplicateCredentialReference
    }
    let account = ProviderAccount(
      id: UUID(),
      provider: provider,
      alias: try Self.validatedAlias(alias),
      credentialReference: credentialReference
    )
    accounts.append(account)
    try persist(accounts)
    cachedAccounts = accounts
    return account
  }

  func rename(accountID: UUID, alias: String) throws {
    var accounts = try loadIfNeeded()
    guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
      throw ProviderAccountStoreError.accountNotFound
    }
    accounts[index].alias = try Self.validatedAlias(alias)
    try persist(accounts)
    cachedAccounts = accounts
  }

  @discardableResult
  func remove(accountID: UUID) async throws -> ProviderAccount {
    var accounts = try loadIfNeeded()
    guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
      throw ProviderAccountStoreError.accountNotFound
    }
    let account = accounts[index]
    try await credentialStore.deleteSecret(for: account.credentialReference)
    accounts.remove(at: index)
    try persist(accounts)
    cachedAccounts = accounts
    return account
  }

  private struct MetadataFile: Codable {
    let version: Int
    let accounts: [ProviderAccount]
  }

  private func loadIfNeeded() throws -> [ProviderAccount] {
    if let cachedAccounts { return cachedAccounts }
    let accounts = try readMetadata()
    cachedAccounts = accounts
    return accounts
  }

  private func readMetadata() throws -> [ProviderAccount] {
    var info = stat()
    if lstat(metadataURL.path, &info) != 0 {
      if errno == ENOENT { return [] }
      throw ProviderAccountStoreError.unreadableMetadata
    }
    guard (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      (info.st_mode & 0o077) == 0,
      info.st_size >= 0,
      info.st_size <= Self.maximumMetadataSize
    else { throw ProviderAccountStoreError.unreadableMetadata }

    let data: Data
    do {
      data = try Data(contentsOf: metadataURL, options: .mappedIfSafe)
    } catch {
      throw ProviderAccountStoreError.unreadableMetadata
    }
    guard data.count <= Self.maximumMetadataSize else {
      throw ProviderAccountStoreError.unreadableMetadata
    }

    let metadata: MetadataFile
    do {
      metadata = try JSONDecoder().decode(MetadataFile.self, from: data)
    } catch {
      throw ProviderAccountStoreError.unreadableMetadata
    }
    guard metadata.version == Self.currentVersion else {
      throw ProviderAccountStoreError.unsupportedVersion
    }

    var accountIDs = Set<UUID>()
    var credentialIDs = Set<CredentialReference>()
    for account in metadata.accounts {
      guard accountIDs.insert(account.id).inserted,
        credentialIDs.insert(account.credentialReference).inserted,
        (try? Self.validatedAlias(account.alias)) == account.alias
      else { throw ProviderAccountStoreError.unreadableMetadata }
    }
    return metadata.accounts
  }

  private func persist(_ accounts: [ProviderAccount]) throws {
    let directory = metadataURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(MetadataFile(version: Self.currentVersion, accounts: accounts))
      guard data.count <= Self.maximumMetadataSize else {
        throw ProviderAccountStoreError.unreadableMetadata
      }
      let temporaryURL = directory.appendingPathComponent(
        ".provider-accounts.\(UUID().uuidString).tmp")
      do {
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        guard Darwin.rename(temporaryURL.path, metadataURL.path) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
    } catch let error as ProviderAccountStoreError {
      throw error
    } catch {
      throw ProviderAccountStoreError.couldNotPersist
    }
  }

  private static func validatedAlias(_ alias: String) throws -> String {
    let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !alias.isEmpty,
      alias.count <= 64,
      !alias.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw ProviderAccountStoreError.invalidAlias }
    return alias
  }
}

enum ProviderAccountStoreError: LocalizedError, Equatable {
  case invalidAlias
  case accountNotFound
  case duplicateCredentialReference
  case unreadableMetadata
  case unsupportedVersion
  case couldNotPersist

  var errorDescription: String? {
    switch self {
    case .invalidAlias: "Use an account name between 1 and 64 characters."
    case .accountNotFound: "That provider account no longer exists."
    case .duplicateCredentialReference: "That credential is already assigned to an account."
    case .unreadableMetadata: "Cowlick could not safely read provider accounts."
    case .unsupportedVersion: "The provider account file was created by a newer Cowlick version."
    case .couldNotPersist: "Cowlick could not save provider accounts."
    }
  }
}
