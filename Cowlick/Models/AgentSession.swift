import Foundation

struct AgentSession: Identifiable, Equatable, Sendable {
  let id: String
  var turnID: String?
  var projectName: String
  var workingDirectory: String
  var model: String?
  var status: AgentStatus
  var updatedAt: Date
  var completionVisibleUntil: Date?
  var isRecovered = false

  var isActive: Bool {
    guard !isRecovered else { return false }
    return switch status {
    case .working, .awaitingApproval: true
    case .idle, .failed, .completed: false
    }
  }

  var statusLabel: String {
    isRecovered ? "Unconfirmed after restart" : status.shortLabel
  }
}
