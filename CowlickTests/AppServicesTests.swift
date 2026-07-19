import Foundation
import XCTest

@testable import Cowlick

@MainActor
final class AppServicesTests: XCTestCase {
  func testUITestingProviderServicesAreIsolatedFromProductionStateAndNetwork() async throws {
    let fixture = try TemporaryProviderServicesDirectory()
    defer { fixture.remove() }
    let productionCredentialStore = InMemoryCredentialSecretStore()
    let productionStore = ProviderAccountStore(
      metadataURL: fixture.productionMetadataURL,
      credentialStore: productionCredentialStore
    )
    let productionAccount = try await productionStore.create(
      provider: .openAIAPI,
      alias: "Production",
      credential: Data("production-secret".utf8)
    )

    let services = AppServices.makeProviderAccountServices(
      arguments: ["--ui-testing"],
      applicationSupportDirectory: fixture.productionDirectory,
      uiTestingMetadataURL: fixture.uiTestingMetadataURL
    )

    XCTAssertTrue(services.credentialStore is InMemoryCredentialSecretStore)
    let initialUITestingAccounts = try await services.accountStore.accounts()
    XCTAssertTrue(initialUITestingAccounts.isEmpty)

    let uiTestingAccount = try await services.accountStore.create(
      provider: .openAIAPI,
      alias: "UI Test",
      credential: Data("ui-testing-secret".utf8)
    )
    let productionAccounts = try await ProviderAccountStore(
      metadataURL: fixture.productionMetadataURL,
      credentialStore: productionCredentialStore
    ).accounts()
    let uiTestingSecret = try await services.credentialStore.secret(
      for: uiTestingAccount.credentialReference)

    XCTAssertEqual(productionAccounts, [productionAccount])
    XCTAssertEqual(uiTestingSecret, Data("ui-testing-secret".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.uiTestingMetadataURL.path))

    await services.billingStore.refresh(
      account: uiTestingAccount,
      interval: DateInterval(start: .distantPast, duration: 86_400)
    )

    XCTAssertEqual(
      services.billingStore.errors[uiTestingAccount.id],
      "Provider billing network access is disabled during UI testing."
    )
  }

  func testProductionProviderServicesUseApplicationSupportMetadataAndKeychain() async throws {
    let fixture = try TemporaryProviderServicesDirectory()
    defer { fixture.remove() }
    let productionAccount = try await ProviderAccountStore(
      metadataURL: fixture.productionMetadataURL,
      credentialStore: InMemoryCredentialSecretStore()
    ).create(provider: .anthropicAPI, alias: "Production")

    let services = AppServices.makeProviderAccountServices(
      arguments: [],
      applicationSupportDirectory: fixture.productionDirectory
    )
    let accounts = try await services.accountStore.accounts()

    XCTAssertTrue(services.credentialStore is KeychainCredentialSecretStore)
    XCTAssertEqual(accounts, [productionAccount])
  }
}

private struct TemporaryProviderServicesDirectory {
  let root: URL
  let productionDirectory: URL
  let productionMetadataURL: URL
  let uiTestingMetadataURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    productionDirectory = root.appendingPathComponent("Production", isDirectory: true)
    productionMetadataURL = productionDirectory.appendingPathComponent("provider-accounts.json")
    uiTestingMetadataURL =
      root
      .appendingPathComponent("UITesting", isDirectory: true)
      .appendingPathComponent("provider-accounts.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
