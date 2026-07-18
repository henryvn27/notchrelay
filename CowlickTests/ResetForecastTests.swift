import Foundation
import XCTest

@testable import Cowlick

final class ResetForecastTests: XCTestCase {
  func testParsesOnlyDisplayFields() throws {
    let data = Data(
      #"{"fetchedAt":"2026-07-18T12:00:00.123Z","nextRefreshAt":"2026-07-18T12:15:00Z","forecast":{"score":95,"resetAnnounced":false},"incidents":[{"private":"ignored"}],"history":[1,2,3]}"#
        .utf8)

    let forecast = try ResetForecastService.parseResponse(data)

    XCTAssertEqual(forecast.score, 95)
    XCTAssertFalse(forecast.resetAnnounced)
    XCTAssertNotNil(forecast.fetchedAt)
    XCTAssertNotNil(forecast.nextRefreshAt)
    XCTAssertEqual(forecast.scoreLabel, "95% in the next 48 hours")
  }

  func testClampsThirdPartyScore() throws {
    let data = Data(#"{"forecast":{"score":410,"resetAnnounced":true}}"#.utf8)
    let forecast = try ResetForecastService.parseResponse(data)
    XCTAssertEqual(forecast.score, 100)
    XCTAssertEqual(forecast.scoreLabel, "100% in the next 48 hours")
  }

  func testRejectsMalformedForecast() {
    XCTAssertThrowsError(
      try ResetForecastService.parseResponse(Data(#"{"forecast":{"score":"high"}}"#.utf8)))
  }

  func testResponseLimitIsHalfMegabyte() {
    XCTAssertEqual(ResetForecastService.maximumResponseSize, 524_288)
  }
}
