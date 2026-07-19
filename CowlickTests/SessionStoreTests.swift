import XCTest

@testable import Cowlick

@MainActor
final class SessionStoreTests: XCTestCase {
  func testPriorityApprovalFailureWorkingCompletedIdle() {
    XCTAssertGreaterThan(
      AgentStatus.awaitingApproval(sampleApproval()).priority,
      AgentStatus.failed(message: nil).priority)
    XCTAssertGreaterThan(
      AgentStatus.failed(message: nil).priority, AgentStatus.working(prompt: nil).priority)
    XCTAssertGreaterThan(
      AgentStatus.working(prompt: nil).priority, AgentStatus.completed(message: nil).priority)
    XCTAssertGreaterThan(AgentStatus.completed(message: nil).priority, AgentStatus.idle.priority)
  }

  func testMultipleWorkingSessionsAndPriority() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "a", cwd: "/tmp/Scoutly"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .working, sessionID: "b", cwd: "/tmp/ActivityPilot",
        timestamp: Date().addingTimeInterval(1)))

    XCTAssertEqual(store.activeSessionCount, 2)
    XCTAssertEqual(store.displaySession?.id, "b")
    XCTAssertEqual(store.sessionSummaries.count, 2)
  }

  func testApprovalQueueOrderingAndExactRequestMatching() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    let firstID = UUID()
    let secondID = UUID()
    let now = Date()
    let first = makeBridgeEvent(
      event: .approvalRequested, requestID: firstID, sessionID: "one", timestamp: now,
      toolName: "Bash", toolInput: .object(["command": .string("git push")]))
    let second = makeBridgeEvent(
      event: .approvalRequested, requestID: secondID, sessionID: "two",
      timestamp: now.addingTimeInterval(0.01), toolName: "ApplyPatch",
      toolInput: .object(["path": .string("README.md")]))

    let firstTask = Task { await store.receive(first) }
    let firstQueued = await waitUntil { store.approvalQueue.count == 1 }
    XCTAssertTrue(firstQueued)
    let secondTask = Task { await store.receive(second) }
    let bothQueued = await waitUntil { store.approvalQueue.count == 2 }
    XCTAssertTrue(bothQueued)

    XCTAssertEqual(store.currentApproval?.id, firstID)
    XCTAssertFalse(store.decide(requestID: secondID, decision: .allow))
    XCTAssertTrue(store.decide(requestID: firstID, decision: .deny))
    let firstDecision = await firstTask.value
    XCTAssertEqual(firstDecision, .deny)
    let secondBecameCurrent = await waitUntil { store.currentApproval?.id == secondID }
    XCTAssertTrue(secondBecameCurrent)
    XCTAssertTrue(store.decide(requestID: secondID, decision: .allow))
    let secondDecision = await secondTask.value
    XCTAssertEqual(secondDecision, .allow)
    XCTAssertTrue(store.approvalQueue.isEmpty)
  }

  func testApprovalKeepsHumanReasonSeparateFromOperation() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      toolName: "Bash",
      toolInput: .object([
        "command": .string("git push origin main"),
        "description": .string("Publish the verified branch"),
      ]))

    let task = Task { await store.receive(event) }
    let approvalQueued = await waitUntil { store.currentApproval != nil }
    XCTAssertTrue(approvalQueued)
    XCTAssertEqual(store.currentApproval?.reasonPreview, "Publish the verified branch")
    XCTAssertEqual(store.currentApproval?.operationPreview, "git push origin main")
    XCTAssertTrue(store.currentApproval?.showsDistinctOperation == true)
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    _ = await task.value
  }

  func testApprovalWithoutToolInputDoesNotInventOperation() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      toolName: "Codex tool",
      description: "Review this permission")

    let task = Task { await store.receive(event) }
    let approvalQueued = await waitUntil { store.currentApproval != nil }
    XCTAssertTrue(approvalQueued)
    XCTAssertEqual(store.currentApproval?.reasonPreview, "Review this permission")
    XCTAssertEqual(store.currentApproval?.operationPreview, "")
    XCTAssertFalse(store.currentApproval?.showsDistinctOperation == true)
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    _ = await task.value
  }

  func testExpiredApprovalDefersWithoutQueueing() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 5
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      timestamp: Date().addingTimeInterval(-10),
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )

    let decision = await store.receive(event)
    XCTAssertEqual(decision, .deferDecision)
    XCTAssertTrue(store.approvalQueue.isEmpty)
  }

  func testApprovalTimeoutDoesNotLeaveAnActiveSession() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 0.05
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )

    let decision = await store.receive(event)

    XCTAssertEqual(decision, .deferDecision)
    XCTAssertEqual(store.activeSessionCount, 0)
    XCTAssertNil(store.displaySession)
    XCTAssertTrue(store.approvalQueue.isEmpty)
  }

  func testLocalApprovalDemoClearsAfterDecision() {
    let store = SessionStore(settings: makeTestSettings())
    store.testState(.approvalRequested)
    let requestID = store.currentApproval!.id

    XCTAssertTrue(store.decide(requestID: requestID, decision: .allow))
    XCTAssertEqual(store.activeSessionCount, 0)
    XCTAssertNil(store.displaySession)
    XCTAssertTrue(store.approvalQueue.isEmpty)
  }

  func testEveryPreviewActionPreservesLivePendingApprovalAndSession() async {
    let previews: [(String, (SessionStore) -> Void)] = [
      ("Working", { $0.testState(.working) }),
      ("Approval", { $0.testState(.approvalRequested) }),
      ("Completed", { $0.testState(.completed) }),
      ("Failed", { $0.testState(.failed) }),
      ("Multiple Sessions", { $0.testMultipleSessions() }),
    ]

    for (name, preview) in previews {
      let settings = makeTestSettings()
      settings.approvalTimeout = 10
      let store = SessionStore(settings: settings)
      let requestID = UUID()
      let event = makeBridgeEvent(
        event: .approvalRequested,
        requestID: requestID,
        sessionID: "live-approval",
        toolName: "Bash",
        toolInput: .object(["command": .string("git push")])
      )
      let decisionTask = Task { await store.receive(event) }
      let queued = await waitUntil { store.currentApproval?.id == requestID }
      XCTAssertTrue(queued, name)
      guard let liveSession = store.sessions[event.sessionId] else {
        decisionTask.cancel()
        return XCTFail("Expected live session before \(name) preview")
      }

      preview(store)

      XCTAssertEqual(store.approvalQueue.map(\.id), [requestID], name)
      XCTAssertEqual(store.sessions[event.sessionId], liveSession, name)
      XCTAssertEqual(store.sessions.count, 1, name)
      XCTAssertTrue(store.decide(requestID: requestID, decision: .allow), name)
      let decision = await decisionTask.value
      XCTAssertEqual(decision, .allow, name)
    }
  }

  func testEveryPreviewActionPreservesLiveWorkingSession() async {
    let previews: [(String, (SessionStore) -> Void)] = [
      ("Working", { $0.testState(.working) }),
      ("Approval", { $0.testState(.approvalRequested) }),
      ("Completed", { $0.testState(.completed) }),
      ("Failed", { $0.testState(.failed) }),
      ("Multiple Sessions", { $0.testMultipleSessions() }),
    ]

    for (name, preview) in previews {
      let store = SessionStore(settings: makeTestSettings())
      _ = await store.receive(
        makeBridgeEvent(event: .working, sessionID: "live-working", prompt: "Ship Cowlick"))
      let liveSession = store.sessions["live-working"]

      preview(store)

      XCTAssertEqual(store.sessions["live-working"], liveSession, name)
      XCTAssertEqual(store.sessions.count, 1, name)
      XCTAssertTrue(store.approvalQueue.isEmpty, name)
    }
  }

  func testLiveApprovalClearsOnlyLocallyOwnedDemoState() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    _ = await store.receive(
      makeBridgeEvent(event: .failed, sessionID: "existing-failure", error: "Build failed"))
    let existingSession = store.sessions["existing-failure"]
    store.testState(.approvalRequested)
    let demoRequestID = store.currentApproval?.id
    let liveRequestID = UUID()
    let event = makeBridgeEvent(
      event: .approvalRequested,
      requestID: liveRequestID,
      sessionID: "live-approval",
      toolName: "Bash"
    )

    let decisionTask = Task { await store.receive(event) }
    let queued = await waitUntil { store.currentApproval?.id == liveRequestID }

    XCTAssertTrue(queued)
    XCTAssertFalse(store.approvalQueue.contains { $0.id == demoRequestID })
    XCTAssertEqual(store.approvalQueue.map(\.id), [liveRequestID])
    XCTAssertEqual(store.sessions["existing-failure"], existingSession)
    XCTAssertNil(store.sessions["demo-visual-state"])
    XCTAssertTrue(store.decide(requestID: liveRequestID, decision: .deny))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .deny)
  }

  func testDuplicateApprovalRequestIDDefersWithoutAliasingDecision() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    let requestID = UUID()
    let first = makeBridgeEvent(
      event: .approvalRequested, requestID: requestID, sessionID: "first", toolName: "Bash")
    let duplicate = makeBridgeEvent(
      event: .approvalRequested, requestID: requestID, sessionID: "second",
      timestamp: Date().addingTimeInterval(0.01), toolName: "ApplyPatch")

    let firstTask = Task { await store.receive(first) }
    let firstQueued = await waitUntil { store.currentApproval?.id == requestID }
    XCTAssertTrue(firstQueued)
    let duplicateDecision = await store.receive(duplicate)

    XCTAssertEqual(duplicateDecision, .deferDecision)
    XCTAssertEqual(store.approvalQueue.count, 1)
    XCTAssertEqual(store.currentApproval?.sessionID, "first")
    XCTAssertTrue(store.decide(requestID: requestID, decision: .allow))
    let firstDecision = await firstTask.value
    XCTAssertEqual(firstDecision, .allow)
  }

  func testCompletionVisibilityAndResultPrivacy() async {
    let settings = makeTestSettings()
    settings.showResultPreviews = false
    settings.completionVisibility = .twoSeconds
    let store = SessionStore(settings: settings)
    _ = await store.receive(makeBridgeEvent(event: .completed, result: "private result"))

    guard case .completed(let message)? = store.sessions["session-1"]?.status else {
      return XCTFail("Expected completion")
    }
    XCTAssertNil(message)
    XCTAssertNotNil(store.displaySession)
    store.dismissCompletion(sessionID: "session-1")
    XCTAssertNil(store.displaySession)
  }

  func testCompletionResultPreviewIsStoredAndRenderedWhenEnabled() async {
    let settings = makeTestSettings()
    settings.showResultPreviews = true
    let store = SessionStore(settings: settings)
    _ = await store.receive(
      makeBridgeEvent(event: .completed, result: "Release verification passed"))

    guard let session = store.sessions["session-1"] else {
      return XCTFail("Expected completed session")
    }
    XCTAssertEqual(
      SessionListView.secondaryText(
        for: session,
        showPromptPreviews: false,
        showResultPreviews: true),
      "Release verification passed"
    )
    XCTAssertEqual(
      SessionListView.accessibilityLabel(
        for: session,
        showPromptPreviews: false,
        showResultPreviews: true),
      "Scoutly, Completed, Release verification passed"
    )
    XCTAssertEqual(
      SessionListView.secondaryText(
        for: session,
        showPromptPreviews: false,
        showResultPreviews: false),
      "Completed"
    )
    XCTAssertEqual(
      SessionListView.accessibilityLabel(
        for: session,
        showPromptPreviews: false,
        showResultPreviews: false),
      "Scoutly, Completed"
    )
  }

  func testCompletionAutomaticallyExpiresObservedState() async throws {
    let settings = makeTestSettings()
    settings.completionVisibility = .twoSeconds
    let store = SessionStore(settings: settings)
    _ = await store.receive(makeBridgeEvent(event: .completed))

    XCTAssertNotNil(store.displaySession)
    try await Task.sleep(for: .seconds(2.2))

    XCTAssertNil(store.displaySession)
    XCTAssertEqual(store.sessions["session-1"]?.completionVisibleUntil, .distantPast)
  }

  func testFailureOutranksWorking() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "working"))
    _ = await store.receive(
      makeBridgeEvent(event: .failed, sessionID: "failed", error: "Build failed"))
    XCTAssertEqual(store.displaySession?.id, "failed")
    XCTAssertEqual(store.activeSessionCount, 1)
  }

  func testFailureRemainsVisibleWithoutCountingAsActive() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(event: .failed, sessionID: "failed", error: "Build failed"))

    XCTAssertEqual(store.displaySession?.id, "failed")
    XCTAssertEqual(store.activeSessionCount, 0)
  }

  func testPromptPreviewRemainsDisabledByDefault() async {
    let settings = makeTestSettings()
    XCTAssertFalse(settings.showPromptPreviews)
    let store = SessionStore(settings: settings)
    _ = await store.receive(makeBridgeEvent(event: .working, prompt: "private prompt"))
    XCTAssertFalse(store.settings.showPromptPreviews)
  }

  private func sampleApproval() -> ApprovalRequest {
    ApprovalRequest(
      id: UUID(), sessionID: "s", turnID: "t", projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly", toolName: "Bash",
      operationDescription: "Run the project test suite", operationSummary: "swift test",
      fullOperation: "swift test",
      requestedAt: Date(), expiresAt: Date().addingTimeInterval(60)
    )
  }
}
