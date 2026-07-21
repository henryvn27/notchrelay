import AppKit
import SwiftUI

@main
struct CowlickApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let services = AppServices.shared

  var body: some Scene {
    let showsMenuBar = services.presentationCoordinator.showsMenuBar
    MenuBarExtra(
      isInserted: Binding(
        get: { showsMenuBar },
        set: { _ in }
      )
    ) {
      MenuBarContentView(services: services)
    } label: {
      MenuBarLabelView(
        store: services.sessionStore,
        usageStore: services.usageStore,
        settings: services.settings
      )
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(services: services)
    }
  }
}
