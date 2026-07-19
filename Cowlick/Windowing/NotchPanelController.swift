import AppKit
import Observation
import QuartzCore
import SwiftUI

@MainActor
@Observable
final class NotchPanelPresentation {
  private(set) var isAttached = false
  private(set) var notchGapWidth: CGFloat = 0
  private(set) var safeAreaTop: CGFloat = 0

  func update(from geometry: ResolvedNotchGeometry) {
    isAttached = geometry.hasNotch
    notchGapWidth = geometry.notchGapWidth
    safeAreaTop = geometry.safeAreaTop
  }
}

@MainActor
final class NotchPanel: NSPanel {
  var permitsKeyInteraction = false
  override var canBecomeKey: Bool { permitsKeyInteraction }
  override var canBecomeMain: Bool { false }
}

struct ApprovalFocusTracker {
  private var hasPresentedApproval = false

  mutating func shouldActivate(isApproval: Bool) -> Bool {
    guard isApproval else {
      hasPresentedApproval = false
      return false
    }
    guard !hasPresentedApproval else { return false }
    hasPresentedApproval = true
    return true
  }
}

@MainActor
final class NotchPanelController {
  private let store: SessionStore
  private let panel: NotchPanel
  private let presentation = NotchPanelPresentation()
  private var observers: [NSObjectProtocol] = []
  private var presentationUpdateScheduled = false
  private var approvalFocusTracker = ApprovalFocusTracker()
  private(set) var currentGeometry: ResolvedNotchGeometry?

