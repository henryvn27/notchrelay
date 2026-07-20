import Foundation

struct SubagentActivity: Identifiable, Equatable, Sendable {
  let id: String
  let turnID: String
  let deliverySequence: UInt64
  var updatedAt: Date
}
