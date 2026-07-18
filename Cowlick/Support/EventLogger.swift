import Foundation
import OSLog
import Observation

struct SanitizedBridgeRecord: Identifiable, Equatable, Sendable {
  let id: UUID
  let timestamp: Date
  let event: String
  let project: String
  let outcome: String
}

@MainActor
@Observable
final class EventLogger {
  private(set) var recentEvents: [SanitizedBridgeRecord] = []
  private(set) var recentErrors: [String] = []

  private let logger = Logger(subsystem: "com.henryvn27.Cowlick", category: "Bridge")
  private let maximumRecords = 10

  func record(event: BridgeEventName, project: String, outcome: String = "accepted") {
    let record = SanitizedBridgeRecord(
      id: UUID(),
      timestamp: Date(),
      event: event.rawValue,
      project: Self.sanitizeProject(project),
      outcome: outcome
    )
    recentEvents.append(record)
    recentEvents = Array(recentEvents.suffix(maximumRecords))
    logger.info(
      "Bridge event \(event.rawValue, privacy: .public) for \(record.project, privacy: .public): \(outcome, privacy: .public)"
    )
  }

  func error(_ message: String) {
    let sanitized = Self.sanitizeError(message)
    recentErrors.append(sanitized)
    recentErrors = Array(recentErrors.suffix(maximumRecords))
    logger.error("\(sanitized, privacy: .public)")
  }

  func reset() {
    recentEvents.removeAll()
    recentErrors.removeAll()
  }

  static func sanitizeProject(_ value: String) -> String {
    let name = URL(fileURLWithPath: value).lastPathComponent
    let candidate = name.isEmpty ? value : name
    let singleLine =
      candidate
      .components(separatedBy: .controlCharacters)
      .joined(separator: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return String(sanitizeError(singleLine).prefix(80))
  }

  static func sanitizeError(_ value: String) -> String {
    var sanitized = value.replacingOccurrences(
      of: #"/Users/[^/\s]+"#,
      with: "~",
      options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
      of: #"(?i)\bauthorization\s*:\s*bearer\s+[^\s,;]+"#,
      with: "authorization=<redacted>",
      options: .regularExpression
    )
    sanitized = sanitized.replacingOccurrences(
      of:
        #"(?i)\b(token|secret|password|authorization|api[_-]?key|auth[_-]?token)\b[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
      with: "$1=<redacted>",
      options: .regularExpression
    )
    return String(sanitized.prefix(400))
  }
}
