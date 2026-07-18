import Foundation

enum ApprovalDecision: String, Codable, Sendable, Equatable {
  case allow
  case deny
  case deferDecision = "defer"
}

struct ApprovalResponse: Codable, Sendable, Equatable {
  let version: Int
  let requestId: UUID
  let decision: ApprovalDecision

  init(version: Int = BridgeEvent.currentVersion, requestId: UUID, decision: ApprovalDecision) {
    self.version = version
    self.requestId = requestId
    self.decision = decision
  }
}

struct BridgeAcknowledgement: Codable, Sendable, Equatable {
  let version: Int
  let requestId: UUID
  let accepted: Bool
  let error: String?
}
