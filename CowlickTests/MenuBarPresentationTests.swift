import XCTest

@testable import Cowlick

@MainActor
final class MenuBarPresentationTests: XCTestCase {
  func testMenuBarArtworkIsAnAdaptiveTemplateWithVisibleAndTransparentPixels() throws {
    let image = CowlickMenuBarArtwork.templateImage()
    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

    let data = try XCTUnwrap(image.tiffRepresentation)
    let representation = try XCTUnwrap(NSBitmapImageRep(data: data))
    var visiblePixelCount = 0
    var transparentPixelCount = 0
    for x in 0..<representation.pixelsWide {
      for y in 0..<representation.pixelsHigh {
        let alpha = representation.colorAt(x: x, y: y)?.alphaComponent ?? 0
        if alpha > 0.1 {
          visiblePixelCount += 1
        } else {
          transparentPixelCount += 1
        }
      }
    }
    XCTAssertGreaterThan(visiblePixelCount, 0)
    XCTAssertGreaterThan(transparentPixelCount, 0)
  }

  func testMenuBarDetailHeightLeavesFixedActionsVisible() {
    XCTAssertEqual(CowlickMenuBarLayout.maximumDetailHeight(visibleScreenHeight: 1_080), 480)
    XCTAssertEqual(CowlickMenuBarLayout.maximumDetailHeight(visibleScreenHeight: 648), 328)
    XCTAssertEqual(CowlickMenuBarLayout.maximumDetailHeight(visibleScreenHeight: 400), 80)
    XCTAssertEqual(CowlickMenuBarLayout.maximumDetailHeight(visibleScreenHeight: 300), 0)
  }

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

  func testLiveStateOutranksHookReview() {
    let states: [(AgentStatus, String)] = [
      (.awaitingApproval(approvalRequest), "Approval needed"),
      (.failed(message: nil), "Failed"),
      (.working(prompt: nil), "Working"),
      (.completed(message: nil), "Completed"),
    ]

    for (status, title) in states {
      XCTAssertEqual(
        MenuBarContentView.headerTitle(status: status, trustState: .needsReview),
        title
      )
    }
  }

  func testActiveSessionCountOutranksHookReview() {
    XCTAssertEqual(
      MenuBarContentView.activitySummary(activeSessionCount: 1, trustState: .needsReview),
      "1 active session"
    )
    XCTAssertEqual(
      MenuBarContentView.activitySummary(activeSessionCount: 3, trustState: .incomplete),
      "3 active sessions"
    )
    XCTAssertEqual(
      MenuBarContentView.activitySummary(
        activeSessionCount: 1, activeSubagentCount: 2, trustState: .needsReview),
      "1 active session · 2 agents"
    )
  }

  func testIdleStateRetainsIntegrationWarnings() {
    XCTAssertEqual(
      MenuBarContentView.headerTitle(status: nil, trustState: .needsReview),
      "Codex review required"
    )
    XCTAssertEqual(
      MenuBarContentView.activitySummary(activeSessionCount: 0, trustState: .needsReview),
      "Review Cowlick in Codex CLI /hooks"
    )
    XCTAssertEqual(
      MenuBarContentView.headerTitle(status: .idle, trustState: .incomplete),
      "Integration needs repair"
    )
    XCTAssertEqual(
      MenuBarContentView.activitySummary(activeSessionCount: 0, trustState: .incomplete),
      "Open Settings to repair integration"
    )
  }

  func testTrustedIntegrationKeepsLiveSessionHeadline() {
    XCTAssertEqual(
      MenuBarContentView.headerTitle(
        status: .working(prompt: nil),
        trustState: .trusted
      ),
      "Working"
    )
    XCTAssertEqual(
      MenuBarContentView.activitySummary(
        activeSessionCount: 2,
        trustState: .trusted
      ),
      "2 active sessions"
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
      chatTitle: nil,
      projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly",
      toolName: "Shell",
      operationDescription: "Run the project test suite",
      operationSummary: "swift test",
      fullOperation: "swift test",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )
  }
}
