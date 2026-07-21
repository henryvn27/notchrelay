import AppKit
import CoreGraphics
import SwiftUI
import XCTest

@testable import Cowlick

final class NotchGeometryTests: XCTestCase {
  @MainActor
  func testLongDistinctReasonAndOperationFitNotchAndNonNotchPanels() throws {
    let request = ApprovalRequest(
      id: UUID(),
      sessionID: "layout-test",
      turnID: "turn",
      chatTitle: "Ship the verified ActivityPilot release candidate after reviewing every check",
      projectName: "ActivityPilot",
      workingDirectory: "/tmp/ActivityPilot",
      toolName: "Bash",
      operationDescription: String(
        repeating: "Publish the verified release only after every required check succeeds. ",
        count: 4
      ),
      operationSummary: String(
        repeating: "git push --atomic origin release/product-acceptance ",
        count: 5
      ),
      fullOperation: "git push --atomic origin release/product-acceptance",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )
    let approvalSize = NotchTheme.approvalSize(for: request)
    let content = ApprovalView(
      request: request, isAttached: false, allow: {}, deny: {}, openCodex: {}
    )
    .frame(width: approvalSize.width)
    .background(Color.black)
    let hostingView = NSHostingView(rootView: content)
    let requiredHeight = ceil(hostingView.fittingSize.height)

    XCTAssertEqual(approvalSize, NotchTheme.maximumApprovalSize)
    XCTAssertLessThanOrEqual(requiredHeight, approvalSize.height)

    let attachedSize = NotchTheme.attachedSize(
      baseSize: approvalSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: true
    )
    XCTAssertEqual(attachedSize.width, approvalSize.width)
    XCTAssertEqual(
      attachedSize.height,
      approvalSize.height + 38
    )

    try attachPNG(
      of: content,
      size: approvalSize,
      name: "long-approval-non-notch"
    )
    try attachPNG(
      of:
        ApprovalView(
          request: request, isAttached: true, allow: {}, deny: {}, openCodex: {}
        )
        .padding(.top, 38)
        .frame(width: attachedSize.width, height: attachedSize.height, alignment: .top),
      size: attachedSize,
      name: "long-approval-simulated-notch"
    )
  }

  func testShortApprovalUsesAContentMatchedPanelHeight() {
    let request = ApprovalRequest(
      id: UUID(),
      sessionID: "layout-test",
      turnID: "turn",
      chatTitle: nil,
      projectName: "ActivityPilot",
      workingDirectory: "/tmp/ActivityPilot",
      toolName: "Bash",
      operationDescription: "Publish the verified branch",
      operationSummary: "git push origin main",
      fullOperation: "git push origin main",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )

    XCTAssertEqual(NotchTheme.approvalSize(for: request), CGSize(width: 380, height: 116))
  }

  func testApprovalPresentationNeverActivatesUntilUserInteracts() {
    XCTAssertFalse(
      NotchPanelInteractionPolicy.shouldActivate(isApproval: true, initiatedByUser: false))
    XCTAssertFalse(
      NotchPanelInteractionPolicy.shouldActivate(isApproval: false, initiatedByUser: true))
    XCTAssertTrue(
      NotchPanelInteractionPolicy.shouldActivate(isApproval: true, initiatedByUser: true))
  }

  func testApprovalAccessibilityAnnouncementContainsOnlyProjectAndTool() {
    let request = ApprovalRequest(
      id: UUID(),
      sessionID: "session",
      turnID: "turn",
      chatTitle: nil,
      projectName: "Scoutly",
      workingDirectory: "/private/work/Scoutly",
      toolName: "Bash",
      operationDescription: "Publish the private release",
      operationSummary: "secret-command --token private",
      fullOperation: "secret-command --token private",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )

    let announcement = ApprovalAccessibilityPresentation.announcement(for: request)
    XCTAssertEqual(announcement, "Approval requested for Scoutly, Bash")
    XCTAssertFalse(announcement.contains("private"))
    XCTAssertFalse(announcement.contains("secret-command"))
  }

  func testApprovalAccessibilityAnnouncementDisambiguatesChatWithProject() {
    let request = ApprovalRequest(
      id: UUID(),
      sessionID: "session",
      turnID: "turn",
      chatTitle: "Ship the release",
      projectName: "Scoutly",
      workingDirectory: "/private/work/Scoutly",
      toolName: "Bash",
      operationDescription: "Publish the private release",
      operationSummary: "secret-command --token private",
      fullOperation: "secret-command --token private",
      requestedAt: .now,
      expiresAt: .now.addingTimeInterval(60)
    )

    XCTAssertEqual(
      ApprovalAccessibilityPresentation.announcement(for: request),
      "Approval requested for Ship the release, Scoutly, Bash")
  }

