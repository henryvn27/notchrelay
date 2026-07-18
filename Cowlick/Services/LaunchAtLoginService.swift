import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginService {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
    } else if SMAppService.mainApp.status == .enabled {
      try SMAppService.mainApp.unregister()
    }
  }

  static var statusDescription: String {
    switch SMAppService.mainApp.status {
    case .enabled: "Enabled"
    case .requiresApproval: "Needs approval in Login Items"
    case .notRegistered: "Disabled"
    case .notFound: "Unavailable"
    @unknown default: "Unknown"
    }
  }
}
