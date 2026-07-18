import Foundation
import Sparkle

@MainActor
final class UpdateService: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
  private var controller: SPUStandardUpdaterController!

  override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
  }

  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    true
  }

  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

  func configure(automaticChecks: Bool, automaticDownloads: Bool) {
    controller.updater.automaticallyChecksForUpdates = automaticChecks
    controller.updater.automaticallyDownloadsUpdates = automaticDownloads
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
