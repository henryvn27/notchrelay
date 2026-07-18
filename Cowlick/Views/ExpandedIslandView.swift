import SwiftUI

struct ExpandedIslandView: View {
  let store: SessionStore

  var body: some View {
    if let approval = store.currentApproval {
      ApprovalView(
        request: approval,
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
        openDiagnostics: { WindowCoordinator.shared.openDiagnostics() })
    }
  }
}
