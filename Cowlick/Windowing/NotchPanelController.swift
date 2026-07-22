import AppKit
import Observation
import SwiftUI

enum NotchSurfaceMode: Hashable, Sendable {
  case compact
  case sessions
  case approval

  var isExpanded: Bool { self != .compact }
}

struct NotchSurfacePresentationState: Equatable, Sendable {
  var isAttached = false
  var notchGapWidth: CGFloat = 0
  var safeAreaTop: CGFloat = 0
  var surfaceSize = NotchTheme.compactSize
  var mode = NotchSurfaceMode.compact
}

@MainActor
@Observable
final class NotchPanelPresentation {
  private(set) var state = NotchSurfacePresentationState()

  var isAttached: Bool { state.isAttached }
  var notchGapWidth: CGFloat { state.notchGapWidth }
  var safeAreaTop: CGFloat { state.safeAreaTop }
  var surfaceSize: CGSize { state.surfaceSize }
  var mode: NotchSurfaceMode { state.mode }

  func update(
    from geometry: ResolvedNotchGeometry,
    surfaceSize: CGSize,
    mode: NotchSurfaceMode
  ) {
    state = NotchSurfacePresentationState(
      isAttached: geometry.hasNotch,
      notchGapWidth: geometry.notchGapWidth,
      safeAreaTop: geometry.safeAreaTop,
      surfaceSize: surfaceSize,
      mode: mode
    )
  }

  func interactiveRect(in hostSize: CGSize, isFlipped: Bool) -> CGRect {
    NotchSurfaceLayout.interactiveRect(
      hostSize: hostSize,
      surfaceSize: surfaceSize,
      isFlipped: isFlipped
    )
  }
}

@MainActor
final class NotchPanel: NSPanel {
  var permitsKeyInteraction = false
  override var canBecomeKey: Bool { permitsKeyInteraction }
  override var canBecomeMain: Bool { false }
}

enum NotchPanelInteractionPolicy {
  static func shouldActivate(isApproval: Bool, initiatedByUser: Bool) -> Bool {
    isApproval && initiatedByUser
  }
}

enum ApprovalAccessibilityPresentation {
  static func announcement(for request: ApprovalRequest) -> String {
    let context = [request.displayName, request.projectContext, request.toolName]
      .compactMap { $0 }
      .joined(separator: ", ")
    return "Approval requested for \(context)"
  }
}

@MainActor
final class NotchPanelController {
  private let store: SessionStore
  private let panel: NotchPanel
  private let presentation = NotchPanelPresentation()
  private var observers: [NSObjectProtocol] = []
  private var presentationUpdateScheduled = false
  private var lastAnnouncedApprovalID: UUID?
  private var presentationEnabled = false
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
    hostingView.handlePointerDown = { [weak self] in
      self?.activateApprovalForUserInteraction()
    }
    hostingView.interactiveRect = { [weak hostingView, weak presentation] in
      guard let hostingView, let presentation else { return .zero }
      return presentation.interactiveRect(
        in: hostingView.bounds.size,
        isFlipped: hostingView.isFlipped
      )
    }
    panel.contentView = hostingView
    installObservers()
    store.presentationDidChange = { [weak self] in self?.schedulePresentationUpdate() }
  }

  func updatePresentation() {
    announceCurrentApprovalIfNeeded()
    let interactiveApproval = store.currentApproval != nil && store.isExpanded

    let mode: NotchSurfaceMode
    let baseSize: CGSize
    if interactiveApproval, let approval = store.currentApproval {
      mode = .approval
      baseSize = NotchTheme.approvalSize(for: approval)
    } else if store.isExpanded {
      mode = .sessions
      baseSize = NotchTheme.sessionListSize(sessionCount: store.sessionSummaries.count)
    } else {
      mode = .compact
      baseSize = NotchTheme.compactSize
    }

    guard presentationEnabled, store.shouldShowOverlay,
      let screen = NotchGeometryResolver.preferredScreen(store.settings.preferredDisplay)
    else {
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }

    let isExpanded = store.isExpanded
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

    currentGeometry = geometry
    presentation.update(from: geometry, surfaceSize: contentSize, mode: mode)
    panel.hasShadow = !geometry.hasNotch
    panel.permitsKeyInteraction = interactiveApproval
    panel.ignoresMouseEvents = false
    if !interactiveApproval || !panel.isKeyWindow {
      panel.styleMask.insert(.nonactivatingPanel)
    }

    let reduceMotion =
      store.settings.reducedAnimation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let hostContentSize = NotchTheme.hostSize(
      notchGapWidth: geometry.notchGapWidth,
      safeAreaTop: geometry.safeAreaTop
    )
    guard let hostGeometry = resolvedGeometry(screen: screen, contentSize: hostContentSize) else {
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }
    if panel.frame != hostGeometry.panelFrame {
      panel.setFrame(hostGeometry.panelFrame, display: false)
    }

    let wasVisible = panel.isVisible
    panel.orderFrontRegardless()
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

  func setPresentationEnabled(_ enabled: Bool) {
    guard enabled != presentationEnabled else { return }
    presentationEnabled = enabled
    if enabled {
      schedulePresentationUpdate()
    } else {
      panel.orderOut(nil)
      currentGeometry = nil
    }
  }

  func open() {
    guard !store.sessionSummaries.isEmpty else { return }
    store.isExpanded = true
    schedulePresentationUpdate()
  }

  func openCurrentApproval() {
    guard store.currentApproval != nil else { return }
    store.expand()
    updatePresentation()
    activateApprovalForUserInteraction()
  }

  private func activateApprovalForUserInteraction() {
    let isApproval = store.currentApproval != nil && store.isExpanded
    guard
      NotchPanelInteractionPolicy.shouldActivate(
        isApproval: isApproval,
        initiatedByUser: true
      )
    else { return }
    panel.permitsKeyInteraction = true
    panel.styleMask.remove(.nonactivatingPanel)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  private func announceCurrentApprovalIfNeeded() {
    guard let approval = store.currentApproval else {
      lastAnnouncedApprovalID = nil
      return
    }
    guard lastAnnouncedApprovalID != approval.id else { return }
    lastAnnouncedApprovalID = approval.id
    AccessibilityNotification.Announcement(
      ApprovalAccessibilityPresentation.announcement(for: approval)
    ).post()
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
      showOnNonNotch: false
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
