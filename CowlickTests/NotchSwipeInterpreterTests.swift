import XCTest
@testable import Cowlick

final class NotchSwipeInterpreterTests: XCTestCase {
  func testDownwardMovementExpandsAtThreshold() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: 5, horizontalDelta: 0, isMomentum: false))
    XCTAssertEqual(
      interpreter.interpret(
        phase: .changed, verticalDelta: 7, horizontalDelta: 1, isMomentum: false),
      .expand
    )
  }

  func testUpwardMovementCollapsesAtThreshold() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: -4, horizontalDelta: 0, isMomentum: false))
    XCTAssertEqual(
      interpreter.interpret(
        phase: .changed, verticalDelta: -8, horizontalDelta: 0, isMomentum: false),
      .collapse
    )
  }

  func testSubthresholdAndDirectionReversalDoNotTrigger() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: 7, horizontalDelta: 0, isMomentum: false))
    XCTAssertNil(
      interpreter.interpret(
        phase: .changed, verticalDelta: -7, horizontalDelta: 0, isMomentum: false))
    XCTAssertEqual(interpreter.accumulatedVertical, 0)
  }

  func testHorizontalDominantGestureIsRejectedUntilReset() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: 2, horizontalDelta: 8, isMomentum: false))
    XCTAssertNil(
      interpreter.interpret(
        phase: .changed, verticalDelta: 20, horizontalDelta: 0, isMomentum: false))
    XCTAssertFalse(interpreter.hasTriggered)
  }

  func testInitialDiagonalJitterAllowsLaterDeliberateVerticalSwipe() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: 1, horizontalDelta: 2, isMomentum: false))
    XCTAssertNil(
      interpreter.interpret(
        phase: .changed, verticalDelta: 4, horizontalDelta: 1, isMomentum: false))
    XCTAssertEqual(
      interpreter.interpret(
        phase: .changed, verticalDelta: 7, horizontalDelta: 0, isMomentum: false),
      .expand
    )
  }

  func testHorizontalIntentRemainsLockedAfterClearDominance() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .began, verticalDelta: 1, horizontalDelta: 6, isMomentum: false))
    XCTAssertNil(
      interpreter.interpret(
        phase: .changed, verticalDelta: 20, horizontalDelta: 0, isMomentum: false))
    XCTAssertFalse(interpreter.hasTriggered)
  }

  func testGestureTriggersOnlyOnce() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertEqual(
      interpreter.interpret(
        phase: .began, verticalDelta: 12, horizontalDelta: 0, isMomentum: false),
      .expand
    )
    XCTAssertNil(
      interpreter.interpret(
        phase: .changed, verticalDelta: -30, horizontalDelta: 0, isMomentum: false))
  }

  func testMomentumNeverTriggers() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertNil(
      interpreter.interpret(
        phase: .none, verticalDelta: 30, horizontalDelta: 0, isMomentum: true))
    XCTAssertFalse(interpreter.hasTriggered)
    XCTAssertEqual(interpreter.accumulatedVertical, 0)
  }

  func testEndedGestureResetsForNextGesture() {
    var interpreter = NotchSwipeInterpreter()

    XCTAssertEqual(
      interpreter.interpret(
        phase: .began, verticalDelta: 12, horizontalDelta: 0, isMomentum: false),
      .expand
    )
    XCTAssertNil(
      interpreter.interpret(
        phase: .ended, verticalDelta: 0, horizontalDelta: 0, isMomentum: false))
    XCTAssertEqual(
      interpreter.interpret(
        phase: .began, verticalDelta: -12, horizontalDelta: 0, isMomentum: false),
      .collapse
    )
  }

  func testVerticalDirectionNormalizationWithoutNaturalScrolling() {
    XCTAssertEqual(
      NotchSwipeEventNormalizer.verticalDelta(
        reportedDelta: -6,
        directionInvertedFromDevice: false
      ),
      6
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.verticalDelta(
        reportedDelta: 6,
        directionInvertedFromDevice: false
      ),
      -6
    )
  }

  func testVerticalDirectionNormalizationWithNaturalScrolling() {
    XCTAssertEqual(
      NotchSwipeEventNormalizer.verticalDelta(
        reportedDelta: 6,
        directionInvertedFromDevice: true
      ),
      6
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.verticalDelta(
        reportedDelta: -6,
        directionInvertedFromDevice: true
      ),
      -6
    )
  }

  func testHorizontalDirectionNormalizationCompensatesForPreference() {
    XCTAssertEqual(
      NotchSwipeEventNormalizer.horizontalDelta(
        reportedDelta: 5,
        directionInvertedFromDevice: false
      ),
      5
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.horizontalDelta(
        reportedDelta: -5,
        directionInvertedFromDevice: true
      ),
      5
    )
  }

  func testPhaseNormalization() {
    XCTAssertEqual(
      NotchSwipeEventNormalizer.phase(
        began: true, changed: false, ended: false, cancelled: false),
      .began
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.phase(
        began: false, changed: true, ended: false, cancelled: false),
      .changed
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.phase(
        began: false, changed: false, ended: true, cancelled: false),
      .ended
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.phase(
        began: false, changed: false, ended: false, cancelled: true),
      .cancelled
    )
    XCTAssertEqual(
      NotchSwipeEventNormalizer.phase(
        began: false, changed: false, ended: false, cancelled: false),
      .none
    )
  }
}
