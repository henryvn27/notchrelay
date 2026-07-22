import SwiftUI

struct NotchRootView: View {
  let store: SessionStore
  let usageStore: UsageStore
  let presentation: NotchPanelPresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var islandMorph
  @State private var collapseIntent: Task<Void, Never>?
  @GestureState private var pullDistance: CGFloat = 0

  var body: some View {
    notchSurface
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onDisappear { collapseIntent?.cancel() }
      .onExitCommand { store.collapse() }
      .preferredColorScheme(presentation.isAttached ? .dark : nil)
  }

  private var notchSurface: some View {
    ZStack(alignment: .top) {
      if presentation.isAttached {
        surfaceShape.fill(NotchTheme.island)
      } else {
        surfaceShape.fill(NotchTheme.floatingSurface)
      }

      VStack(spacing: 0) {
        if let session = store.displaySession ?? store.sessionSummaries.first {
          CollapsedIslandView(
            session: session,
            usageStore: usageStore,
            activeCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            isAttached: presentation.isAttached,
            reducedAnimation: store.settings.reducedAnimation,
            namespace: islandMorph,
            action: handleHeaderAction
          )
          .frame(
            height: presentation.isAttached
              ? presentation.safeAreaTop : NotchTheme.compactSize.height
          )
          .zIndex(1)
        } else if hasUsage {
          CollapsedIslandView(
            session: nil,
            usageStore: usageStore,
            activeCount: 0,
            activeSubagentCount: 0,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            isAttached: presentation.isAttached,
            reducedAnimation: store.settings.reducedAnimation,
            namespace: islandMorph,
            action: handleHeaderAction
          )
          .frame(
            height: presentation.isAttached
              ? presentation.safeAreaTop : NotchTheme.compactSize.height
          )
          .zIndex(1)
        }

        if presentation.mode.isExpanded {
          ExpandedIslandView(
            store: store,
            isAttached: presentation.isAttached
          )
          .transition(expandedTransition)
          .zIndex(0)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .scaleEffect(
        x: 1,
        y: motionReduced ? 1 : 1 + NotchPullGesturePolicy.progress(for: pullDistance) * 0.015,
        anchor: .top
      )
    }
    .frame(
      width: presentation.surfaceSize.width,
      height: presentation.surfaceSize.height,
      alignment: .top
    )
    .overlay {
      if !presentation.isAttached {
        surfaceShape.stroke(.separator.opacity(0.55), lineWidth: 0.5)
      }
    }
    .contentShape(surfaceShape)
    .clipShape(surfaceShape)
    .animation(surfaceAnimation, value: presentation.state)
    .onHover(perform: handleHover)
    .simultaneousGesture(pullDownGesture)
  }

  private var isExpanded: Bool {
    presentation.mode.isExpanded
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

  private var layoutMode: NotchSurfaceMode {
    presentation.mode
  }

  private var motionReduced: Bool {
    reduceMotion || store.settings.reducedAnimation
  }

  private var surfaceAnimation: Animation? {
    if motionReduced {
      return nil
    }
    return layoutMode == .compact ? NotchTheme.surfaceClose : NotchTheme.surfaceOpen
  }

  private var expandedTransition: AnyTransition {
    .opacity.animation(motionReduced ? NotchTheme.reducedMotion : NotchTheme.contentReveal)
  }

  private var hasUsage: Bool {
    CollapsedIslandView.usageText(
      showCodexUsage: usageStore.settings.showCodexUsage,
      percent: usageStore.primaryDisplayedPercent
    ) != nil
  }

  private var pullDownGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .updating($pullDistance) { value, distance, _ in
        guard
          presentation.isAttached,
          store.currentApproval == nil,
          hasExpandableContent,
          !motionReduced
        else { return }
        distance = max(0, value.translation.height)
      }
      .onEnded { value in
        guard presentation.isAttached, store.currentApproval == nil, hasExpandableContent else {
          return
        }
        if NotchPullGesturePolicy.shouldExpand(
          distance: value.translation.height,
          predictedDistance: value.predictedEndTranslation.height
        ) {
          withAnimation(motionReduced ? nil : NotchTheme.dragRelease) {
            expandSurface()
          }
        }
      }
  }

  private func handleHover(_ isHovering: Bool) {
    collapseIntent?.cancel()
    #if DEBUG
      guard !CommandLine.arguments.contains("--disable-auto-hover") else { return }
    #endif
    guard !isHovering, presentation.isAttached, store.currentApproval == nil, isExpanded else {
      return
    }

    collapseIntent = Task { @MainActor in
      try? await Task.sleep(for: .seconds(NotchTheme.hoverCloseDelay))
      guard !Task.isCancelled else { return }
      store.collapse()
    }
  }

  private var hasExpandableContent: Bool {
    hasUsage || !store.sessionSummaries.isEmpty
  }

  private func handleHeaderAction() {
    if isExpanded {
      store.collapse()
    } else if let session = store.displaySession,
      case .completed = session.presentationStatus
    {
      store.dismissCompletion(sessionID: session.id)
    } else {
      expandSurface()
    }
  }

  private func expandSurface() {
    if store.sessionSummaries.isEmpty {
      guard hasUsage, !isExpanded else { return }
      store.toggleExpanded()
    } else {
      store.expand()
    }
  }
}
