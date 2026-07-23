import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
  static let shared = WindowCoordinator()

  private var services: AppServices?
  private var notchPanelController: NotchPanelController?
  private var onboardingWindowController: NSWindowController?
  private var diagnosticsWindowController: NSWindowController?
  private var settingsTestWindowController: NSWindowController?
  private var usageTestWindowController: NSWindowController?

  private init() {}

  func configure(services: AppServices) {
    self.services = services
    notchPanelController = NotchPanelController(services: services)
    services.presentationCoordinator.routeWillChange = { [weak self] previous, next in
      guard case .notch = previous, case .menuBar = next else { return }
      self?.notchPanelController?.setPresentationEnabled(false)
    }
    services.presentationCoordinator.routeDidChange = { [weak self] _, next in
      self?.notchPanelController?.setPresentationEnabled(!next.usesMenuBar)
    }
    notchPanelController?.setPresentationEnabled(
      !services.presentationCoordinator.activePresentation.usesMenuBar)
    notchPanelController?.updatePresentation()
  }

  func openIsland() {
    notchPanelController?.open()
  }

  func reviewCurrentApproval() {
    notchPanelController?.openCurrentApproval()
  }

  func openOnboarding() {
    guard let services else { return }
    if let window = onboardingWindowController?.window {
      present(window)
      return
    }
    let controller = makeWindow(
      title: "Welcome to Cowlick",
      size: CGSize(width: 640, height: 500),
      rootView: AnyView(OnboardingView(services: services))
    )
    onboardingWindowController = controller
    present(controller.window!)
  }

  func openDiagnostics() {
    guard let services else { return }
    if let window = diagnosticsWindowController?.window {
      present(window)
      return
    }
    let controller = makeWindow(
      title: "Cowlick Diagnostics",
      size: CGSize(width: 660, height: 520),
      rootView: AnyView(DiagnosticsView(services: services))
    )
    diagnosticsWindowController = controller
    present(controller.window!)
  }

  func openSettingsForTesting() {
    guard let services else { return }
    if let window = settingsTestWindowController?.window {
      present(window)
      return
    }
    let controller = makeWindow(
      title: "Cowlick Settings",
      size: CGSize(width: 600, height: 460),
      rootView: AnyView(SettingsView(services: services))
    )
    settingsTestWindowController = controller
    present(controller.window!)
  }

  func openUsageForTesting() {
    guard let services else { return }
    if let window = usageTestWindowController?.window {
      present(window)
      return
    }
    let size = CGSize(width: 400, height: 520)
    let panel = UsageCapturePanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.center()
    panel.contentViewController = NSHostingController(
      rootView: UsageCaptureView(services: services).frame(width: size.width, height: size.height)
    )
    let controller = NSWindowController(window: panel)
    usageTestWindowController = controller
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
  }

  private func makeWindow(title: String, size: CGSize, rootView: AnyView) -> NSWindowController {
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.contentMinSize = CGSize(width: size.width * 0.8, height: size.height * 0.8)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: rootView)
    // Installing an unconstrained SwiftUI hosting controller can replace the requested frame with
    // its ideal size. Reassert the caller's initial content size, then center that final frame.
    window.setContentSize(size)
    window.center()
    return NSWindowController(window: window)
  }

  private func present(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }
}

private final class UsageCapturePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private struct UsageCaptureView: View {
  let services: AppServices

  var body: some View {
    UsageSectionView(
      store: services.usageStore,
      showOfficialUsage: true,
      showAPICostEstimate: true,
      showForecast: true,
      metricPreference: .remaining,
      density: .detailed
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.separator.opacity(0.55), lineWidth: 0.5)
    }
  }
}
