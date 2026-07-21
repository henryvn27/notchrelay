import CoreGraphics
import Foundation

enum PresentationPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case menuBar

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: "Automatic"
    case .menuBar: "Menu bar"
    }
  }
}

enum ActivePresentation: Equatable, Sendable {
  case notch(displayID: CGDirectDisplayID)
  case menuBar

  var usesMenuBar: Bool {
    if case .menuBar = self { return true }
    return false
  }
}

enum PresentationRouting {
  static func resolve(
    preference: PresentationPreference,
    displayID: CGDirectDisplayID,
    hasNotch: Bool
  ) -> ActivePresentation {
    switch preference {
    case .automatic where hasNotch:
      .notch(displayID: displayID)
    case .automatic, .menuBar:
      .menuBar
    }
  }
}
