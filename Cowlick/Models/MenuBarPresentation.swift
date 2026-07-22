import Foundation

enum MenuBarPresentation: String, CaseIterable, Identifiable, Sendable {
  case iconAndDetails
  case percentageOnly
  case iconOnly
  case statusOnly
  case statusAndPercentage

  var id: String { rawValue }

  var label: String {
    switch self {
    case .iconAndDetails: "Icon and details"
    case .percentageOnly: "Usage quota"
    case .iconOnly: "App icon only"
    case .statusOnly: "Activity icon only"
    case .statusAndPercentage: "Activity and percentage"
    }
  }

  var guidance: String {
    switch self {
    case .iconAndDetails:
      "Shows the Cowlick icon, multiple-session count, and primary quota percentage."
    case .percentageOnly:
      "Shows a usage-chart symbol and the primary Codex quota as percent left or used."
    case .iconOnly:
      "Shows only the Cowlick app icon."
    case .statusOnly:
      "Shows a symbol for idle, working, approval, completed, or failed."
    case .statusAndPercentage:
      "Shows the current activity symbol beside the primary quota percentage."
    }
  }
}

struct MenuBarLabelContent: Equatable {
  enum Icon: Equatable {
    case app
    case usage
    case status(String)
  }

  let icon: Icon
  let text: String?

  static func resolve(
    presentation: MenuBarPresentation,
    status: AgentStatus?,
    activeSessionCount: Int,
    percentageText: String?
  ) -> MenuBarLabelContent {
    switch presentation {
    case .iconAndDetails:
      let sessions = activeSessionCount > 1 ? "\(activeSessionCount)" : nil
      let text = [sessions, percentageText].compactMap { $0 }.joined(separator: " · ")
      return MenuBarLabelContent(icon: .app, text: text.isEmpty ? nil : text)
    case .percentageOnly:
      return MenuBarLabelContent(icon: .usage, text: percentageText ?? "Quota —")
    case .iconOnly:
      return MenuBarLabelContent(icon: .app, text: nil)
    case .statusOnly:
      return MenuBarLabelContent(icon: statusIcon(for: status), text: nil)
    case .statusAndPercentage:
      return MenuBarLabelContent(
        icon: statusIcon(for: status), text: percentageText)
    }
  }

  private static func statusIcon(for status: AgentStatus?) -> Icon {
    switch status {
    case .working: .status("waveform.path")
    case .awaitingApproval: .status("exclamationmark.shield.fill")
    case .completed: .status("checkmark.circle.fill")
    case .failed: .status("xmark.circle.fill")
    case .idle, nil: .app
    }
  }
}
