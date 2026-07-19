import Foundation

enum HookApprovalDecision: String, Codable, Equatable, Sendable {
  case allow
  case deny
  case deferDecision = "defer"
}

struct ApprovalBridgeResponse: Codable, Equatable, Sendable {
  let version: Int
  let requestId: UUID
  let decision: HookApprovalDecision
}

struct HookBridgeAcknowledgement: Codable, Equatable, Sendable {
  let version: Int
  let requestId: UUID
  let accepted: Bool
  let error: String?
}

enum HookOutput {
  static let neutralStop = Data("{}\n".utf8)

  static func permission(
    _ decision: HookApprovalDecision, message: String = "Denied in Cowlick."
  ) throws -> Data? {
    switch decision {
    case .deferDecision:
      return nil
    case .allow:
      return try JSONSerialization.data(
        withJSONObject: [
          "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow"],
          ]
        ], options: [.sortedKeys]) + Data([0x0A])
    case .deny:
      return try JSONSerialization.data(
        withJSONObject: [
          "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": [
              "behavior": "deny",
              "message": message,
            ],
          ]
        ], options: [.sortedKeys]) + Data([0x0A])
    }
  }
}
