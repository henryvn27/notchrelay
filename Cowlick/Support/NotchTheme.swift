import SwiftUI

// Aesthetic direction: quiet, physical, and attached to the Mac rather than floating above it.
// Type: SF Pro for the interface; SF Mono only for operations and diagnostics.
// Color: physical black, a neutral stone control tint, and restrained semantic status colors.
// Density: compact overlay on a 4-point grid; comfortable system-native windows.
// Radius: continuous pill geometry; no ornamental cards.
// Motion: restrained spring transitions, disabled for Reduce Motion.
enum NotchTheme {
  static let island = Color.black
  static let islandRaised = Color(white: 0.075)
  static let accent = Color(red: 0.79, green: 0.78, blue: 0.74)
  static let success = Color(red: 0.53, green: 0.76, blue: 0.62)
  static let warning = Color(red: 0.88, green: 0.68, blue: 0.38)
  static let failure = Color(red: 0.84, green: 0.47, blue: 0.43)
  static let hairline = Color.white.opacity(0.12)

  static let compactSize = CGSize(width: 158, height: 34)
  static let approvalSize = CGSize(width: 380, height: 180)
  static let attachedWingWidth: CGFloat = 82
  static let compactRadius: CGFloat = 14
  static let expandedBottomRadius: CGFloat = 22
  static let floatingRadius: CGFloat = 12
  static let panelExpandDuration = 0.24
  static let panelCollapseDuration = 0.18
  static let reducedMotionFadeDuration = 0.12
  static let hoverFeedbackDuration = 0.12
  static let hoverOpenDelay = 0.14
  static let hoverCloseDelay = 0.34
  static let contentSpring = Animation.spring(response: 0.24, dampingFraction: 0.90)
  static let contentCollapse = Animation.timingCurve(
    0.42,
    0.00,
    0.58,
    1.00,
    duration: panelCollapseDuration
  )

  // A decisive ease-out makes the panel feel attached to the camera housing:
  // most of the travel happens immediately, then the lower edge settles.
  static let expandTimingControlPoints: (Float, Float, Float, Float) =
    (0.16, 0.84, 0.24, 1.00)
  static let collapseTimingControlPoints: (Float, Float, Float, Float) =
    (0.42, 0.00, 0.58, 1.00)

  static func attachedSize(
    baseSize: CGSize,
    notchGapWidth: CGFloat,
    safeAreaTop: CGFloat,
    expanded: Bool
  ) -> CGSize {
    if expanded {
      return CGSize(
        width: max(baseSize.width, notchGapWidth + attachedWingWidth * 2),
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
