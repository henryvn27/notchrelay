import Foundation

struct ApprovalRequest: Identifiable, Equatable, Sendable {
  let id: UUID
  let sessionID: String
  let turnID: String?
  let projectName: String
  let workingDirectory: String
  let toolName: String
  let operationDescription: String
  let fullOperation: String
  let requestedAt: Date
  let expiresAt: Date

  var isExpired: Bool { expiresAt <= Date() }

  var operationPreview: String {
    let singleLine =
      operationDescription
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
    guard singleLine.count > 180 else { return singleLine }
    return String(singleLine.prefix(177)) + "…"
  }
}
