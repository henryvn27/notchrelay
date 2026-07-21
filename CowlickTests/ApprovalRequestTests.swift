import XCTest

@testable import Cowlick

final class ApprovalRequestTests: XCTestCase {
  func testHumanReasonAndOperationRemainDistinct() {
    let request = makeRequest(
      reason: "Publish the verified branch",
      operation: "git push origin release/product-acceptance")

    XCTAssertEqual(request.reasonPreview, "Publish the verified branch")
    XCTAssertEqual(request.operationPreview, "git push origin release/product-acceptance")
    XCTAssertTrue(request.showsDistinctOperation)
  }

  func testOperationPreviewCollapsesWhitespaceAndTruncates() {
    let request = makeRequest(
      reason: "Inspect output", operation: String(repeating: "x ", count: 120))

    XCTAssertFalse(request.operationPreview.contains("\n"))
    XCTAssertLessThanOrEqual(request.operationPreview.count, 180)
    XCTAssertTrue(request.operationPreview.hasSuffix("…"))
  }

  func testMissingOperationDoesNotInventASecondPreview() {
    let request = makeRequest(reason: "Review this permission", operation: "")

    XCTAssertEqual(request.reasonPreview, "Review this permission")
    XCTAssertEqual(request.operationPreview, "")
    XCTAssertFalse(request.showsDistinctOperation)
  }

  func testGlanceablePreviewsRedactCredentialsButCopyValueRemainsComplete() {
    let secret = "sk-sensitive-value"
    let operation = "curl -H 'Authorization: Bearer \(secret)' https://example.com"
    let request = makeRequest(reason: "Use token=\(secret)", operation: operation)

    XCTAssertFalse(request.reasonPreview.contains(secret))
    XCTAssertFalse(request.operationPreview.contains(secret))
    XCTAssertTrue(request.reasonPreview.contains("<redacted>"))
    XCTAssertEqual(request.fullOperation, operation)
  }

  private func makeRequest(reason: String, operation: String) -> ApprovalRequest {
    ApprovalRequest(
      id: UUID(),
      sessionID: "session",
      turnID: "turn",
      projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly",
      toolName: "Shell",
      operationDescription: reason,
      operationSummary: operation,
      fullOperation: operation,
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )
  }
}
