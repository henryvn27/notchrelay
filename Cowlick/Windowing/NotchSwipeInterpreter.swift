import AppKit
import SwiftUI

enum NotchSurfaceLayout {
  private static let hoverSlop: CGFloat = 2

  static func interactiveRect(
    hostSize: CGSize,
    surfaceSize: CGSize,
    isFlipped: Bool = true
  ) -> CGRect {
    let boundedHeight = min(hostSize.height, surfaceSize.height)
    return CGRect(
      x: max(0, (hostSize.width - surfaceSize.width) / 2),
      y: isFlipped ? 0 : max(0, hostSize.height - surfaceSize.height),
      width: min(hostSize.width, surfaceSize.width),
      height: boundedHeight
    )
  }

  static func hoverScreenRect(panelFrame: CGRect, surfaceSize: CGSize) -> CGRect {
    CGRect(
      x: panelFrame.midX - surfaceSize.width / 2,
      y: panelFrame.maxY - surfaceSize.height,
      width: surfaceSize.width,
      height: surfaceSize.height
    ).insetBy(dx: -hoverSlop, dy: -hoverSlop)
  }
}

@MainActor
final class NotchHostingView<Content: View>: NSHostingView<Content> {
  /// Adapted from Ping Island's Apache-2.0 bounded hosting view at
  /// commit c9148fc6a66a98f62dc1cac8fde415c2be9f2233.
  var interactiveRect: () -> CGRect = { .zero }
  var handlePointerDown: () -> Void = {}
  var handlePointerPresenceChange: (Bool) -> Void = { _ in }
  private var pointerTrackingArea: NSTrackingArea?

  override var isOpaque: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard interactiveRect().contains(point) else { return nil }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    handlePointerDown()
    super.mouseDown(with: event)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea {
      removeTrackingArea(pointerTrackingArea)
    }
    let rect = interactiveRect()
    guard !rect.isEmpty else {
      pointerTrackingArea = nil
      return
    }
    let trackingArea = NSTrackingArea(
      rect: rect,
      options: [.mouseEnteredAndExited, .activeAlways],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    pointerTrackingArea = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    handlePointerPresenceChange(true)
  }

  override func mouseExited(with event: NSEvent) {
    handlePointerPresenceChange(false)
  }

  func refreshPointerTrackingArea() {
    updateTrackingAreas()
  }

}
