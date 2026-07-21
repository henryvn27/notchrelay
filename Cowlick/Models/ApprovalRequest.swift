import Foundation

struct ApprovalRequest: Identifiable, Equatable, Sendable {
  let id: UUID
  let sessionID: String
  let turnID: String?
  let projectName: String
  let workingDirectory: String
  let toolName: String
  let operationDescription: String
  let operationSummary: String
  let fullOperation: String
  let requestedAt: Date
  let expiresAt: Date

  var isExpired: Bool { expiresAt <= Date() }

  var reasonPreview: String {
    Self.preview(operationDescription, limit: 180)
  }

  var operationPreview: String {
    Self.preview(operationSummary, limit: 180)
  }

  var showsDistinctOperation: Bool {
    !operationPreview.isEmpty && operationPreview != reasonPreview
  }

  private static func preview(_ value: String, limit: Int) -> String {
    let singleLine = EventLogger.sanitizeError(value)
    guard singleLine.count > limit else { return singleLine }
    return String(singleLine.prefix(limit - 1)) + "…"
  }
}