  @MainActor
  func testCollapsedAccessibilityHintMatchesItsAction() {
    XCTAssertEqual(
      CollapsedIslandView.accessibilityHint(for: .completed(message: nil)),
      "Dismiss the completed status"
    )
    XCTAssertEqual(
      CollapsedIslandView.accessibilityHint(for: .working(prompt: nil)),
      "Expand the status island"
    )
    let session = AgentSession(
      id: "session",
      turnID: "turn",
      chatTitle: nil,
      projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly",
      model: nil,
      status: .working(prompt: nil),
      updatedAt: .now
    )
    XCTAssertEqual(
      CollapsedIslandView.accessibilityLabel(
        session: session, activeCount: 3, activeSubagentCount: 2),
      "Scoutly, Working, 3 active sessions, 2 active agents"
    )
  }

  func testNotchUsesAuxiliaryGapWithoutHardcodedWidth() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        safeAreaTop: 38,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
        auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38),
        requestedContentSize: CGSize(width: 150, height: 32),
        displayID: 7,
        showOnNonNotch: true
      ))

    XCTAssertTrue(result.hasNotch)
    XCTAssertEqual(result.panelFrame.width, 212)
    XCTAssertEqual(result.panelFrame.maxY, 982)
    XCTAssertEqual(result.notchGapWidth, 212)
    XCTAssertEqual(result.safeAreaTop, 38)
  }

  func testAttachedCompactReservesVisibleWingsBesideCameraGap() {
    let size = NotchTheme.attachedSize(
      baseSize: NotchTheme.compactSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: false
    )

    XCTAssertEqual(size.width, 356)
    XCTAssertEqual(size.height, 38)
  }

  func testAttachedExpansionGrowsDownwardFromStableTopEdge() throws {
    let compactSize = NotchTheme.attachedSize(
      baseSize: NotchTheme.compactSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: false
    )
    let expandedSize = NotchTheme.attachedSize(
      baseSize: NotchTheme.maximumApprovalSize,
      notchGapWidth: 212,
      safeAreaTop: 38,
      expanded: true
    )
    let compact = try XCTUnwrap(resolveNotched(contentSize: compactSize))
    let expanded = try XCTUnwrap(resolveNotched(contentSize: expandedSize))

    XCTAssertEqual(compact.panelFrame.maxY, 982)
    XCTAssertEqual(expanded.panelFrame.maxY, compact.panelFrame.maxY)
    XCTAssertGreaterThanOrEqual(expanded.panelFrame.width, compact.panelFrame.width)
    XCTAssertLessThan(expanded.panelFrame.minY, compact.panelFrame.minY)
    XCTAssertEqual(expanded.panelFrame.height, 208)
  }

  func testNonNotchFallbackSitsBelowMenuBar() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
        safeAreaTop: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil,
        requestedContentSize: CGSize(width: 150, height: 32),
        displayID: 3,
        showOnNonNotch: true
      ))

    XCTAssertFalse(result.hasNotch)
    XCTAssertEqual(result.panelFrame.midX, 960)
    XCTAssertEqual(result.panelFrame.maxY, 1049)
  }

  func testNonNotchFallbackCanBeHidden() {
    let result = NotchGeometryResolver.resolve(
      screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
      safeAreaTop: 0,
      auxiliaryTopLeftArea: nil,
      auxiliaryTopRightArea: nil,
      requestedContentSize: CGSize(width: 150, height: 32),
      displayID: 3,
      showOnNonNotch: false
    )
    XCTAssertNil(result)
  }

  func testPanelFrameMatchesRequestedContentOnExternalDisplay() throws {
    let result = try XCTUnwrap(
      NotchGeometryResolver.resolve(
        screenFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415),
        safeAreaTop: 0,
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil,
        requestedContentSize: NotchTheme.maximumApprovalSize,
        displayID: 9,
        showOnNonNotch: true
      ))
    XCTAssertEqual(result.panelFrame.size, NotchTheme.maximumApprovalSize)
    XCTAssertEqual(result.displayID, 9)
  }

  private func resolveNotched(contentSize: CGSize) -> ResolvedNotchGeometry? {
    NotchGeometryResolver.resolve(
      screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
      safeAreaTop: 38,
      auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 650, height: 38),
      auxiliaryTopRightArea: CGRect(x: 862, y: 944, width: 650, height: 38),
      requestedContentSize: contentSize,
      displayID: 7,
      showOnNonNotch: true
    )
  }

  @MainActor
  private func attachPNG<Content: View>(of content: Content, size: CGSize, name: String) throws {
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    let representation = try XCTUnwrap(
      hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(png.count, 1_000)

    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
