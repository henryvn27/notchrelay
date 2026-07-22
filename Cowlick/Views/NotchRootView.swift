import SwiftUI

struct NotchRootView: View {
  let services: AppServices
  let presentation: NotchPanelPresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState private var pullDistance: CGFloat = 0

  private var store: SessionStore { services.sessionStore }
  private var usageStore: UsageStore { services.usageStore }

  var body: some View {
    notchSurface
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onExitCommand { store.collapse() }
      .preferredColorScheme(presentation.isAttached ? .dark : nil)
  }

  private var notchSurface: some View {
    ZStack(alignment: .top) {
      if presentation.isAttached {
        animatedSurfaceShape.fill(NotchTheme.island)
          .animation(surfaceAnimation, value: presentation.state)
      } else {
        animatedSurfaceShape.fill(NotchTheme.floatingSurface)
          .animation(surfaceAnimation, value: presentation.state)
      }

      VStack(spacing: 0) {
        if let session = store.displaySession ?? store.sessionSummaries.first {
          CollapsedIslandView(
            session: session,
            completionStatus: store.displaySession?.presentationStatus,
            usageStore: usageStore,
            activeCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            isAttached: presentation.isAttached,
            height: compactHeaderHeight,
            reducedAnimation: store.settings.reducedAnimation,
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
            completionStatus: nil,
            usageStore: usageStore,
            activeCount: 0,
            activeSubagentCount: 0,
            notchGapWidth: presentation.isAttached ? presentation.notchGapWidth : nil,
            isAttached: presentation.isAttached,
            height: compactHeaderHeight,
            reducedAnimation: store.settings.reducedAnimation,
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
            services: services,
            isAttached: presentation.isAttached,
            allowsEmergencyScrolling: requiresEmergencyScrolling,
            contentHeightDidChange: presentation.reportInformationContentHeight
          )
          .transition(expandedTransition)
          .zIndex(0)
        }
      }
      .frame(
        width: presentation.surfaceSize.width,
        height: presentation.surfaceSize.height,
        alignment: .top
      )
      .scaleEffect(
        x: 1,
        y: motionReduced ? 1 : 1 + NotchPullGesturePolicy.progress(for: pullDistance) * 0.015,
        anchor: .top
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .overlay {
      if !presentation.isAttached {
        animatedSurfaceShape.stroke(.separator.opacity(0.55), lineWidth: 0.5)
          .animation(surfaceAnimation, value: presentation.state)
      }
    }
    .contentShape(animatedSurfaceShape)
    .mask {
      animatedSurfaceShape.fill(.white)
        .animation(surfaceAnimation, value: presentation.state)
    }
    .simultaneousGesture(pullDownGesture)
  }

  private var isExpanded: Bool {
    presentation.mode.isExpanded
  }

  private var compactHeaderHeight: CGFloat {
    presentation.isAttached ? presentation.safeAreaTop : NotchTheme.compactSize.height
  }

  private var requiresEmergencyScrolling: Bool {
    let availableHeight = max(0, presentation.surfaceSize.height - compactHeaderHeight)
    return presentation.informationContentHeight <= 0
      || presentation.informationContentHeight > availableHeight + 0.5
  }

  private var animatedSurfaceShape: TopAnchoredNotchShape {
    let attachedRadius = isExpanded ? NotchTheme.expandedBottomRadius : NotchTheme.compactRadius
    return TopAnchoredNotchShape(
      size: presentation.surfaceSize,
      topRadius: presentation.isAttached ? 0 : NotchTheme.floatingRadius,
      bottomRadius: presentation.isAttached ? attachedRadius : NotchTheme.floatingRadius
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
    .asymmetric(
      insertion: .opacity.animation(
        motionReduced ? NotchTheme.reducedMotion : NotchTheme.contentReveal),
      removal: .opacity.animation(
        motionReduced ? NotchTheme.reducedMotion : NotchTheme.contentConceal)
    )
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

  private var hasExpandableContent: Bool {
    hasUsage || !store.sessionSummaries.isEmpty
  }

  private func handleHeaderAction() {
    if isExpanded {
      store.collapse()
      return
    }

    if let session = store.displaySession,
      CollapsedIslandView.showsCompletionIndicator(for: session.presentationStatus)
    {
      store.dismissCompletion(sessionID: session.id)
    }
    if !store.sessionSummaries.isEmpty {
      store.expand()
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

/// Draws the changing Cowlick surface inside the already-prepared AppKit host. The path's y-origin
/// is always zero, so size interpolation can only reveal or conceal pixels below the physical notch.
struct TopAnchoredNotchShape: Shape {
  typealias SurfaceAnimationData = AnimatablePair<
    AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>
  >

  var size: CGSize
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: SurfaceAnimationData {
    get {
      AnimatablePair(
        AnimatablePair(size.width, size.height),
        AnimatablePair(topRadius, bottomRadius)
      )
    }
    set {
      size = CGSize(width: newValue.first.first, height: newValue.first.second)
      topRadius = newValue.second.first
      bottomRadius = newValue.second.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let width = min(max(0, size.width), rect.width)
    let height = min(max(0, size.height), rect.height)
    let surfaceRect = CGRect(
      x: rect.midX - width / 2,
      y: rect.minY,
      width: width,
      height: height
    )
    return UnevenRoundedRectangle(
      cornerRadii: RectangleCornerRadii(
        topLeading: topRadius,
        bottomLeading: bottomRadius,
        bottomTrailing: bottomRadius,
        topTrailing: topRadius
      ),
      style: .continuous
    ).path(in: surfaceRect)
  }
}
