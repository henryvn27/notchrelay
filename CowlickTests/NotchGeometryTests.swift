import CoreGraphics
import XCTest

@testable import Cowlick

final class NotchGeometryTests: XCTestCase {
  func testNotchUsesAuxiliaryGapWithoutHardcodedWidth() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaTop: 38,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
        auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38),
        requestedContentSize: CGSize(width: 150, height: 32),
        displayID: 7,
        showOnNonNotch: true
      ))

    XCTAssertTrue(result.hasNotch)
    XCTAssertEqual(result.panelFrame.width, 212)
    XCTAssertEqual(result.panelFrame.maxY, 982)
    XCTAssertEqual(result.notchGapWidth, 212)
    XCTAssertEqual(result.safeAreaTop, 38)
  }

  func testAttachedCompactReservesVisibleWingsBesideCameraGap() {
    let size = NotchTheme.attachedSize(
      baseSize: NotchTheme.compactSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: false
    )

    XCTAssertEqual(size.width, 376)
    XCTAssertEqual(size.height, 38)
  }

  func testAttachedExpansionGrowsDownwardFromStableTopEdge() throws {
    let compactSize = NotchTheme.attachedSize(
      baseSize: NotchTheme.compactSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: false
    )
    let expandedSize = NotchTheme.attachedSize(
      baseSize: NotchTheme.approvalSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: true
    )
    let compact = try XCTUnwrap(resolveNotched(contentSize: compactSize))
    let expanded = try XCTUnwrap(resolveNotched(contentSize: expandedSize))

    XCTAssertEqual(compact.panelFrame.maxY, 982)
    XCTAssertEqual(expanded.panelFrame.maxY, compact.panelFrame.maxY)
    XCTAssertGreaterThanOrEqual(expanded.panelFrame.width, compact.panelFrame.width)
    XCTAssertLessThan(expanded.panelFrame.minY, compact.panelFrame.minY)
    XCTAssertEqual(expanded.panelFrame.height, 194)
  }

  func testNonNotchFallbackSitsBelowMenuBar() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
        safeAreaTop: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil,
        requestedContentSize: CGSize(width: 150, height: 32),
        displayID: 3,
        showOnNonNotch: true
      ))

    XCTAssertFalse(result.hasNotch)
    XCTAssertEqual(result.panelFrame.midX, 960)
    XCTAssertEqual(result.panelFrame.maxY, 1049)
  }

  func testNonNotchFallbackCanBeHidden() {
    let result = NotchGeometryResolver.resolve(
      screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      requestedContentSize: CGSize(width: 150, height: 32),
      displayID: 3,
      showOnNonNotch: false
    )
    XCTAssertNil(result)
  }

  func testPanelFrameMatchesRequestedContentOnExternalDisplay() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415),
        safeAreaTop: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil,
        requestedContentSize: CGSize(width: 380, height: 156),
        displayID: 9,
        showOnNonNotch: true
      ))
    XCTAssertEqual(result.panelFrame.size, CGSize(width: 380, height: 156))
    XCTAssertEqual(result.displayID, 9)
  }

  private func resolveNotched(contentSize: CGSize) -> ResolvedNotchGeometry? {
    NotchGeometryResolver.resolve(
      screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
      safeAreaTop: 38,
      auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
      auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38),
      requestedContentSize: contentSize,
      displayID: 7,
      showOnNonNotch: true
    )
  }
}
