import AppKit
import Observation

@MainActor
@Observable
final class PresentationCoordinator {
  private let settings: SettingsStore
  private var observers: [NSObjectProtocol] = []
  private(set) var activePresentation: ActivePresentation
  var routeWillChange: ((ActivePresentation, ActivePresentation) -> Void)?
  var routeDidChange: ((ActivePresentation, ActivePresentation) -> Void)?

  init(settings: SettingsStore) {
    self.settings = settings
    activePresentation = Self.resolve(settings: settings)
  }

  var showsMenuBar: Bool { activePresentation.usesMenuBar }

  var resolvedDescription: String {
    switch activePresentation {
    case .notch: "Using the MacBook notch. Cowlick stays out of the menu bar."
    case .menuBar: "Using one menu-bar item. Cowlick does not draw a floating notch."
    }
  }

  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    observers.append(
      center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      })
    refresh()
  }

  func refresh() {
    let next = Self.resolve(settings: settings)
    guard next != activePresentation else { return }
    let previous = activePresentation
    routeWillChange?(previous, next)
    activePresentation = next
    routeDidChange?(previous, next)
  }

  private static func resolve(settings: SettingsStore) -> ActivePresentation {
    let screen = NotchGeometryResolver.preferredScreen(settings.preferredDisplay)
    let displayID = screen?.displayID ?? 0
    #if DEBUG
      let simulatesNotch = CommandLine.arguments.contains("--simulate-notch")
    #else
      let simulatesNotch = false
    #endif
    return PresentationRouting.resolve(
      preference: settings.presentationPreference,
      displayID: displayID,
      hasNotch: simulatesNotch || screen.map(NotchGeometryResolver.notchMetrics(screen:)) != nil
    )
  }
}
