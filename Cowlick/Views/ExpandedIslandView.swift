import SwiftUI

struct ExpandedIslandView: View {
  let store: SessionStore
  let isAttached: Bool

  var body: some View {
    if let approval = store.currentApproval {
      ApprovalView(
        request: approval,
        isAttached: isAttached,
        allow: { _ = store.decide(requestID: approval.id, decision: .allow) },
        deny: { _ = store.decide(requestID: approval.id, decision: .deny) },
        openCodex: {
          CodexActivationService.openCodex(fallbackDirectory: approval.workingDirectory)
        }
      )
    } else {
      SessionListView(
        sessions: store.sessionSummaries,
        showPromptPreviews: store.settings.showPromptPreviews,
        showResultPreviews: store.settings.showResultPreviews,
        isAttached: isAttached,
        openDiagnostics: { WindowCoordinator.shared.openDiagnostics() })
    }
  }
}
