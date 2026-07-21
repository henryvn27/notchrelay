import SwiftUI

struct NotchRootView: View {
  let store: SessionStore
  let presentation: NotchPanelPresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var islandMorph
  @State private var hoverIntent: Task<Void, Never>?
  @State private var pullDownTriggered = false

  var body: some View {
    ZStack(alignment: .top) {
      if presentation.isAttached {
        surfaceShape.fill(NotchTheme.island)
      } else {
        surfaceShape.fill(.regularMaterial)
      }

      Group {
        if isExpanded {
          ExpandedIslandView(
            store: store,
            presentation: presentation,
            namespace: islandMorph
          )
        } else if let session = store.displaySession {
          CollapsedIslandView(
            session: session,
            activeCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            isAttached: presentation.isAttached,
            reducedAnimation: store.settings.reducedAnimation,
            namespace: islandMorph
          ) {
            if case .completed = session.presentationStatus {
              store.dismissCompletion(sessionID: session.id)
            } else {
              store.toggleExpanded()
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .transition(contentTransition)
    }
    .overlay {
      if !presentation.isAttached {
        surfaceShape.stroke(.separator.opacity(0.55), lineWidth: 0.5)
      }
    }
    .contentShape(surfaceShape)
    .clipShape(surfaceShape)
    .animation(contentAnimation, value: layoutMode)
    .onHover(perform: handleHover)
    .simultaneousGesture(pullDownGesture)
    .onDisappear {
      hoverIntent?.cancel()
      pullDownTriggered = false
    }
    .onExitCommand { store.collapse() }
    .preferredColorScheme(presentation.isAttached ? .dark : nil)
  }

  private var isExpanded: Bool {
    store.isExpanded
  }

  private var surfaceShape: UnevenRoundedRectangle {
    let attachedRadius = isExpanded ? NotchTheme.expandedBottomRadius : NotchTheme.compactRadius
    return UnevenRoundedRectangle(
      cornerRadii: RectangleCornerRadii(
        topLeading: presentation.isAttached ? 0 : NotchTheme.floatingRadius,
        bottomLeading: presentation.isAttached ? attachedRadius : NotchTheme.floatingRadius,
        bottomTrailing: presentation.isAttached ? attachedRadius : NotchTheme.floatingRadius,
        topTrailing: presentation.isAttached ? 0 : NotchTheme.floatingRadius
      ),
      style: .continuous
    )
  }

  private var layoutMode: LayoutMode {
    if store.currentApproval != nil, store.isExpanded { return .approval }
    if store.isExpanded { return .sessions }
    return .compact
  }

  private var motionReduced: Bool {
    reduceMotion || store.settings.reducedAnimation
  }

  private var contentAnimation: Animation {
    if motionReduced {
      return .easeOut(duration: NotchTheme.reducedMotionFadeDuration)
    }
    return layoutMode == .compact ? NotchTheme.contentCollapse : NotchTheme.contentSpring
  }

  private var contentTransition: AnyTransition {
    .opacity
  }

  private var pullDownGesture: some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard !pullDownTriggered, presentation.isAttached, store.currentApproval == nil,
          value.translation.height > 12
        else { return }
        pullDownTriggered = true
        store.expand()
      }
      .onEnded { value in
        defer { pullDownTriggered = false }
        guard !pullDownTriggered, presentation.isAttached, store.currentApproval == nil,
          value.translation.height > 12
        else { return }
        store.expand()
      }
  }

  private func handleHover(_ isHovering: Bool) {
    hoverIntent?.cancel()
    #if DEBUG
      guard !CommandLine.arguments.contains("--disable-auto-hover") else { return }
    #endif
    guard presentation.isAttached, store.currentApproval == nil else { return }

    hoverIntent = Task { @MainActor in
      let delay = isHovering ? NotchTheme.hoverOpenDelay : NotchTheme.hoverCloseDelay
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      if isHovering {
        store.expand()
      } else {
        store.collapse()
      }
    }
  }
}

private enum LayoutMode: Hashable {
  case compact
  case sessions
  case approval
}
