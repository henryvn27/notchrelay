import SwiftUI

struct ExpandedIslandView: View {
  let store: SessionStore
  let presentation: NotchPanelPresentation
  let namespace: Namespace.ID

  var body: some View {
    VStack(spacing: 0) {
      if presentation.isAttached, let session = store.displaySession ?? store.sessionSummaries.first
      {
        IslandHeaderView(
          session: session,
          activeCount: store.activeSessionCount,
          activeSubagentCount: store.activeSubagentCount,
          notchGapWidth: presentation.notchGapWidth,
          isAttached: true,
          reducedAnimation: store.settings.reducedAnimation,
          namespace: namespace
        )
        .frame(height: presentation.safeAreaTop)
      }

      if let approval = store.currentApproval {
        ApprovalView(
          request: approval,
          isAttached: presentation.isAttached,
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
          isAttached: presentation.isAttached,
          openDiagnostics: { WindowCoordinator.shared.openDiagnostics() })
      }
    }
  }
}
