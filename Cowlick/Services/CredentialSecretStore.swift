import Foundation
import Security

protocol CredentialSecretStore: Sendable {
  func store(_ secret: Data, for reference: CredentialReference) async throws
  func secret(for reference: CredentialReference) async throws -> Data?
  func deleteSecret(for reference: CredentialReference) async throws
}

enum CredentialSecretStoreError: LocalizedError, Equatable {
  case invalidSecret
  case keychainFailure(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidSecret:
      "The credential is empty or too large."
    case .keychainFailure:
      "Cowlick could not access this credential in Keychain."
    }
  }
}

struct KeychainCredentialSecretStore: CredentialSecretStore {
  static let maximumSecretSize = 32_768

  private let service: String

  init(service: String = "com.henryvn27.Cowlick.provider-credentials") {
    self.service = service
  }

  func store(_ secret: Data, for reference: CredentialReference) async throws {
    guard !secret.isEmpty, secret.count <= Self.maximumSecretSize else {
      throw CredentialSecretStoreError.invalidSecret
    }

    let query = baseQuery(reference)
    let update: [String: Any] = [kSecValueData as String: secret]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw CredentialSecretStoreError.keychainFailure(updateStatus)
    }

    var item = query
    item[kSecValueData as String] = secret
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw CredentialSecretStoreError.keychainFailure(addStatus)
    }
  }

  func secret(for reference: CredentialReference) async throws -> Data? {
    var query = baseQuery(reference)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw CredentialSecretStoreError.keychainFailure(status)
    }
    return data
  }

  func deleteSecret(for reference: CredentialReference) async throws {
    let status = SecItemDelete(baseQuery(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialSecretStoreError.keychainFailure(status)
    }
  }

  private func baseQuery(_ reference: CredentialReference) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.id.uuidString.lowercased(),
    ]
  }
}
