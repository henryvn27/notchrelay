import Darwin
import Foundation
import XCTest

@testable import Cowlick

final class ProviderAccountStoreTests: XCTestCase {
  func testPersistsMultipleAccountsForSameProviderWithoutSecretsOrPrivateFields() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let store = ProviderAccountStore(metadataURL: fixture.url)
    let firstReference = CredentialReference(id: UUID())
    let secondReference = CredentialReference(id: UUID())

    let first = try await store.create(
      provider: .openAIAPI, alias: "Work", credentialReference: firstReference)
    let second = try await store.create(
      provider: .openAIAPI, alias: "Personal", credentialReference: secondReference)

    XCTAssertNotEqual(first.id, second.id)
    let reloaded = try await ProviderAccountStore(metadataURL: fixture.url).accounts()
    XCTAssertEqual(Set(reloaded), Set([first, second]))
    let persisted = try String(contentsOf: fixture.url, encoding: .utf8)
    XCTAssertFalse(persisted.contains("secret"))
    XCTAssertFalse(persisted.contains("email"))
    XCTAssertFalse(persisted.contains("path"))
  }

  func testTransactionalCreateStoresCredentialOutsideMetadata() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)

    let account = try await store.create(
      provider: .openAIAPI,
      alias: "Work",
      credential: Data("admin-key".utf8)
    )

    let accounts = try await store.accounts()
    let credential = try await credentials.secret(for: account.credentialReference)
    XCTAssertEqual(accounts, [account])
    XCTAssertEqual(credential, Data("admin-key".utf8))
    let persisted = try String(contentsOf: fixture.url, encoding: .utf8)
    XCTAssertFalse(persisted.contains("admin-key"))
  }

  func testCredentialFailureDoesNotPublishAccountMetadata() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore(storeFailuresRemaining: 1)
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)

    do {
      _ = try await store.create(
        provider: .anthropicAPI,
        alias: "Work",
        credential: Data("admin-key".utf8)
      )
      XCTFail("Expected credential persistence failure")
    } catch let error as CredentialSecretStoreError {
      XCTAssertEqual(error, .keychainFailure(errSecInteractionNotAllowed))
    }

    let accounts = try await store.accounts()
    XCTAssertTrue(accounts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
  }

  func testMetadataFailureCleansUpPersistedCredential() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(
      metadataURL: fixture.directory,
      credentialStore: credentials
    )

    do {
      _ = try await store.create(
        provider: .openAIAPI,
        alias: "Work",
        credential: Data("admin-key".utf8)
      )
      XCTFail("Expected metadata persistence failure")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .unreadableMetadata)
    }

    let storedReferences = await credentials.storedReferences
    let deletedReferences = await credentials.deletedReferences
    XCTAssertEqual(storedReferences.count, 1)
    XCTAssertEqual(deletedReferences, storedReferences)
    let credential = try await credentials.secret(for: try XCTUnwrap(storedReferences.first))
    XCTAssertNil(credential)
  }

  func testRejectsUnsupportedBillingProviderBeforeStoringCredential() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)

    do {
      _ = try await store.create(
        provider: .codex,
        alias: "Local Codex",
        credential: Data("unused".utf8)
      )
      XCTFail("Expected unsupported provider rejection")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .unsupportedProvider)
    }

    let storedReferences = await credentials.storedReferences
    XCTAssertTrue(storedReferences.isEmpty)
    let accounts = try await store.accounts()
    XCTAssertTrue(accounts.isEmpty)
  }

  func testReplaceCredentialKeepsAccountIdentityAndReference() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let account = try await store.create(
      provider: .openAIAPI, alias: "Work", credential: Data("old-key".utf8))

    try await store.replaceCredential(accountID: account.id, credential: Data("new-key".utf8))

    let accounts = try await store.accounts()
    let credential = try await credentials.secret(for: account.credentialReference)
    XCTAssertEqual(accounts, [account])
    XCTAssertEqual(credential, Data("new-key".utf8))
  }

  func testRenameAndRemoveAffectOnlyMatchingAccount() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let first = try await store.create(provider: .anthropicAPI, alias: "Company")
    let second = try await store.create(provider: .anthropicAPI, alias: "Lab")

    try await store.rename(accountID: first.id, alias: "Main")
    let removed = try await store.remove(accountID: second.id)
    let accounts = try await store.accounts()

    XCTAssertEqual(removed, second)
    XCTAssertEqual(accounts.count, 1)
    XCTAssertEqual(accounts.first?.id, first.id)
    XCTAssertEqual(accounts.first?.alias, "Main")
    let deletedReferences = await credentials.deletedReferences
    XCTAssertEqual(deletedReferences, [second.credentialReference])
  }

  func testFailedCredentialDeletionRetainsAccountReferenceForRetry() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore(failuresRemaining: 1)
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let account = try await store.create(provider: .openAIAPI, alias: "Work")

    do {
      _ = try await store.remove(accountID: account.id)
      XCTFail("Expected credential deletion failure")
    } catch let error as CredentialSecretStoreError {
      XCTAssertEqual(error, .keychainFailure(errSecInteractionNotAllowed))
    }

    let cachedAccounts = try await store.accounts()
    let reloadedAccounts = try await ProviderAccountStore(
      metadataURL: fixture.url, credentialStore: credentials
    ).accounts()
    XCTAssertEqual(cachedAccounts, [account])
    XCTAssertEqual(reloadedAccounts, [account])

    let removed = try await store.remove(accountID: account.id)
    let finalAccounts = try await store.accounts()
    let deletedReferences = await credentials.deletedReferences
    XCTAssertEqual(removed, account)
    XCTAssertTrue(finalAccounts.isEmpty)
    XCTAssertEqual(deletedReferences, [account.credentialReference, account.credentialReference])
  }

  func testConcurrentReadDoesNotPublishRemovalWhenCredentialDeletionFails() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore(
      failuresRemaining: 1,
      blockDeletion: true
    )
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let account = try await store.create(provider: .openAIAPI, alias: "Work")

    let removal = Task { try await store.remove(accountID: account.id) }
    await credentials.waitForDeleteCall()

    let accountsDuringDeletion = try await store.accounts()
    XCTAssertEqual(accountsDuringDeletion, [account])

    await credentials.resumeDeletion()
    do {
      _ = try await removal.value
      XCTFail("Expected credential deletion failure")
    } catch let error as CredentialSecretStoreError {
      XCTAssertEqual(error, .keychainFailure(errSecInteractionNotAllowed))
    }
    let accountsAfterRollback = try await store.accounts()
    XCTAssertEqual(accountsAfterRollback, [account])
  }

  func testPurgeDeletesAndVerifiesEveryReferencedCredentialWithoutRemovingMetadata() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore()
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let first = try await store.create(
      provider: .openAIAPI, alias: "Work", credential: Data("first-key".utf8))
    let second = try await store.create(
      provider: .anthropicAPI, alias: "Lab", credential: Data("second-key".utf8))

    let count = try await store.purgeReferencedCredentials()
    let firstCredential = try await credentials.secret(for: first.credentialReference)
    let secondCredential = try await credentials.secret(for: second.credentialReference)
    let accounts = try await store.accounts()

    XCTAssertEqual(count, 2)
    XCTAssertNil(firstCredential)
    XCTAssertNil(secondCredential)
    XCTAssertEqual(accounts, [first, second])
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
  }

  func testPurgeFailureLeavesMetadataForRetryWhenDeletionCannotBeVerified() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let credentials = RecordingCredentialSecretStore(ignoreDeletions: true)
    let store = ProviderAccountStore(metadataURL: fixture.url, credentialStore: credentials)
    let account = try await store.create(
      provider: .openAIAPI, alias: "Work", credential: Data("admin-key".utf8))

    do {
      _ = try await store.purgeReferencedCredentials()
      XCTFail("Expected purge verification failure")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .credentialCleanupCouldNotBeVerified)
    }
    let accounts = try await store.accounts()
    let credential = try await credentials.secret(for: account.credentialReference)

    XCTAssertEqual(accounts, [account])
    XCTAssertNotNil(credential)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
  }

  func testMetadataUsesOwnerOnlyPermissionsAndRejectsInsecureFile() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let store = ProviderAccountStore(metadataURL: fixture.url)
    _ = try await store.create(provider: .openAIAPI, alias: "Primary")

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)

    do {
      _ = try await ProviderAccountStore(metadataURL: fixture.url).accounts()
      XCTFail("Expected insecure metadata to be rejected")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .unreadableMetadata)
    }
  }

  func testRejectsBlankAndControlCharacterAliases() async throws {
    let fixture = try TemporaryAccountMetadata()
    defer { fixture.remove() }
    let store = ProviderAccountStore(metadataURL: fixture.url)

    do {
      _ = try await store.create(provider: .openAIAPI, alias: "  ")
      XCTFail("Expected blank alias rejection")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .invalidAlias)
    }
    do {
      _ = try await store.create(provider: .openAIAPI, alias: "Work\u{0007}")
      XCTFail("Expected control character rejection")
    } catch let error as ProviderAccountStoreError {
      XCTAssertEqual(error, .invalidAlias)
    }
  }
}

