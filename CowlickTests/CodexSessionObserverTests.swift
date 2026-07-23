import Foundation
import XCTest

@testable import Cowlick

final class CodexSessionObserverTests: XCTestCase {
  func testOnlyActivityEventsRefreshUsage() {
    for kind in [
      ObservedCodexLifecycleEvent.Kind.working,
      .completed,
      .failed,
    ] {
      XCTAssertTrue(makeEvent(kind: kind).shouldRefreshUsage)
    }
    XCTAssertFalse(makeEvent(kind: .stale).shouldRefreshUsage)
  }

  private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObservedCodexLifecycleEvent] = []

    func append(_ event: ObservedCodexLifecycleEvent) {
      lock.withLock { storage.append(event) }
    }

    var events: [ObservedCodexLifecycleEvent] { lock.withLock { storage } }
  }

  private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func record() {
      lock.withLock { storage += 1 }
    }

    var count: Int { lock.withLock { storage } }
  }

  func testTranscriptLifecycleMapsWorkingCompletionAndFailureWithoutApproval() throws {
    var accumulator = CodexTranscriptAccumulator()
    XCTAssertNil(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"session_meta","timestamp":"2026-07-20T12:00:00.000Z","payload":{"id":"session-1","cwd":"/tmp/Scoutly","source":"vscode"}}"#
        )))
    XCTAssertNil(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"turn_context","timestamp":"2026-07-20T12:00:01.000Z","payload":{"turn_id":"turn-1","cwd":"/tmp/Scoutly","model":"gpt-5.6-sol"}}"#
        )))

    let working = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"event_msg","timestamp":"2026-07-20T12:00:02.000Z","payload":{"type":"task_started","turn_id":"turn-1"}}"#
        )))
    XCTAssertEqual(working.kind, .working)
    XCTAssertEqual(working.sessionID, "session-1")
    XCTAssertEqual(working.turnID, "turn-1")
    XCTAssertEqual(working.model, "gpt-5.6-sol")
    XCTAssertEqual(working.bridgeEvent?.event, .working)
    XCTAssertNotEqual(working.bridgeEvent?.event, .approvalRequested)

    let completed = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"event_msg","timestamp":"2026-07-20T12:00:03.000Z","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"private result is ignored"}}"#
        )))
    XCTAssertEqual(completed.kind, .completed)
    XCTAssertEqual(completed.bridgeEvent?.event, .completed)
    XCTAssertNil(completed.bridgeEvent?.lastAssistantMessage)

    let failed = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"event_msg","timestamp":"2026-07-20T12:00:04.000Z","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"private reason is ignored"}}"#
        )))
    XCTAssertEqual(failed.kind, .failed)
    XCTAssertEqual(failed.bridgeEvent?.event, .failed)
    XCTAssertEqual(failed.bridgeEvent?.errorMessage, "Codex turn interrupted")
  }

  func testSubagentTranscriptMapsToParentSubagentEvents() throws {
    var accumulator = CodexTranscriptAccumulator()
    _ = accumulator.consume(
      line: jsonLine(
        #"{"type":"session_meta","timestamp":"2026-07-20T12:00:00.000Z","payload":{"id":"child-1","cwd":"/tmp/Scoutly","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-1","agent_path":"/root/reviewer","agent_role":"code-reviewer"}}}}}"#
      ))
    _ = accumulator.consume(
      line: jsonLine(
        #"{"type":"turn_context","timestamp":"2026-07-20T12:00:01.000Z","payload":{"turn_id":"child-turn","cwd":"/tmp/Scoutly","model":"gpt-5.6-sol"}}"#
      ))

    let started = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"event_msg","timestamp":"2026-07-20T12:00:02.000Z","payload":{"type":"task_started","turn_id":"child-turn"}}"#
        )))
    XCTAssertEqual(started.parentSessionID, "parent-1")
    XCTAssertEqual(started.agentType, "code-reviewer")
    XCTAssertEqual(started.bridgeEvent?.event, .subagentStarted)
    XCTAssertEqual(started.bridgeEvent?.sessionId, "parent-1")
    XCTAssertEqual(started.bridgeEvent?.agentId, "child-1")

    let stopped = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(
          #"{"type":"event_msg","timestamp":"2026-07-20T12:00:03.000Z","payload":{"type":"task_complete","turn_id":"child-turn"}}"#
        )))
    XCTAssertEqual(stopped.bridgeEvent?.event, .subagentStopped)
  }

  func testReplayedSessionMetadataCannotReplaceEnvelopeIdentity() throws {
    var accumulator = CodexTranscriptAccumulator()
    _ = accumulator.consume(
      line: jsonLine(
        #"{"type":"session_meta","payload":{"id":"current-session","cwd":"/tmp/Scoutly"}}"#
      ))
    _ = accumulator.consume(
      line: jsonLine(
        #"{"type":"session_meta","payload":{"id":"historical-session","cwd":"/tmp/Other"}}"#
      ))

    let event = try XCTUnwrap(
      accumulator.consume(
        line: jsonLine(#"{"type":"event_msg","payload":{"type":"task_started"}}"#)))

    XCTAssertEqual(event.sessionID, "current-session")
    XCTAssertEqual(event.cwd, "/tmp/Scoutly")
  }

  func testUnknownAndOversizedTranscriptRecordsAreIgnored() {
    var accumulator = CodexTranscriptAccumulator()
    XCTAssertNil(
      accumulator.consume(
        line: jsonLine(#"{"type":"future_record","payload":{"type":"approval_requested"}}"#)
      ))
    XCTAssertNil(
      accumulator.consume(
        line: Data(repeating: 0x78, count: CodexSessionObserver.maximumLineSize + 1)))
  }

  func testInitialPartialRecordCompletesAfterAppend() async throws {
    let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Observer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let sessions = codexHome.appendingPathComponent("sessions/2026/07/20", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let rollout = sessions.appendingPathComponent("rollout.jsonl")
    let prefix =
      #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/Scoutly"}}"#
      + "\n"
      + #"{"type":"event_msg","payload":{"type":"task_"#
    try Data(prefix.utf8).write(to: rollout)
    let recorder = EventRecorder()
    let observer = CodexSessionObserver(codexHome: codexHome, handler: recorder.append)
    observer.start()
    defer { observer.stop() }
    try await Task.sleep(for: .milliseconds(250))

    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("started\"}}\n".utf8))
    try handle.close()

    let deadline = Date().addingTimeInterval(2)
    while recorder.events.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(recorder.events.last?.kind, .working)
    XCTAssertEqual(recorder.events.last?.sessionID, "session-1")
  }

  func testObserverReportsCodexPinnedThreadChanges() async throws {
    let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Pin-Observer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let changes = ChangeRecorder()
    let observer = CodexSessionObserver(
      codexHome: codexHome,
      pinnedThreadsDidChange: changes.record,
      handler: { _ in })
    observer.start()
    defer { observer.stop() }
    try await Task.sleep(for: .milliseconds(250))

    try Data(#"{"pinned-thread-ids":[]}"#.utf8).write(
      to: codexHome.appendingPathComponent(".codex-global-state.json"))

    let deadline = Date().addingTimeInterval(2)
    while changes.count == 0, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(changes.count, 0)
  }

  func testObserverRecoversWhenCodexHomeIsCreatedAfterLaunch() async throws {
    let privateParent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Late-Root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: privateParent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: privateParent.path)
    defer { try? FileManager.default.removeItem(at: privateParent) }
    let codexHome = privateParent.appendingPathComponent(".codex", isDirectory: true)
    let recorder = EventRecorder()
    let observer = CodexSessionObserver(codexHome: codexHome, handler: recorder.append)
    observer.start()
    defer { observer.stop() }
    try await Task.sleep(for: .milliseconds(150))

    let sessions = codexHome.appendingPathComponent("sessions/2026/07/20", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let rollout = sessions.appendingPathComponent("rollout.jsonl")
    try Data(
      (#"{"type":"session_meta","payload":{"id":"late-session","cwd":"/tmp/Scoutly"}}"#
        + "\n"
        + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"late-turn"}}"#
        + "\n").utf8
    ).write(to: rollout)

    let deadline = Date().addingTimeInterval(2)
    while recorder.events.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(recorder.events.last?.sessionID, "late-session")
    XCTAssertEqual(observer.statusSummary, "monitoring local Codex lifecycle events")
  }

  func testObserverBoundsTrackedFilesFragmentsAndExpiresState() throws {
    let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Bounded-State-\(UUID().uuidString)", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let clock = LockedClock(Date())
    let observer = CodexSessionObserver(codexHome: codexHome, now: clock.now) { _ in }

    for index in 0...CodexSessionObserver.maximumTrackedFiles {
      let rollout = sessions.appendingPathComponent("\(index).jsonl")
      try Data(
        (#"{"type":"session_meta","payload":{"id":"session-"# + "\(index)"
          + #"","cwd":"/tmp/Scoutly"}}"# + "\n" + #"{"incomplete":""#).utf8
      ).write(to: rollout)
      observer.processFileForTesting(rollout)
      clock.advance(by: 1)
    }

    XCTAssertEqual(observer.testingStateMetrics.fileCount, CodexSessionObserver.maximumTrackedFiles)
    XCTAssertLessThanOrEqual(
      observer.testingStateMetrics.fragmentBytes,
      CodexSessionObserver.maximumTotalFragmentBytes)
    XCTAssertFalse(
      observer.testingTrackedPaths.contains(sessions.appendingPathComponent("0.jsonl").path))
    XCTAssertTrue(
      observer.testingTrackedPaths.contains(
        sessions.appendingPathComponent("\(CodexSessionObserver.maximumTrackedFiles).jsonl").path))

    clock.advance(by: CodexSessionObserver.stateRetentionInterval + 1)
    observer.pruneStateForTesting()
    XCTAssertEqual(observer.testingStateMetrics.fileCount, 0)
    XCTAssertEqual(observer.testingStateMetrics.fragmentBytes, 0)
  }

  func testObserverBoundsTotalFragmentBytesAndRemovesDeletedPaths() throws {
    let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Fragment-Bound-\(UUID().uuidString)", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let observer = CodexSessionObserver(codexHome: codexHome) { _ in }

    var rollouts: [URL] = []
    for index in 0..<5 {
      let rollout = sessions.appendingPathComponent("large-\(index).jsonl")
      let envelope =
        #"{"type":"session_meta","payload":{"id":"session-"# + "\(index)"
        + #"","cwd":"/tmp/Scoutly"}}"# + "\n"
      var data = Data(envelope.utf8)
      data.append(Data(repeating: 0x78, count: CodexSessionObserver.maximumLineSize))
      try data.write(to: rollout)
      rollouts.append(rollout)
      observer.processFileForTesting(rollout)
    }

    XCTAssertGreaterThan(observer.testingStateMetrics.fragmentBytes, 0)
    XCTAssertLessThanOrEqual(
      observer.testingStateMetrics.fragmentBytes,
      CodexSessionObserver.maximumTotalFragmentBytes)

    let beforeDeletion = observer.testingStateMetrics.fileCount
    try FileManager.default.removeItem(at: rollouts.last!)
    observer.pruneStateForTesting()
    XCTAssertLessThan(observer.testingStateMetrics.fileCount, beforeDeletion)
  }

  @MainActor
  func testStaleObservationCannotRemoveHookOwnedSession() async {
    let store = SessionStore(capsLockService: RecordingCapsLockService())
    let observed = BridgeEvent(
      event: .working,
      sessionId: "session-1",
      turnId: "turn-1",
      cwd: "/tmp/Scoutly",
      authToken: "",
      origin: .localObservation
    )
    _ = await store.receive(observed)
    XCTAssertNotNil(store.sessions["session-1"])
    store.expireLocalObservation(sessionID: "session-1", turnID: "turn-1")
    XCTAssertNil(store.sessions["session-1"])

    _ = await store.receive(observed)
    let hook = BridgeEvent(
      event: .working,
      sessionId: "session-1",
      turnId: "turn-1",
      cwd: "/tmp/Scoutly",
      authToken: ""
    )
    _ = await store.receive(hook)
    store.expireLocalObservation(sessionID: "session-1", turnID: "turn-1")
    XCTAssertNotNil(store.sessions["session-1"])
  }

  @MainActor
  func testLocalObservationCannotRejectOrOverwriteAuthoritativeApproval() async {
    let settings = makeTestSettings()
    settings.approvalTimeout = 10
    let store = SessionStore(settings: settings, capsLockService: RecordingCapsLockService())
    let observed = BridgeEvent(
      event: .working,
      sessionId: "session-1",
      turnId: "turn-1",
      cwd: "/tmp/Scoutly",
      authToken: "",
      origin: .localObservation
    )
    _ = await store.receive(observed)

    let approval = makeBridgeEvent(
      event: .approvalRequested,
      requestID: UUID(),
      sessionID: "session-1",
      turnID: "turn-1",
      toolName: "Bash",
      toolInput: .object(["command": .string("git status")]),
      deliverySequence: 1
    )
    let approvalTask = Task { await store.receive(approval) }
    let approvalQueued = await waitUntil { store.currentApproval?.id == approval.requestId }
    XCTAssertTrue(approvalQueued)

    _ = await store.receive(observed)
    XCTAssertEqual(store.currentApproval?.id, approval.requestId)
    _ = await store.receive(
      BridgeEvent(
        event: .working,
        timestamp: Date().addingTimeInterval(1),
        sessionId: "session-1",
        turnId: "turn-2",
        cwd: "/tmp/Scoutly",
        authToken: "",
        origin: .localObservation
      ))
    _ = await store.receive(
      BridgeEvent(
        event: .subagentStarted,
        timestamp: Date().addingTimeInterval(2),
        sessionId: "session-1",
        turnId: "child-turn",
        cwd: "/tmp/Scoutly",
        agentId: "child-1",
        agentType: "reviewer",
        authToken: "",
        origin: .localObservation
      ))
    XCTAssertEqual(store.currentApproval?.id, approval.requestId)
    XCTAssertEqual(store.sessions["session-1"]?.turnID, "turn-1")
    XCTAssertTrue(store.sessions["session-1"]?.subagents.isEmpty == true)
    XCTAssertTrue(store.decide(requestID: approval.requestId, decision: .deny))
    let decision = await approvalTask.value
    XCTAssertEqual(decision, .deny)
  }

  @MainActor
  func testStaleObservationKeepsSessionWithActiveSubagent() async {
    let store = SessionStore(capsLockService: RecordingCapsLockService())
    let parent = BridgeEvent(
      event: .working,
      sessionId: "session-1",
      turnId: "turn-1",
      cwd: "/tmp/Scoutly",
      authToken: "",
      origin: .localObservation
    )
    let child = BridgeEvent(
      event: .subagentStarted,
      sessionId: "session-1",
      turnId: "child-turn",
      cwd: "/tmp/Scoutly",
      agentId: "child-1",
      agentType: "reviewer",
      authToken: "",
      origin: .localObservation
    )
    _ = await store.receive(parent)
    _ = await store.receive(child)

    store.expireLocalObservation(sessionID: "session-1", turnID: "turn-1")

    XCTAssertNotNil(store.sessions["session-1"])
    XCTAssertEqual(store.sessions["session-1"]?.subagents.count, 1)
  }

  @MainActor
  func testHookCompletionAfterObservationDoesNotSignalTwice() async throws {
    let settings = makeTestSettings()
    settings.capsLockEnabled = true
    let capsLock = RecordingCapsLockService()
    let store = SessionStore(settings: settings, capsLockService: capsLock)
    let timestamp = Date()
    let observed = BridgeEvent(
      event: .completed,
      timestamp: timestamp,
      sessionId: "session-1",
      turnId: "turn-1",
      cwd: "/tmp/Scoutly",
      authToken: "",
      origin: .localObservation
    )
    let hook = makeBridgeEvent(
      event: .completed,
      sessionID: "session-1",
      turnID: "turn-1",
      timestamp: timestamp.addingTimeInterval(0.01),
      result: "Verified result",
      deliverySequence: 1
    )

    _ = await store.receive(observed)
    _ = await store.receive(hook)
    try await Task.sleep(for: .milliseconds(50))

    let patterns = await capsLock.snapshot().0
    XCTAssertEqual(patterns.filter { $0 == .completion(flashes: 10) }.count, 1)
  }

  @MainActor
  func testDelayedHookTerminalForOlderTurnCannotOverwriteNewerObservedTurn() async {
    let store = SessionStore(capsLockService: RecordingCapsLockService())
    let start = Date()
    _ = await store.receive(
      makeBridgeEvent(
        event: .working,
        sessionID: "session-1",
        turnID: "turn-a",
        timestamp: start,
        deliverySequence: 1
      ))
    _ = await store.receive(
      BridgeEvent(
        event: .working,
        timestamp: start.addingTimeInterval(2),
        sessionId: "session-1",
        turnId: "turn-b",
        cwd: "/tmp/Scoutly",
        authToken: "",
        origin: .localObservation
      ))
    _ = await store.receive(
      makeBridgeEvent(
        event: .completed,
        sessionID: "session-1",
        turnID: "turn-a",
        timestamp: start.addingTimeInterval(1),
        deliverySequence: 2
      ))

    XCTAssertEqual(store.sessions["session-1"]?.turnID, "turn-b")
    XCTAssertEqual(store.sessions["session-1"]?.presentationStatus, .working(prompt: nil))
  }

  @MainActor
  func testHookRemainsAuthoritativeForSameObservedTurn() async {
    let store = SessionStore(
      settings: makeTestSettings(), capsLockService: RecordingCapsLockService())
    let start = Date()
    _ = await store.receive(
      BridgeEvent(
        event: .working,
        timestamp: start,
        sessionId: "session-1",
        turnId: "turn-a",
        cwd: "/tmp/Scoutly",
        authToken: "",
        origin: .localObservation
      ))
    _ = await store.receive(
      makeBridgeEvent(
        event: .completed,
        sessionID: "session-1",
        turnID: "turn-a",
        timestamp: start.addingTimeInterval(-1),
        result: "Hook result",
        deliverySequence: 1
      ))

    XCTAssertEqual(store.sessions["session-1"]?.presentationStatus, .completed(message: nil))
  }

  private func jsonLine(_ value: String) -> Data { Data(value.utf8) }

  private func makeEvent(kind: ObservedCodexLifecycleEvent.Kind) -> ObservedCodexLifecycleEvent {
    ObservedCodexLifecycleEvent(
      kind: kind,
      sessionID: "session-1",
      turnID: "turn-1",
      cwd: "/tmp/Scoutly",
      model: "gpt-5.6-sol",
      timestamp: Date(timeIntervalSince1970: 0),
      parentSessionID: nil,
      agentType: nil
    )
  }

  private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
      lock.withLock { value = value.addingTimeInterval(interval) }
    }
  }
}
