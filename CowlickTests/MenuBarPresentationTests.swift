import XCTest

@testable import Cowlick

final class MenuBarPresentationTests: XCTestCase {
  func testIconAndDetailsShowsOnlyMultipleSessionCounts() {
    XCTAssertEqual(
      resolve(.iconAndDetails, activeSessionCount: 1, percentageText: "64%"),
      MenuBarLabelContent(icon: .app, text: "64%")
    )
    XCTAssertEqual(
      resolve(.iconAndDetails, activeSessionCount: 3, percentageText: "64%"),
      MenuBarLabelContent(icon: .app, text: "3 · 64%")
    )
  }

  func testPercentageOnlyFallsBackToClickableAppIcon() {
    XCTAssertEqual(
      resolve(.percentageOnly, percentageText: "64%"),
      MenuBarLabelContent(icon: .none, text: "64%")
    )
    XCTAssertEqual(
      resolve(.percentageOnly, percentageText: nil),
      MenuBarLabelContent(icon: .app, text: nil)
    )
  }

  func testIconAndStatusModesResolveExpectedContent() {
    XCTAssertEqual(
      resolve(.iconOnly, status: .working(prompt: nil), percentageText: "64%"),
      MenuBarLabelContent(icon: .app, text: nil)
    )
    XCTAssertEqual(
      resolve(.statusOnly, status: .working(prompt: nil), percentageText: "64%"),
      MenuBarLabelContent(icon: .status("waveform.path"), text: nil)
    )
    XCTAssertEqual(
      resolve(.statusOnly, status: .awaitingApproval(approvalRequest)),
      MenuBarLabelContent(icon: .status("exclamationmark.shield.fill"), text: nil)
    )
    XCTAssertEqual(
      resolve(.statusOnly, status: .completed(message: nil)),
      MenuBarLabelContent(icon: .status("checkmark.circle.fill"), text: nil)
    )
    XCTAssertEqual(
      resolve(.statusAndPercentage, status: .failed(message: nil), percentageText: "64%"),
      MenuBarLabelContent(icon: .status("xmark.circle.fill"), text: "64%")
    )
    XCTAssertEqual(
      resolve(.statusOnly),
      MenuBarLabelContent(icon: .app, text: nil)
    )
    XCTAssertEqual(
      resolve(.statusAndPercentage, percentageText: "64%"),
      MenuBarLabelContent(icon: .app, text: "64%")
    )
  }

  private func resolve(
    _ presentation: MenuBarPresentation,
    status: AgentStatus? = nil,
    activeSessionCount: Int = 0,
    percentageText: String? = nil
  ) -> MenuBarLabelContent {
    MenuBarLabelContent.resolve(
      presentation: presentation,
      status: status,
      activeSessionCount: activeSessionCount,
      percentageText: percentageText
    )
  }

  private var approvalRequest: ApprovalRequest {
    ApprovalRequest(
      id: UUID(),
      sessionID: "session-1",
      turnID: "turn-1",
      projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly",
      toolName: "Shell",
      operationDescription: "Run tests",
      fullOperation: "swift test",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )
  }
}