private actor RecordingCredentialSecretStore: CredentialSecretStore {
  private(set) var deletedReferences: [CredentialReference] = []
  private(set) var storedReferences: [CredentialReference] = []
  private var secrets: [CredentialReference: Data] = [:]
  private var failuresRemaining: Int
  private var storeFailuresRemaining: Int
  private let blockDeletion: Bool
  private let ignoreDeletions: Bool
  private var deletionBlocker: CheckedContinuation<Void, Never>?
  private var deleteCallWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    failuresRemaining: Int = 0,
    storeFailuresRemaining: Int = 0,
    blockDeletion: Bool = false,
    ignoreDeletions: Bool = false
  ) {
    self.failuresRemaining = failuresRemaining
    self.storeFailuresRemaining = storeFailuresRemaining
    self.blockDeletion = blockDeletion
    self.ignoreDeletions = ignoreDeletions
  }

  func waitForDeleteCall() async {
    guard deletedReferences.isEmpty else { return }
    await withCheckedContinuation { deleteCallWaiters.append($0) }
  }

  func resumeDeletion() {
    deletionBlocker?.resume()
    deletionBlocker = nil
  }

  func store(_ secret: Data, for reference: CredentialReference) async throws {
    storedReferences.append(reference)
    if storeFailuresRemaining > 0 {
      storeFailuresRemaining -= 1
      throw CredentialSecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    secrets[reference] = secret
  }

  func secret(for reference: CredentialReference) async throws -> Data? { secrets[reference] }

  func deleteSecret(for reference: CredentialReference) async throws {
    deletedReferences.append(reference)
    let waiters = deleteCallWaiters
    deleteCallWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if blockDeletion {
      await withCheckedContinuation { deletionBlocker = $0 }
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw CredentialSecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    guard !ignoreDeletions else { return }
    secrets.removeValue(forKey: reference)
  }
}

private struct TemporaryAccountMetadata {
  let directory: URL
  let url: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    url = directory.appendingPathComponent("provider-accounts.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
