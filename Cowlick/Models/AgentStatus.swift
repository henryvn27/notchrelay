import Foundation

enum AgentStatus: Equatable, Sendable {
  case idle
  case working(prompt: String?)
  case awaitingApproval(ApprovalRequest)
  case completed(message: String?)
  case failed(message: String?)

  var priority: Int {
    switch self {
    case .awaitingApproval: 5
    case .failed: 4
    case .working: 3
    case .completed: 2
    case .idle: 1
    }
  }

  var shortLabel: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .awaitingApproval: "Approval needed"
    case .completed: "Completed"
    case .failed: "Failed"
    }
  }
}

extension AgentStatus {
  var isAwaitingApproval: Bool {
    if case .awaitingApproval = self { return true }
    return false
  }
}
