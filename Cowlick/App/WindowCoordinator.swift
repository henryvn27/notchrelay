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

  private init() {}

  func configure(services: AppServices) {
    self.services = services
    notchPanelController = NotchPanelController(store: services.sessionStore)
    notchPanelController?.updatePresentation()
  }

  func openIsland() {
    notchPanelController?.open()
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
    window.center()
    window.contentViewController = NSHostingController(rootView: rootView)
    return NSWindowController(window: window)
  }

  private func present(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}
