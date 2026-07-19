import Darwin
import Foundation

@main
struct ProviderCredentialPurgeCommand {
  static func main() async {
    guard CommandLine.arguments.count == 2 else {
      fputs("usage: purge_provider_credentials <provider-accounts.json>\n", stderr)
      exit(2)
    }

    let metadataURL = URL(fileURLWithPath: CommandLine.arguments[1])
    do {
      let store = ProviderAccountStore(
        metadataURL: metadataURL,
        credentialStore: KeychainCredentialSecretStore()
      )
      let count = try await store.purgeReferencedCredentials()
      print("Verified removal of \(count) provider credential(s) from Keychain.")
    } catch {
      fputs("Provider credential cleanup failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
