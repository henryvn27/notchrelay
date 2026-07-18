import XCTest

final class UpdateConfigurationTests: XCTestCase {
  func testUpdateConfigurationRequiresSignedFeedAndPreExtractionVerification() {
    let info = Bundle.main.infoDictionary
    XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
    XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    XCTAssertFalse((info?["SUPublicEDKey"] as? String ?? "").isEmpty)
    XCTAssertEqual(
      info?["SUFeedURL"] as? String,
      "https://github.com/henryvn27/cowlick/releases/latest/download/appcast.xml")
  }
}
