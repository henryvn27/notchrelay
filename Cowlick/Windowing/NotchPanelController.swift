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
  private(set) var informationContentHeight: CGFloat = 0

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

  func reportInformationContentHeight(_ height: CGFloat) {
    let height = max(0, height)
    guard abs(informationContentHeight - height) >= 0.5 else { return }
    informationContentHeight = height
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
  private let services: AppServices
  private var store: SessionStore { services.sessionStore }
  private var usageStore: UsageStore { services.usageStore }
  private let panel: NotchPanel
  private let presentation = NotchPanelPresentation()
  private let hostingView: NotchHostingView<NotchRootView>
  private var observers: [NSObjectProtocol] = []
  private var presentationUpdateScheduled = false
  private var geometryTransitionTask: Task<Void, Never>?
  private var hoverIntent: Task<Void, Never>?
  private var lastAnnouncedApprovalID: UUID?
  private var presentationEnabled = false
  private(set) var currentGeometry: ResolvedNotchGeometry?

  init(services: AppServices) {
    self.services = services
    panel = NotchPanel(
      contentRect: CGRect(origin: .zero, size: NotchTheme.compactSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    hostingView = NotchHostingView(
      rootView: NotchRootView(
        services: services,
        presentation: presentation
      ))
    hostingView.handlePointerDown = { [weak self] in
      self?.activateApprovalForUserInteraction()
    }
    hostingView.handlePointerPresenceChange = { [weak self] isInside in
      self?.handlePointerPresenceChange(isInside)
    }
    hostingView.interactiveRect = { [weak hostingView, weak presentation] in
      guard let hostingView, let presentation else { return .zero }
      return presentation.interactiveRect(
        in: hostingView.bounds.size,
        isFlipped: hostingView.isFlipped
      )
    }
    configurePanel()
    panel.contentView = hostingView
    installObservers()
    observeUsageChanges()
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
      let estimatedSize = NotchTheme.expandedInformationSize(
        sessionCount: store.sessionSummaries.count,
        showsCurrentWork: services.settings.showNotchCurrentWork,
        showsIntegrationAlerts: services.settings.showNotchIntegrationAlerts,
        showsOfficialUsage: services.settings.showCodexUsage
          && services.settings.showNotchCodexUsage,
        showsAPICostEstimate: services.settings.showAPICostEstimate
          && services.settings.showNotchAPICostEstimate,
        showsForecast: services.settings.showResetForecast
          && services.settings.showNotchResetForecast,
        showsBilling: services.settings.showNotchProviderBilling
          && !services.providerAccountsController.accounts.isEmpty
      )
      baseSize = CGSize(
        width: estimatedSize.width,
        height: presentation.informationContentHeight > 0
          ? presentation.informationContentHeight : estimatedSize.height
      )
    } else {
      mode = .compact
      baseSize = NotchTheme.compactSize
    }

    guard presentationEnabled, store.shouldShowOverlay || hasUsagePresentation,
      let screen = NotchGeometryResolver.preferredScreen(store.settings.preferredDisplay)
    else {
      geometryTransitionTask?.cancel()
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }

    let isExpanded = store.isExpanded
    let unboundedContentSize: CGSize
    let notchMetrics = resolvedNotchMetrics(for: screen)
    if let metrics = notchMetrics {
      unboundedContentSize = NotchTheme.attachedSize(
        baseSize: baseSize,
        notchGapWidth: metrics.gapWidth,
        safeAreaTop: metrics.safeAreaTop,
        expanded: isExpanded,
        allowsWidthGrowth: mode == .approval
      )
    } else {
      unboundedContentSize = baseSize
    }
    let maximumPanelHeight =
      notchMetrics == nil
      ? max(NotchTheme.actionBarHeight, screen.visibleFrame.height - 12)
      : max(NotchTheme.actionBarHeight, screen.frame.height - 24)
    let contentSize = CGSize(
      width: unboundedContentSize.width,
      height: min(unboundedContentSize.height, maximumPanelHeight)
    )

    guard let geometry = resolvedGeometry(screen: screen, contentSize: contentSize)
    else {
      panel.orderOut(nil)
      currentGeometry = nil
      return
    }

    geometryTransitionTask?.cancel()
    currentGeometry = geometry
    panel.hasShadow = !geometry.hasNotch
    panel.permitsKeyInteraction = interactiveApproval
    panel.ignoresMouseEvents = false
    if !interactiveApproval || !panel.isKeyWindow {
      panel.styleMask.insert(.nonactivatingPanel)
    }

    let reduceMotion =
      store.settings.reducedAnimation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let wasVisible = panel.isVisible
    panel.orderFrontRegardless()

    let presentationNeedsUpdate =
      presentation.isAttached != geometry.hasNotch
      || presentation.notchGapWidth != geometry.notchGapWidth
      || presentation.safeAreaTop != geometry.safeAreaTop
      || presentation.surfaceSize != contentSize
      || presentation.mode != mode
    let growsHost =
      geometry.panelFrame.width > panel.frame.width
      || geometry.panelFrame.height > panel.frame.height
    let shrinksHost =
      geometry.panelFrame.width < panel.frame.width
      || geometry.panelFrame.height < panel.frame.height

    if !wasVisible || reduceMotion || !presentationNeedsUpdate {
      if panel.frame != geometry.panelFrame {
        panel.setFrame(geometry.panelFrame, display: false)
      }
      updatePresentationModel(from: geometry, surfaceSize: contentSize, mode: mode)
    } else if growsHost {
      panel.setFrame(geometry.panelFrame, display: false)
      geometryTransitionTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, !Task.isCancelled, self.currentGeometry == geometry else { return }
        self.updatePresentationModel(from: geometry, surfaceSize: contentSize, mode: mode)
      }
    } else {
      updatePresentationModel(from: geometry, surfaceSize: contentSize, mode: mode)
      if shrinksHost {
        geometryTransitionTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(NotchTheme.surfaceCloseDuration))
          guard let self, !Task.isCancelled, self.currentGeometry == geometry else { return }
          self.panel.setFrame(geometry.panelFrame, display: false)
        }
      }
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

  func setPresentationEnabled(_ enabled: Bool) {
    guard enabled != presentationEnabled else { return }
    presentationEnabled = enabled
    if enabled {
      schedulePresentationUpdate()
    } else {
      geometryTransitionTask?.cancel()
      hoverIntent?.cancel()
      panel.orderOut(nil)
      currentGeometry = nil
    }
  }

  private func updatePresentationModel(
    from geometry: ResolvedNotchGeometry,
    surfaceSize: CGSize,
    mode: NotchSurfaceMode
  ) {
    presentation.update(from: geometry, surfaceSize: surfaceSize, mode: mode)
    hostingView.refreshPointerTrackingArea()
  }

  private func handlePointerPresenceChange(_ isInside: Bool) {
    hoverIntent?.cancel()
    #if DEBUG
      guard !CommandLine.arguments.contains("--disable-auto-hover") else { return }
    #endif
    guard presentation.isAttached, store.currentApproval == nil else { return }

    let delay: TimeInterval
    if isInside {
      guard !store.isExpanded, !store.sessionSummaries.isEmpty else { return }
      delay = NotchTheme.hoverOpenDelay
    } else {
      guard store.isExpanded else { return }
      delay = NotchTheme.hoverCloseDelay
    }

    hoverIntent = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled else { return }
      let isActuallyInside = NotchSurfaceLayout.hoverScreenRect(
        panelFrame: self.panel.frame,
        surfaceSize: self.presentation.surfaceSize
      ).contains(NSEvent.mouseLocation)
      if isInside {
        guard isActuallyInside, !self.store.isExpanded,
          !self.store.sessionSummaries.isEmpty
        else { return }
        self.store.expand()
      } else {
        guard !isActuallyInside, self.store.isExpanded else { return }
        self.store.collapse()
      }
    }
  }

  func open() {
    guard !store.sessionSummaries.isEmpty || hasUsagePresentation else { return }
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

  private var hasUsagePresentation: Bool {
    CollapsedIslandView.usageText(
      showCodexUsage: usageStore.settings.showCodexUsage,
      percent: usageStore.primaryDisplayedPercent
    ) != nil
  }

  private func observeUsageChanges() {
    withObservationTracking {
      _ = usageStore.settings.showCodexUsage
      _ = usageStore.settings.showAPICostEstimate
      _ = usageStore.settings.showResetForecast
      _ = usageStore.settings.showNotchCurrentWork
      _ = usageStore.settings.showNotchIntegrationAlerts
      _ = usageStore.settings.showNotchCodexUsage
      _ = usageStore.settings.showNotchAPICostEstimate
      _ = usageStore.settings.showNotchResetForecast
      _ = usageStore.settings.showNotchProviderBilling
      _ = usageStore.primaryDisplayedPercent
      _ = services.providerAccountsController.accounts.count
      _ = presentation.informationContentHeight
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observeUsageChanges()
        self?.schedulePresentationUpdate()
      }
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
