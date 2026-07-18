import Foundation

@MainActor
final class ApprovalCoordinator {
  private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
  private var expirationTasks: [UUID: Task<Void, Never>] = [:]

  func waitForDecision(for request: ApprovalRequest) async -> ApprovalDecision {
    guard !request.isExpired else { return .deferDecision }

    return await withCheckedContinuation { continuation in
      continuations[request.id] = continuation
      let delay = max(0, request.expiresAt.timeIntervalSinceNow)
      expirationTasks[request.id] = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        self?.resolve(requestID: request.id, decision: .deferDecision)
      }
    }
  }

  @discardableResult
  func resolve(requestID: UUID, decision: ApprovalDecision) -> Bool {
    guard let continuation = continuations.removeValue(forKey: requestID) else { return false }
    expirationTasks.removeValue(forKey: requestID)?.cancel()
    continuation.resume(returning: decision)
    return true
  }

  func deferAll() {
    for requestID in Array(continuations.keys) {
      resolve(requestID: requestID, decision: .deferDecision)
    }
  }
}
