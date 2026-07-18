import AppKit
import SwiftUI

@main
struct CowlickApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let services = AppServices.shared

  var body: some Scene {
    MenuBarExtra {
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
