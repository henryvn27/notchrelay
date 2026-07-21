import XCTest

@testable import Cowlick

final class NotchPullGesturePolicyTests: XCTestCase {
  func testSlowShortPullReturnsToRest() {
    XCTAssertFalse(NotchPullGesturePolicy.shouldExpand(distance: 20, predictedDistance: 24))
  }

  func testLongSlowPullExpands() {
    XCTAssertTrue(NotchPullGesturePolicy.shouldExpand(distance: 30, predictedDistance: 32))
  }

  func testShortFastFlickExpandsFromPredictedTravel() {
    XCTAssertTrue(NotchPullGesturePolicy.shouldExpand(distance: 12, predictedDistance: 56))
  }

  func testUpwardDragNeverExpands() {
    XCTAssertFalse(NotchPullGesturePolicy.shouldExpand(distance: -40, predictedDistance: -80))
  }

  func testResistanceBeginsAfterDirectTravel() {
    XCTAssertEqual(NotchPullGesturePolicy.resistedDistance(for: 20), 20)
    XCTAssertEqual(NotchPullGesturePolicy.resistedDistance(for: 44), 28.8, accuracy: 0.001)
  }

  func testProgressIsClamped() {
    XCTAssertEqual(NotchPullGesturePolicy.progress(for: -20), 0)
    XCTAssertEqual(NotchPullGesturePolicy.progress(for: 12), 0.5)
    XCTAssertEqual(NotchPullGesturePolicy.progress(for: 100), 1)
  }
}
