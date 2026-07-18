import SwiftUI

struct NotchRootView: View {
  let store: SessionStore
  let presentation: NotchPanelPresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      surfaceShape.fill(NotchTheme.island)

      Group {
        if isExpanded {
          ExpandedIslandView(store: store)
            .padding(.top, presentation.isAttached ? presentation.safeAreaTop : 0)
        } else if let session = store.displaySession {
          CollapsedIslandView(
            session: session,
            activeCount: store.activeSessionCount,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            reducedAnimation: store.settings.reducedAnimation
          ) {
            if case .completed = session.status {
              store.dismissCompletion(sessionID: session.id)
            } else {
              store.toggleExpanded()
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .id(contentIdentity)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
    .overlay {
      if !presentation.isAttached {
        surfaceShape.stroke(NotchTheme.hairline, lineWidth: 0.75)
      }
    }
    .contentShape(surfaceShape)
    .clipShape(surfaceShape)
    .animation(contentAnimation, value: contentIdentity)
    .onExitCommand { store.collapse() }
    .preferredColorScheme(.dark)
  }

  private var isExpanded: Bool {
    store.currentApproval != nil || store.isExpanded
  }

  private var surfaceShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      cornerRadii: RectangleCornerRadii(
        topLeading: presentation.isAttached ? 0 : 16,
        bottomLeading: presentation.isAttached ? 13 : 16,
        bottomTrailing: presentation.isAttached ? 13 : 16,
        topTrailing: presentation.isAttached ? 0 : 16
      ),
      style: .continuous
    )
  }

  private var contentIdentity: String {
    if let approval = store.currentApproval { return "approval-\(approval.id)" }
    if store.isExpanded { return "sessions" }
    guard let session = store.displaySession else { return "idle" }
    return "compact-\(session.id)-\(session.status.shortLabel)"
  }

  private var contentAnimation: Animation? {
    reduceMotion || store.settings.reducedAnimation
      ? nil : .spring(response: 0.32, dampingFraction: 0.88)
  }
}
