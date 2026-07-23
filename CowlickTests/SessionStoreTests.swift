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

  func testPinnedOnlyPreferenceFiltersRowsCountsAndPrimarySession() async {
    let settings = makeTestSettings()
    settings.showOnlyPinnedSessions = true
    let store = SessionStore(
      settings: settings,
      resolvePinnedThreadIDs: { ["a"] }
    )
    await store.refreshPinnedThreadIDs()
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "a"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .working, sessionID: "b", timestamp: Date().addingTimeInterval(1)))

    XCTAssertEqual(store.activeSessionCount, 1)
    XCTAssertEqual(store.displaySession?.id, "a")
    XCTAssertEqual(store.sessionSummaries.map(\.id), ["a"])
  }

  func testPinnedOnlyPreferenceFailsOpenWhenCodexPinStateIsUnavailable() async {
    let settings = makeTestSettings()
    settings.showOnlyPinnedSessions = true
    let store = SessionStore(settings: settings, resolvePinnedThreadIDs: { nil })
    await store.refreshPinnedThreadIDs()
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "a"))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "b"))

    XCTAssertEqual(store.activeSessionCount, 2)
    XCTAssertEqual(Set(store.sessionSummaries.map(\.id)), Set(["a", "b"]))
  }

  func testPinnedOnlyPreferenceFailsOpenWhenCachedPinStateBecomesUnavailable() async {
    let settings = makeTestSettings()
    settings.showOnlyPinnedSessions = true
    let pins = LockedPinnedThreadIDs(["a"])
    let store = SessionStore(settings: settings, resolvePinnedThreadIDs: { pins.value })
    await store.refreshPinnedThreadIDs()
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "a"))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: "b"))
    XCTAssertEqual(store.activeSessionCount, 1)

    pins.value = nil
    await store.refreshPinnedThreadIDs()

    XCTAssertEqual(store.activeSessionCount, 2)
    XCTAssertEqual(Set(store.sessionSummaries.map(\.id)), Set(["a", "b"]))
  }

  func testPinnedOnlyPreferenceNeverHidesAnApprovalRequest() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    settings.autoExpandApprovals = false
    settings.showOnlyPinnedSessions = true
    let store = SessionStore(settings: settings, resolvePinnedThreadIDs: { [] })
    await store.refreshPinnedThreadIDs()
    let event = makeBridgeEvent(
      event: .approvalRequested,
      sessionID: "unpinned",
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )

    let decisionTask = Task { await store.receive(event) }
    let approvalBecameVisible = await waitUntil { store.currentApproval != nil }
    XCTAssertTrue(approvalBecameVisible)
    XCTAssertEqual(store.displaySession?.id, "unpinned")
    XCTAssertEqual(store.sessionSummaries.map(\.id), ["unpinned"])
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .deny)
  }

  func testSubagentsRemainChildActivityWithoutInflatingSessionCount() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "code-reviewer"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-2", agentType: "worker"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-2", agentType: "worker"))

    XCTAssertEqual(store.activeSessionCount, 1)
    XCTAssertEqual(store.activeSubagentCount, 2)
    XCTAssertEqual(store.displaySession?.presentationStatus, .working(prompt: nil))
    XCTAssertEqual(store.displaySession?.statusLabel, "Working · 2 agents")
  }

  func testSingleSubagentUsesAChildCountWithoutCreatingASecondSession() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "code-reviewer"))

    XCTAssertEqual(store.activeSessionCount, 1)
    XCTAssertEqual(store.displaySession?.statusLabel, "Working · 1 agent")
  }

  func testSubagentStopRequiresExactIDAndTurnAndPreservesParent() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(event: .working, sessionID: "parent", turnID: "turn-1"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStopped, sessionID: "parent", turnID: "wrong-turn",
        agentID: "agent-1", agentType: "worker"))

    XCTAssertEqual(store.activeSubagentCount, 1)

    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStopped, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker", result: "ignored child result"))

    XCTAssertEqual(store.activeSubagentCount, 0)
    XCTAssertEqual(store.sessions["parent"]?.status, .working(prompt: nil))
    XCTAssertEqual(store.activeSessionCount, 1)
  }

  func testSubagentMetadataDoesNotReplaceParentProjectIdentity() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(
        event: .working, sessionID: "parent", cwd: "/tmp/ParentProject",
        deliverySequence: 1))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", cwd: "/tmp/ChildWorktree",
        agentID: "agent-1", agentType: "worker", deliverySequence: 2))

    XCTAssertEqual(store.sessions["parent"]?.projectName, "ParentProject")
    XCTAssertEqual(store.sessions["parent"]?.workingDirectory, "/tmp/ParentProject")
    XCTAssertEqual(store.activeSubagentCount, 1)
  }

  func testOutOfOrderSubagentStopTombstonesDelayedStart() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStopped, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker", deliverySequence: 2))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker", deliverySequence: 1))

    XCTAssertEqual(store.activeSubagentCount, 0)
    XCTAssertNil(store.sessions["parent"])
  }

  func testDelayedChildStartCannotReviveNewerRootCompletion() async {
    let settings = makeTestSettings()
    settings.completionVisibility = .eightSeconds
    let store = SessionStore(settings: settings)
    _ = await store.receive(
      makeBridgeEvent(event: .completed, sessionID: "parent", deliverySequence: 3))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker", deliverySequence: 2))

    XCTAssertEqual(store.activeSubagentCount, 0)
    XCTAssertEqual(store.sessions["parent"]?.presentationStatus, .completed(message: nil))
  }

  func testOlderParentEventKeepsNewerChildWhileRestoringParentIdentity() async {
    let store = SessionStore(settings: makeTestSettings())
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", cwd: "/tmp/ChildWorktree",
        agentID: "agent-1", agentType: "worker", deliverySequence: 2))
    _ = await store.receive(
      makeBridgeEvent(
        event: .working, sessionID: "parent", cwd: "/tmp/ParentProject",
        deliverySequence: 1))

    XCTAssertEqual(store.sessions["parent"]?.projectName, "ParentProject")
    XCTAssertEqual(store.activeSubagentCount, 1)
    XCTAssertEqual(store.sessions["parent"]?.presentationStatus, .working(prompt: nil))
  }

  func testRootLifecycleClearsSubagentsButChildStopDoesNotSignalCompletion() async {
    let settings = makeTestSettings()
    settings.capsLockEnabled = true
    let capsLock = RecordingCapsLockService()
    let store = SessionStore(settings: settings, capsLockService: capsLock)
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker"))
    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStopped, sessionID: "parent", turnID: "turn-1",
        agentID: "agent-1", agentType: "worker"))

    let signalSnapshot = await capsLock.snapshot()
    XCTAssertEqual(signalSnapshot.0, [])

    _ = await store.receive(
      makeBridgeEvent(
        event: .subagentStarted, sessionID: "parent", turnID: "turn-2",
        agentID: "agent-2", agentType: "worker"))
    _ = await store.receive(
      makeBridgeEvent(event: .completed, sessionID: "parent", turnID: "turn-2"))

    XCTAssertEqual(store.activeSubagentCount, 0)
    XCTAssertEqual(store.sessions["parent"]?.presentationStatus, .completed(message: nil))
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

  func testApprovalDoesNotAutoExpandWhenPreferenceIsDisabled() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    settings.autoExpandApprovals = false
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )

    let decisionTask = Task { await store.receive(event) }
    let queued = await waitUntil { store.currentApproval?.id == event.requestId }
    XCTAssertTrue(queued)
    XCTAssertFalse(store.isExpanded)
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .deny)
  }

  func testPendingApprovalCanCollapseAndReopenWithoutResolving() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    settings.autoExpandApprovals = true
    let store = SessionStore(settings: settings)
    let event = makeBridgeEvent(
      event: .approvalRequested,
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )

    let decisionTask = Task { await store.receive(event) }
    let queued = await waitUntil { store.currentApproval?.id == event.requestId }
    XCTAssertTrue(queued)
    XCTAssertTrue(store.isExpanded)

    store.collapse()
    XCTAssertFalse(store.isExpanded)
    XCTAssertEqual(store.currentApproval?.id, event.requestId)
    XCTAssertEqual(store.displaySession?.status, .awaitingApproval(store.currentApproval!))

    store.expand()
    XCTAssertTrue(store.isExpanded)
    XCTAssertEqual(store.currentApproval?.id, event.requestId)
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .deny)
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
      (
        "Test Integration",
        {
          guard let lease = $0.beginIntegrationSelfTest(owner: .onboarding) else { return }
          _ = $0.beginIntegrationDemoSession("blocked-integration-demo", lease: lease)
        }
      ),
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
      (
        "Test Integration",
        {
          guard let lease = $0.beginIntegrationSelfTest(owner: .onboarding) else { return }
          _ = $0.beginIntegrationDemoSession("blocked-integration-demo", lease: lease)
        }
      ),
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

  func testEveryPreviewActionPreservesAndCannotHideLiveFailedSession() async {
    let previews: [(String, (SessionStore) -> Void)] = [
      ("Working", { $0.testState(.working) }),
      ("Approval", { $0.testState(.approvalRequested) }),
      ("Completed", { $0.testState(.completed) }),
      ("Failed", { $0.testState(.failed) }),
      ("Multiple Sessions", { $0.testMultipleSessions() }),
      (
        "Test Integration",
        {
          guard let lease = $0.beginIntegrationSelfTest(owner: .onboarding) else { return }
          _ = $0.beginIntegrationDemoSession("blocked-integration-demo", lease: lease)
        }
      ),
    ]

    for (name, preview) in previews {
      let store = SessionStore(settings: makeTestSettings())
      _ = await store.receive(
        makeBridgeEvent(event: .failed, sessionID: "live-failure", error: "Real build failed"))
      let liveSession = store.sessions["live-failure"]

      XCTAssertFalse(store.canPreviewTestStates, name)
      preview(store)

      XCTAssertEqual(store.sessions["live-failure"], liveSession, name)
      XCTAssertEqual(store.sessions.count, 1, name)
      XCTAssertEqual(store.displaySession, liveSession, name)
      XCTAssertTrue(store.approvalQueue.isEmpty, name)
      XCTAssertFalse(store.integrationSelfTestInProgress, name)
    }
  }

  func testLiveApprovalClearsOnlyLocallyOwnedDemoState() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    store.testState(.approvalRequested)
    let demoRequestID = store.currentApproval?.id
    XCTAssertNotNil(demoRequestID)
    XCTAssertNotNil(store.sessions["demo-visual-state"])
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
    XCTAssertNil(store.sessions["demo-visual-state"])
    XCTAssertEqual(Set(store.sessions.keys), ["live-approval"])
    XCTAssertTrue(store.decide(requestID: liveRequestID, decision: .deny))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .deny)
  }

  func testLiveApprovalCancelsIntegrationDemoAndIgnoresLateCompletion() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings)
    let demoSessionID = "cowlick-self-test-\(UUID().uuidString)"
    guard let lease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: lease))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: demoSessionID))
    XCTAssertTrue(store.isIntegrationDemoSessionActive(demoSessionID))

    let liveRequestID = UUID()
    let liveEvent = makeBridgeEvent(
      event: .approvalRequested,
      requestID: liveRequestID,
      sessionID: "live-approval",
      toolName: "Bash",
      toolInput: .object(["command": .string("git push")])
    )
    let decisionTask = Task { await store.receive(liveEvent) }
    let queued = await waitUntil { store.currentApproval?.id == liveRequestID }
    XCTAssertTrue(queued)
    guard let liveSession = store.sessions[liveEvent.sessionId] else {
      decisionTask.cancel()
      return XCTFail("Expected live approval session")
    }
    XCTAssertFalse(store.isIntegrationDemoSessionActive(demoSessionID))
    store.finishIntegrationDemoSession(demoSessionID, discardPresentedState: true)

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: demoSessionID))

    XCTAssertNil(store.sessions[demoSessionID])
    XCTAssertEqual(store.approvalQueue.map(\.id), [liveRequestID])
    XCTAssertEqual(store.sessions[liveEvent.sessionId], liveSession)
    XCTAssertTrue(store.decide(requestID: liveRequestID, decision: .allow))
    let decision = await decisionTask.value
    XCTAssertEqual(decision, .allow)
  }

  func testResetCancelsIntegrationDemoAndIgnoresLateCompletion() async {
    let store = SessionStore(settings: makeTestSettings())
    let demoSessionID = "cowlick-self-test-\(UUID().uuidString)"
    guard let lease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: lease))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: demoSessionID))
    XCTAssertTrue(store.hasObservedIntegrationDemoEvent(.working, sessionID: demoSessionID))

    store.reset()
    XCTAssertFalse(store.isIntegrationDemoSessionActive(demoSessionID))
    XCTAssertFalse(store.isIntegrationSelfTestActive(lease))
    XCTAssertTrue(store.integrationSelfTestInProgress)
    XCTAssertTrue(store.sessions.isEmpty)

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: demoSessionID))

    XCTAssertNil(store.sessions[demoSessionID])
    XCTAssertTrue(store.approvalQueue.isEmpty)
    store.finishIntegrationSelfTest(lease)
  }

  func testOverlappingIntegrationDemoStartsAreRejected() {
    let store = SessionStore(settings: makeTestSettings())
    guard let lease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }

    XCTAssertTrue(store.beginIntegrationDemoSession("first-integration-demo", lease: lease))
    XCTAssertFalse(store.beginIntegrationDemoSession("second-integration-demo", lease: lease))
    XCTAssertTrue(store.isIntegrationDemoSessionActive("first-integration-demo"))
    XCTAssertFalse(store.isIntegrationDemoSessionActive("second-integration-demo"))
  }

  func testIntegrationDemoOwnershipEndsOnlyAfterObservedCompletion() async {
    let store = SessionStore(settings: makeTestSettings())
    let demoSessionID = "cowlick-self-test-\(UUID().uuidString)"
    guard let lease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: lease))

    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: demoSessionID))
    XCTAssertTrue(store.hasObservedIntegrationDemoEvent(.working, sessionID: demoSessionID))
    XCTAssertFalse(store.hasObservedIntegrationDemoEvent(.completed, sessionID: demoSessionID))

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: demoSessionID))
    XCTAssertTrue(store.hasObservedIntegrationDemoEvent(.completed, sessionID: demoSessionID))
    store.finishIntegrationDemoSession(demoSessionID, discardPresentedState: false)

    XCTAssertFalse(store.isIntegrationDemoSessionActive(demoSessionID))
    XCTAssertNotNil(store.sessions[demoSessionID])
  }

  func testKeepFinishBeforeCompletionRetainsOwnershipThroughLateDelivery() async {
    let store = SessionStore(settings: makeTestSettings())
    let demoSessionID = "cowlick-self-test-\(UUID().uuidString)"
    guard let lease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: lease))

    store.finishIntegrationDemoSession(demoSessionID, discardPresentedState: false)
    XCTAssertTrue(store.isIntegrationDemoSessionActive(demoSessionID))

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: demoSessionID))

    XCTAssertTrue(store.hasObservedIntegrationDemoEvent(.completed, sessionID: demoSessionID))
    XCTAssertFalse(store.isIntegrationDemoSessionActive(demoSessionID))
    XCTAssertNotNil(store.sessions[demoSessionID])
  }

  func testDiagnosticsSelfTestCannotOverlapOnboardingDemo() async {
    let store = SessionStore(settings: makeTestSettings())
    guard let onboardingLease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    let demoSessionID = "cowlick-self-test-\(UUID().uuidString)"
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: onboardingLease))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: demoSessionID))

    XCTAssertNil(store.beginIntegrationSelfTest(owner: .diagnostics))
    XCTAssertTrue(store.isIntegrationDemoSessionActive(demoSessionID))
    XCTAssertTrue(store.hasObservedIntegrationDemoEvent(.working, sessionID: demoSessionID))

    store.finishIntegrationDemoSession(demoSessionID, discardPresentedState: true)
    store.finishIntegrationSelfTest(onboardingLease)
    XCTAssertNotNil(store.beginIntegrationSelfTest(owner: .diagnostics))
  }

  func testResetKeepsCancelledLeaseUntilDelayedOwnerFinishesAndIgnoresLateEvent() async {
    let store = SessionStore(settings: makeTestSettings())
    guard let onboardingLease = store.beginIntegrationSelfTest(owner: .onboarding) else {
      return XCTFail("Expected onboarding self-test lease")
    }
    let demoSessionID = "delayed-integration-demo"
    XCTAssertTrue(store.beginIntegrationDemoSession(demoSessionID, lease: onboardingLease))
    _ = await store.receive(makeBridgeEvent(event: .working, sessionID: demoSessionID))

    store.reset()
    XCTAssertFalse(store.isIntegrationSelfTestActive(onboardingLease))
    XCTAssertTrue(store.integrationSelfTestInProgress)
    XCTAssertNil(store.beginIntegrationSelfTest(owner: .diagnostics))

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: demoSessionID))
    XCTAssertNil(store.sessions[demoSessionID])

    store.finishIntegrationSelfTest(onboardingLease)
    guard let diagnosticsLease = store.beginIntegrationSelfTest(owner: .diagnostics) else {
      return XCTFail("Expected diagnostics lease after delayed owner finished")
    }
    store.finishIntegrationSelfTest(diagnosticsLease)
    XCTAssertFalse(store.integrationSelfTestInProgress)
  }

  func testPingClearsPreviewAndNotifiesPresentation() async {
    let store = SessionStore(settings: makeTestSettings())
    store.testState(.approvalRequested)
    XCTAssertNotNil(store.currentApproval)
    XCTAssertNotNil(store.sessions["demo-visual-state"])
    var presentationChangeCount = 0
    store.presentationDidChange = { presentationChangeCount += 1 }

    _ = await store.receive(makeBridgeEvent(event: .ping, sessionID: "health-check"))

    XCTAssertNil(store.currentApproval)
    XCTAssertNil(store.sessions["demo-visual-state"])
    XCTAssertEqual(presentationChangeCount, 1)
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

  func testCompletionFlashesEachNewlyFinishedThreadUsingConfiguredCount() async {
    let settings = makeTestSettings()
    settings.capsLockEnabled = true
    settings.capsLockFlashCount = 4
    let capsLock = RecordingCapsLockService()
    let store = SessionStore(settings: settings, capsLockService: capsLock)

    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: "one"))
    _ = await store.receive(makeBridgeEvent(event: .completed, sessionID: "two"))
    try? await Task.sleep(for: .milliseconds(50))

    let snapshot = await capsLock.snapshot()
    XCTAssertEqual(snapshot.0, [.completion(flashes: 4), .completion(flashes: 4)])
    store.expand()
    try? await Task.sleep(for: .milliseconds(20))
    let expandedSnapshot = await capsLock.snapshot()
    XCTAssertEqual(expandedSnapshot.1, 0)
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

  func testChatNameIsMatchedToTheExactSessionAndProjectRemainsContext() async {
    let firstID = UUID().uuidString
    let secondID = UUID().uuidString
    let titles = [firstID: "Polish the notch", secondID: "Verify release signing"]
    let store = SessionStore(
      settings: makeTestSettings(),
      resolveChatTitle: { id, _ in titles[id] }
    )

    _ = await store.receive(
      makeBridgeEvent(event: .working, sessionID: firstID, cwd: "/tmp/Scoutly"))
    _ = await store.receive(
      makeBridgeEvent(event: .working, sessionID: secondID, cwd: "/tmp/Meetly"))

    XCTAssertEqual(store.sessions[firstID]?.displayName, "Polish the notch")
    XCTAssertEqual(store.sessions[firstID]?.projectContext, "Scoutly")
    XCTAssertEqual(store.sessions[secondID]?.displayName, "Verify release signing")
    XCTAssertEqual(store.sessions[secondID]?.projectContext, "Meetly")
  }

  func testDisablingChatNamesClearsSessionsAndPendingApprovals() async {
    let sessionID = UUID().uuidString
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(
      settings: settings,
      resolveChatTitle: { _, _ in "Private task name" })
    let event = makeBridgeEvent(
      event: .approvalRequested,
      sessionID: sessionID,
      toolName: "Bash",
      toolInput: .object(["command": .string("swift test")])
    )
    let decision = Task { await store.receive(event) }
    let didQueueApproval = await waitUntil { store.currentApproval != nil }
    XCTAssertTrue(didQueueApproval)

    settings.showChatNames = false
    await store.updateChatNameVisibility(false)

    XCTAssertNil(store.sessions[sessionID]?.chatTitle)
    XCTAssertNil(store.currentApproval?.chatTitle)
    guard case .awaitingApproval(let embeddedRequest) = store.sessions[sessionID]?.status else {
      return XCTFail("Expected the session to retain its pending approval state")
    }
    XCTAssertNil(embeddedRequest.chatTitle)
    XCTAssertTrue(store.decide(requestID: event.requestId, decision: .deny))
    _ = await decision.value
  }

  func testDisablingPromptPreviewsRevokesPromptDerivedChatTitle() async {
    let sessionID = UUID().uuidString
    let settings = makeTestSettings()
    settings.showPromptPreviews = true
    let store = SessionStore(
      settings: settings,
      resolveChatTitle: { _, allowPromptDerivedFallback in
        allowPromptDerivedFallback ? "Private prompt-derived title" : nil
      })
    _ = await store.receive(
      makeBridgeEvent(event: .working, sessionID: sessionID, cwd: "/tmp/Scoutly"))
    XCTAssertEqual(store.sessions[sessionID]?.chatTitle, "Private prompt-derived title")

    settings.showPromptPreviews = false
    await store.refreshChatNames()

    XCTAssertNil(store.sessions[sessionID]?.chatTitle)
    XCTAssertEqual(store.sessions[sessionID]?.displayName, "Scoutly")
  }

  func testStaleChatNameDisableCannotOverrideCurrentEnabledPreference() async {
    let sessionID = UUID().uuidString
    let settings = makeTestSettings()
    let store = SessionStore(
      settings: settings,
      resolveChatTitle: { _, _ in "Current chat title" })
    _ = await store.receive(
      makeBridgeEvent(event: .working, sessionID: sessionID, cwd: "/tmp/Scoutly"))

    await store.updateChatNameVisibility(false)

    XCTAssertEqual(store.sessions[sessionID]?.chatTitle, "Current chat title")
  }

  private func sampleApproval() -> ApprovalRequest {
    ApprovalRequest(
      id: UUID(), sessionID: "s", turnID: "t", chatTitle: nil, projectName: "Scoutly",
      workingDirectory: "/tmp/Scoutly", toolName: "Bash",
      operationDescription: "Run the project test suite", operationSummary: "swift test",
      fullOperation: "swift test",
      requestedAt: Date(), expiresAt: Date().addingTimeInterval(60)
    )
  }
}

private final class LockedPinnedThreadIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Set<String>?

  init(_ value: Set<String>?) {
    storedValue = value
  }

  var value: Set<String>? {
    get { lock.withLock { storedValue } }
    set { lock.withLock { storedValue = newValue } }
  }
}