  init(store: SessionStore) {
    self.store = store
    panel = NotchPanel(
      contentRect: CGRect(origin: .zero, size: NotchTheme.compactSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configurePanel()
    let hostingView = NotchHostingView(
      rootView: NotchRootView(store: store, presentation: presentation))
    hostingView.canInterpretSwipe = { [weak store, weak presentation] in
      guard let store, let presentation else { return false }
      return presentation.isAttached && store.currentApproval == nil
    }
    hostingView.handleSwipeAction = { [weak store] action in
      guard let store, store.currentApproval == nil else { return false }
      switch action {
      case .expand:
        guard !store.isExpanded, !store.sessionSummaries.isEmpty else { return false }
        store.expand()
      case .collapse:
        guard store.isExpanded else { return false }
        store.collapse()
      }
      return true
    }
    panel.contentView = hostingView
    installObservers()
    store.presentationDidChange = { [weak self] in self?.schedulePresentationUpdate() }
  }

  func updatePresentation() {
    let interactiveApproval = store.currentApproval != nil
    if !interactiveApproval {
      _ = approvalFocusTracker.shouldActivate(isApproval: false)
    }

    let baseSize: CGSize
    if interactiveApproval {
      baseSize = NotchTheme.approvalSize
    } else if store.isExpanded {
      baseSize = NotchTheme.sessionListSize(sessionCount: store.sessionSummaries.count)
    } else {
      baseSize = NotchTheme.compactSize
    }

    guard store.shouldShowOverlay,
      let screen = NotchGeometryResolver.preferredScreen(store.settings.preferredDisplay)
    else {
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }

    let isExpanded = store.currentApproval != nil || store.isExpanded
    let contentSize: CGSize
    if let metrics = resolvedNotchMetrics(for: screen) {
      contentSize = NotchTheme.attachedSize(
        baseSize: baseSize,
        notchGapWidth: metrics.gapWidth,
        safeAreaTop: metrics.safeAreaTop,
        expanded: isExpanded
      )
    } else {
      contentSize = baseSize
    }

    guard let geometry = resolvedGeometry(screen: screen, contentSize: contentSize)
    else {
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }

    let previousGeometry = currentGeometry
    currentGeometry = geometry
    presentation.update(from: geometry)
    panel.hasShadow = !geometry.hasNotch
    panel.permitsKeyInteraction = interactiveApproval
    panel.ignoresMouseEvents = false
    if interactiveApproval {
      panel.styleMask.remove(.nonactivatingPanel)
    } else {
      panel.styleMask.insert(.nonactivatingPanel)
    }

    // Do not force a hosting-view layout here. Ordering the panel performs the
    // required layout once; forcing a display first can re-enter SwiftUI text
    // layout when an approval changes the panel's key-window behavior.
    let reduceMotion =
      store.settings.reducedAnimation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let shouldAnimate =
      panel.isVisible && previousGeometry?.displayID == geometry.displayID && !reduceMotion
    if shouldAnimate, panel.frame != geometry.panelFrame {
      let expanding = geometry.panelFrame.height > panel.frame.height
      let controlPoints =
        expanding
        ? NotchTheme.expandTimingControlPoints
        : NotchTheme.collapseTimingControlPoints
      NSAnimationContext.runAnimationGroup { context in
        context.duration =
          expanding ? NotchTheme.panelExpandDuration : NotchTheme.panelCollapseDuration
        context.timingFunction = CAMediaTimingFunction(
          controlPoints: controlPoints.0,
          controlPoints.1,
          controlPoints.2,
          controlPoints.3
        )
        panel.animator().setFrame(geometry.panelFrame, display: true)
      }
    } else {
      panel.setFrame(geometry.panelFrame, display: false)
    }

    let wasVisible = panel.isVisible
    let shouldActivateApproval =
      interactiveApproval && approvalFocusTracker.shouldActivate(isApproval: true)
    if shouldActivateApproval {
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFrontRegardless()
    }
    if !wasVisible, !reduceMotion {
      panel.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NotchTheme.reducedMotionFadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
    } else {
      panel.alphaValue = 1
    }
  }

  func open() {
    guard !store.sessionSummaries.isEmpty else { return }
    store.isExpanded = true
    schedulePresentationUpdate()
  }

  private func schedulePresentationUpdate() {
    guard !presentationUpdateScheduled else { return }
    presentationUpdateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.presentationUpdateScheduled = false
      self.updatePresentation()
    }
  }

  private func configurePanel() {
    panel.identifier = NSUserInterfaceItemIdentifier("CowlickPanel")
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.acceptsMouseMovedEvents = true
  }

  private func resolvedNotchMetrics(for screen: NSScreen) -> NotchMetrics? {
    #if DEBUG
      if CommandLine.arguments.contains("--simulate-notch") {
        return NotchMetrics(gapWidth: 212, safeAreaTop: 38)
      }
    #endif
    return NotchGeometryResolver.notchMetrics(screen: screen)
  }

  private func resolvedGeometry(screen: NSScreen, contentSize: CGSize)
    -> ResolvedNotchGeometry?
  {
    #if DEBUG
      if CommandLine.arguments.contains("--simulate-notch") {
        let safeAreaTop: CGFloat = 38
        let gapWidth: CGFloat = 212
        let auxiliaryWidth = (screen.frame.width - gapWidth) / 2
        let auxiliaryY = screen.frame.maxY - safeAreaTop
        return NotchGeometryResolver.resolve(
          screenFrame: screen.frame,
          visibleFrame: screen.visibleFrame,
          safeAreaTop: safeAreaTop,
          auxiliaryTopLeftArea: CGRect(
            x: screen.frame.minX,
            y: auxiliaryY,
            width: auxiliaryWidth,
            height: safeAreaTop
          ),
          auxiliaryTopRightArea: CGRect(
            x: screen.frame.midX + gapWidth / 2,
            y: auxiliaryY,
            width: auxiliaryWidth,
            height: safeAreaTop
          ),
          requestedContentSize: contentSize,
          displayID: screen.displayID,
          showOnNonNotch: true
        )
      }
    #endif
    return NotchGeometryResolver.resolve(
      screen: screen,
      contentSize: contentSize,
      showOnNonNotch: store.settings.showOnNonNotch
    )
  }

  private func installObservers() {
    let center = NotificationCenter.default
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePresentationUpdate() }
      })
    observers.append(
      center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePresentationUpdate() }
      })
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePresentationUpdate() }
      })
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedulePresentationUpdate() }
      })
  }
}
