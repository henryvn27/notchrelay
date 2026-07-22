import AppKit
import SwiftUI

// Aesthetic direction: quiet, physical, and attached to the Mac rather than floating above it.
// Type: SF Pro for the interface; SF Mono only for operations and diagnostics.
// Color: physical black, a neutral stone control tint, and restrained semantic status colors.
// Density: compact overlay on a 4-point grid; comfortable system-native windows.
// Radius: continuous pill geometry; no ornamental cards.
// Motion: restrained spring transitions, disabled for Reduce Motion.
enum NotchTheme {
  static let island = Color.black
  static let floatingSurface = Color(nsColor: .windowBackgroundColor)
  static let islandRaised = Color(white: 0.075)
  static let accent = Color(red: 0.79, green: 0.78, blue: 0.74)
  static let success = Color(red: 0.53, green: 0.76, blue: 0.62)
  static let warning = Color(red: 0.88, green: 0.68, blue: 0.38)
  static let failure = Color(red: 0.84, green: 0.47, blue: 0.43)
  static let hairline = Color.white.opacity(0.12)

  static let compactSize = CGSize(width: 170, height: 34)
  static let maximumApprovalSize = CGSize(width: 380, height: 170)
  static let attachedWingWidth: CGFloat = 48
  static let compactRadius: CGFloat = 14
  static let expandedBottomRadius: CGFloat = 22
  static let floatingRadius: CGFloat = 12
  static let reducedMotionFadeDuration = 0.12
  static let hoverFeedbackDuration = 0.12
  static let hoverCloseDelay = 0.16
  // Surface springs follow Ping Island's fixed-shell engine. AppKit owns a
  // stable host window; SwiftUI retargets the complete notch surface.
  static let surfaceOpen = Animation.spring(
    response: 0.42, dampingFraction: 0.8, blendDuration: 0)
  static let surfaceClose = Animation.spring(
    response: 0.45, dampingFraction: 1.0, blendDuration: 0)
  static let statusChange = Animation.timingCurve(
    0.23, 1.00, 0.32, 1.00, duration: 0.16)
  static let contentReveal = Animation.timingCurve(
    0.23, 1.00, 0.32, 1.00, duration: 0.16)
  static let pressFeedback = Animation.timingCurve(
    0.23, 1.00, 0.32, 1.00, duration: 0.14)
  static let dragRelease = Animation.spring(duration: 0.5, bounce: 0.2)
  static let reducedMotion = Animation.easeOut(
    duration: reducedMotionFadeDuration
  )

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
      height: safeAreaTop
    )
  }

  static func sessionListSize(sessionCount: Int) -> CGSize {
    let visibleCount = sessionCount > 3 ? 2 : min(3, sessionCount)
    let overflowHeight: CGFloat = sessionCount > visibleCount ? 20 : 0
    let controlsHeight: CGFloat = 32
    return CGSize(
      width: 360,
      height: 20 + CGFloat(visibleCount) * 28 + overflowHeight + controlsHeight
    )
  }

  static func hostSize(notchGapWidth: CGFloat, safeAreaTop: CGFloat) -> CGSize {
    attachedSize(
      baseSize: maximumApprovalSize,
      notchGapWidth: notchGapWidth,
      safeAreaTop: safeAreaTop,
      expanded: true
    )
  }

  static func approvalSize(for request: ApprovalRequest) -> CGSize {
    var height: CGFloat = 96
    if request.projectContext != nil { height += 30 }
    if request.reasonPreview.count > 64 { height += 14 }
    if request.showsDistinctOperation {
      height += 20
      if request.operationPreview.count > 48 { height += 10 }
    }
    return CGSize(
      width: maximumApprovalSize.width,
      height: min(height, maximumApprovalSize.height)
    )
  }
}
