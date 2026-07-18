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

  var isActive: Bool {
    switch status {
    case .working, .awaitingApproval: true
    case .idle, .failed, .completed: false
    }
  }
}
