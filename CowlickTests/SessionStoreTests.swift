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
      operationDescription: "Run tests", fullOperation: "swift test",
      requestedAt: Date(), expiresAt: Date().addingTimeInterval(60)
    )
  }
}
