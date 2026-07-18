import XCTest

@testable import Cowlick

final class CodexHookTrustServiceTests: XCTestCase {
  private let cwd = "/Users/test/Developer/Cowlick"
  private let command = "'/Users/test/.local/bin/cowlick-hook' hook"

  func testReportsTrustedWhenAllCowlickHooksAreTrusted() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "managed", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .trusted)
    XCTAssertEqual(report.eventStatuses.count, 4)
  }

  func testReportsReviewRequiredForUntrustedHook() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "untrusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .needsReview)
  }

  func testReportsIncompleteWhenHookIsMissing() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .incomplete)
  }

  func testIgnoresForeignHookCommands() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: "'/usr/local/bin/other-hook' hook"
    )

    XCTAssertEqual(report.state, .incomplete)
    XCTAssertTrue(report.eventStatuses.isEmpty)
  }

  func testRejectsMalformedResponse() {
    XCTAssertThrowsError(
      try CodexHookTrustService.parseResponse(
        Data(#"{"id":7,"result":{}}"#.utf8),
        workingDirectory: cwd,
        expectedCommand: command
      ))
  }

  private func response(statuses: [String]) -> Data {
    let events = ["sessionStart", "userPromptSubmit", "permissionRequest", "stop"]
    let hooks = zip(events, statuses).map { event, status in
      """
      {"eventName":"\(event)","command":"\(command)","enabled":true,"trustStatus":"\(status)"}
      """
    }.joined(separator: ",")
    return Data(
      """
      {"id":2,"result":{"data":[{"cwd":"\(cwd)","hooks":[\(hooks)]}]}}
      """.utf8)
  }
}
