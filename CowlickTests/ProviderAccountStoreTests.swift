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
  private var failuresRemaining: Int

  init(failuresRemaining: Int = 0) {
    self.failuresRemaining = failuresRemaining
  }

  func store(_: Data, for _: CredentialReference) async throws {}

  func secret(for _: CredentialReference) async throws -> Data? { nil }

  func deleteSecret(for reference: CredentialReference) async throws {
    deletedReferences.append(reference)
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw CredentialSecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
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
