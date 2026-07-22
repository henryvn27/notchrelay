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

  func testOnlyCompactModeIsCollapsed() {
    XCTAssertFalse(NotchSurfaceMode.compact.isExpanded)
    XCTAssertTrue(NotchSurfaceMode.sessions.isExpanded)
    XCTAssertTrue(NotchSurfaceMode.approval.isExpanded)
  }

  func testHoverScreenRectIncludesThePhysicalTopScreenEdge() {
    let hoverRect = NotchSurfaceLayout.hoverScreenRect(
      panelFrame: CGRect(x: 602, y: 860, width: 308, height: 122),
      surfaceSize: CGSize(width: 308, height: 122)
    )

    XCTAssertTrue(hoverRect.contains(CGPoint(x: 625, y: 982)))
    XCTAssertFalse(hoverRect.contains(CGPoint(x: 250, y: 450)))
  }
}
