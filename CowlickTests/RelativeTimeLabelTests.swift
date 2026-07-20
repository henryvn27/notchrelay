import XCTest

@testable import Cowlick

@MainActor
final class RelativeTimeLabelTests: XCTestCase {
  func testFormatsNearSimultaneousDatesAsJustNow() {
    let referenceDate = Date(timeIntervalSince1970: 1_000_000)

    XCTAssertEqual(
      RelativeTimeLabel.string(
        for: referenceDate.addingTimeInterval(0.5),
        relativeTo: referenceDate
      ),
      "just now"
    )
    XCTAssertEqual(
      RelativeTimeLabel.string(
        for: referenceDate.addingTimeInterval(-4.9),
        relativeTo: referenceDate
      ),
      "just now"
    )
  }

  func testFormatsFutureAndPastRelativeToExplicitReferenceDate() {
    let referenceDate = Date(timeIntervalSince1970: 1_000_000)
    let locale = Locale(identifier: "en_US")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    XCTAssertEqual(
      RelativeTimeLabel.string(
        for: referenceDate.addingTimeInterval(2 * 60 * 60),
        relativeTo: referenceDate,
        locale: locale,
        calendar: calendar
      ),
      "in 2 hours"
    )
    XCTAssertEqual(
      RelativeTimeLabel.string(
        for: referenceDate.addingTimeInterval(-5 * 60),
        relativeTo: referenceDate,
        locale: locale,
        calendar: calendar
      ),
      "5 minutes ago"
    )
  }

  func testMenuPresentationClockRunsOnlyWhileVisible() {
    var refreshCount = 0
    let observer = MenuPresentationObserver.ObserverView(refreshInterval: 0.01) {
      refreshCount += 1
    }

    observer.updatePresentationVisibility(true)
    XCTAssertTrue(observer.hasActiveRefreshTimer)
    XCTAssertEqual(refreshCount, 1)

    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    XCTAssertGreaterThan(refreshCount, 1)

    observer.updatePresentationVisibility(false)
    XCTAssertFalse(observer.hasActiveRefreshTimer)
    let countAfterHiding = refreshCount

    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    XCTAssertEqual(refreshCount, countAfterHiding)
  }
}
