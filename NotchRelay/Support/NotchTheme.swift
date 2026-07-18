import SwiftUI

// Aesthetic direction: quiet / precise / technical.
// Type: SF Pro + SF Mono for native macOS legibility.
// Color: graphite surface, cool cyan relay accent, semantic mint/amber/coral.
// Density: compact overlay on a 4-point grid; comfortable system-native windows.
// Radius: continuous pill geometry; no ornamental cards.
// Motion: restrained spring transitions, disabled for Reduce Motion.
enum NotchTheme {
  static let island = Color(red: 0.018, green: 0.022, blue: 0.028)
  static let islandRaised = Color(red: 0.055, green: 0.063, blue: 0.075)
  static let accent = Color(red: 0.49, green: 0.906, blue: 1.0)
  static let success = Color(red: 0.42, green: 0.90, blue: 0.67)
  static let warning = Color(red: 1.0, green: 0.73, blue: 0.34)
  static let failure = Color(red: 1.0, green: 0.43, blue: 0.42)
  static let hairline = Color.white.opacity(0.12)

  static let compactSize = CGSize(width: 158, height: 34)
  static let approvalSize = CGSize(width: 380, height: 156)
  static let attachedWingWidth: CGFloat = 82

  static func attachedSize(
    baseSize: CGSize,
    notchGapWidth: CGFloat,
    safeAreaTop: CGFloat,
    expanded: Bool
  ) -> CGSize {
    if expanded {
      return CGSize(
        width: max(baseSize.width, notchGapWidth + 48),
        height: baseSize.height + safeAreaTop
      )
    }
    return CGSize(
      width: max(baseSize.width, notchGapWidth + attachedWingWidth * 2),
      height: max(baseSize.height, safeAreaTop)
    )
  }

  static func sessionListSize(sessionCount: Int) -> CGSize {
    CGSize(width: 360, height: 76 + CGFloat(min(5, max(1, sessionCount))) * 32)
  }
}
