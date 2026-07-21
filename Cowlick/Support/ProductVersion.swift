import Foundation

enum ProductVersion {
  static let marketing =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
  static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  static let bridgeProtocol = 2
  static let sourceCommit: String = {
    guard let url = Bundle.main.url(forResource: "cowlick-source-commit", withExtension: "txt"),
      let value = try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    else { return "unknown" }
    return value
  }()
}
