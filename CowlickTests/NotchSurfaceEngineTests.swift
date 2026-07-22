import CoreGraphics
import XCTest

@testable import Cowlick

final class NotchSurfaceEngineTests: XCTestCase {
  func testInteractiveRectCentersSurfaceAtTopOfFlippedHostingView() {
    XCTAssertEqual(
      NotchSurfaceLayout.interactiveRect(
        hostSize: CGSize(width: 380, height: 208),
        surfaceSize: CGSize(width: 356, height: 38)
      ),
      CGRect(x: 12, y: 0, width: 356, height: 38)
    )
  }

  func testInteractiveRectSupportsUnflippedAppKitCoordinates() {
    XCTAssertEqual(
      NotchSurfaceLayout.interactiveRect(
        hostSize: CGSize(width: 380, height: 208),
        surfaceSize: CGSize(width: 356, height: 38),
        isFlipped: false
      ),
      CGRect(x: 12, y: 170, width: 356, height: 38)
    )
  }

  func testInteractiveRectClampsOversizedSurfaceToHost() {
    XCTAssertEqual(
      NotchSurfaceLayout.interactiveRect(
        hostSize: CGSize(width: 300, height: 120),
        surfaceSize: CGSize(width: 400, height: 180)
      ),
      CGRect(x: 0, y: 0, width: 300, height: 120)
    )
  }

  func testHostSizeFitsLargestAttachedApprovalSurface() {
    XCTAssertEqual(
      NotchTheme.hostSize(notchGapWidth: 212, safeAreaTop: 38),
      CGSize(width: 380, height: 208)
    )
  }

  func testOnlyCompactModeIsCollapsed() {
    XCTAssertFalse(NotchSurfaceMode.compact.isExpanded)
    XCTAssertTrue(NotchSurfaceMode.sessions.isExpanded)
    XCTAssertTrue(NotchSurfaceMode.approval.isExpanded)
  }
}
