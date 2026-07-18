import XCTest

@testable import Cowlick

@MainActor
final class DiagnosticsTests: XCTestCase {
  func testSanitizesPathsAndSecrets() {
    let input = "failed /Users/example/private token=abc123 password:letmein"
    let output = EventLogger.sanitizeError(input)
    XCTAssertFalse(output.contains("example"))
    XCTAssertFalse(output.contains("abc123"))
    XCTAssertFalse(output.contains("letmein"))
    XCTAssertTrue(output.contains("token=<redacted>"))
  }

  func testSanitizesJSONKeysBearerCredentialsAndProjectControlCharacters() {
    let input =
      #"Authorization: Bearer sk-live-secret x-api-key="abc123" auth_token='def456'"#
    let output = EventLogger.sanitizeError(input)

    XCTAssertFalse(output.contains("sk-live-secret"))
    XCTAssertFalse(output.contains("abc123"))
    XCTAssertFalse(output.contains("def456"))
    XCTAssertFalse(EventLogger.sanitizeProject("Project\nInjected").contains("\n"))
  }

  func testKeepsOnlyTenSanitizedEvents() {
    let logger = EventLogger()
    for index in 0..<12 {
      logger.record(event: .working, project: "/Users/person/Project\(index)")
    }
    XCTAssertEqual(logger.recentEvents.count, 10)
    XCTAssertEqual(logger.recentEvents.last?.project, "Project11")
    XCTAssertFalse(logger.recentEvents.contains { $0.project.contains("/Users/") })
  }
}
