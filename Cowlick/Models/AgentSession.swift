import Foundation

struct AgentSession: Identifiable, Equatable, Sendable {
  let id: String
  var turnID: String?
  var chatTitle: String?
  var projectName: String
  var workingDirectory: String
  var model: String?
  var subagents: [String: SubagentActivity] = [:]
  var status: AgentStatus
  var updatedAt: Date
  var completionVisibleUntil: Date?
  var isRecovered = false

  var isActive: Bool {
    guard !isRecovered else { return false }
    return switch presentationStatus {
    case .working, .awaitingApproval: true
    case .idle, .failed, .completed: false
    }
  }

  var displayName: String {
    chatTitle ?? projectName
  }

  var projectContext: String? {
    chatTitle == nil ? nil : projectName
  }

  var presentationStatus: AgentStatus {
    switch status {
    case .awaitingApproval, .failed, .working:
      status
    case .idle, .completed:
      subagents.isEmpty ? status : .working(prompt: nil)
    }
  }

  var statusLabel: String {
    let label = isRecovered ? "Unconfirmed after restart" : presentationStatus.shortLabel
    guard !subagents.isEmpty else { return label }
    return "\(label) · \(subagents.count) \(subagents.count == 1 ? "agent" : "agents")"
  }
}
