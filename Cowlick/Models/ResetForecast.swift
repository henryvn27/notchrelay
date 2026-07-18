import Foundation

struct ResetForecast: Equatable, Sendable {
  static let sourceName = "Will Codex Reset?"
  static let sourceURL = URL(string: "https://www.willcodexquotareset.com")!
  static let endpointURL = URL(string: "https://www.willcodexquotareset.com/api/forecast")!
  static let disclaimer =
    "Third-party data shown as provided. It is not Cowlick data or a Cowlick estimate, and Cowlick does not warrant it."

  let score: Double
  let resetAnnounced: Bool
  let fetchedAt: Date?
  let nextRefreshAt: Date?

  var scoreLabel: String {
    "\(Int(score.rounded()))% in the next 48 hours"
  }
}
