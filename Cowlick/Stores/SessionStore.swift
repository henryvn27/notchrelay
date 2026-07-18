import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
  private(set) var sessions: [String: AgentSession] = [:]
  private(set) var approvalQueue: [ApprovalRequest] = []
  private var seenApprovalRequestIDs: [UUID: Date] = [:]
  private var localDemoApprovalIDs: Set<UUID> = []
  var isExpanded = false
  var presentationDidChange: (() -> Void)?

  let settings: SettingsStore
  let eventLogger: EventLogger
  let approvalCoordinator: ApprovalCoordinator
  let capsLockService: any CapsLockSignalService

  init(
    settings: SettingsStore = SettingsStore(),
    eventLogger: EventLogger = EventLogger(),
    approvalCoordinator: ApprovalCoordinator = ApprovalCoordinator(),
    capsLockService: any CapsLockSignalService = NativeCapsLockSignalService()
  ) {
    self.settings = settings
    self.eventLogger = eventLogger
    self.approvalCoordinator = approvalCoordinator
    self.capsLockService = capsLockService
  }

  var currentApproval: ApprovalRequest? { approvalQueue.first }

  var activeSessionCount: Int {
    sessions.values.filter(\.isActive).count
  }

  var displaySession: AgentSession? {
    sessions.values
      .filter { session in
        if case .completed = session.status {
          return (session.completionVisibleUntil ?? .distantPast) > Date()
        }
        if case .idle = session.status { return false }
        return true
      }
      .sorted(by: sessionSort)
      .first
  }

  var sessionSummaries: [AgentSession] {
    let cutoff = Date().addingTimeInterval(-15 * 60)
    return sessions.values
      .filter { session in
        if case .idle = session.status { return false }
        return session.updatedAt >= cutoff
      }
      .sorted(by: sessionSort)
      .prefix(5)
      .map { $0 }
  }

  var shouldShowOverlay: Bool {
    if isExpanded { return !sessionSummaries.isEmpty }
    return displaySession != nil
  }

  func receive(_ event: BridgeEvent) async -> ApprovalDecision? {
    let projectName = await Task.detached(priority: .utility) {
      ProjectNameResolver.resolve(workingDirectory: event.cwd)
    }.value

    switch event.event {
    case .ping:
      eventLogger.record(event: .ping, project: projectName)
      return nil
    case .sessionStart:
      upsertSession(
        id: event.sessionId,
        turnID: event.turnId,
        projectName: projectName,
        cwd: event.cwd,
        model: event.model,
        status: .idle,
        timestamp: event.timestamp
      )
    case .working:
      upsertSession(
        id: event.sessionId,
        turnID: event.turnId,
        projectName: projectName,
        cwd: event.cwd,
        model: event.model,
        status: .working(prompt: event.prompt),
        timestamp: event.timestamp
      )
      isExpanded = false
    case .approvalRequested:
      return await handleApproval(event, projectName: projectName)
    case .completed:
      complete(event, projectName: projectName)
    case .failed:
      fail(event, projectName: projectName)
    }

    eventLogger.record(event: event.event, project: projectName)
    notifyPresentationChanged()
    return nil
  }

  @discardableResult
  func decide(requestID: UUID, decision: ApprovalDecision) -> Bool {
    guard let currentApproval,
      currentApproval.id == requestID,
      !currentApproval.isExpired
    else { return false }
    if approvalCoordinator.resolve(requestID: requestID, decision: decision) { return true }
    guard localDemoApprovalIDs.remove(requestID) != nil else { return false }
    approvalQueue.removeAll { $0.id == requestID }
    if var session = sessions[currentApproval.sessionID] {
      session.status = .idle
      session.updatedAt = Date()
      sessions[session.id] = session
    }
    isExpanded = false
    Task { await capsLockService.cancelAndRestore() }
    notifyPresentationChanged()
    return true
  }

  func toggleExpanded() {
    isExpanded.toggle()
    notifyPresentationChanged()
  }

  func expand() {
    guard !sessionSummaries.isEmpty, !isExpanded else { return }
    isExpanded = true
    notifyPresentationChanged()
  }

  func collapse() {
    guard isExpanded else { return }
    isExpanded = false
    notifyPresentationChanged()
  }

  func dismissCompletion(sessionID: String) {
    guard var session = sessions[sessionID] else { return }
    if case .completed = session.status {
      session.completionVisibleUntil = .distantPast
      sessions[sessionID] = session
      notifyPresentationChanged()
    }
  }

  func reset() {
    approvalCoordinator.deferAll()
    approvalQueue.removeAll()
    seenApprovalRequestIDs.removeAll()
    localDemoApprovalIDs.removeAll()
    sessions.removeAll()
    isExpanded = false
    eventLogger.reset()
    Task.detached(priority: .utility) { LifecycleLedger.clear() }
    Task { await capsLockService.cancelAndRestore() }
    notifyPresentationChanged()
  }

  func testState(_ state: BridgeEventName) {
    let id = "demo-visual-state"
    let now = Date()
    switch state {
    case .working:
      upsertSession(
        id: id, turnID: "demo-turn", projectName: "Scoutly", cwd: "/Demo/Scoutly", model: "gpt-5.6",
        status: .working(prompt: "Refine the match scouting flow"), timestamp: now)
      isExpanded = false
    case .approvalRequested:
      let request = ApprovalRequest(
        id: UUID(),
        sessionID: id,
        turnID: "demo-turn",
        projectName: "ActivityPilot",
        workingDirectory: "/Demo/ActivityPilot",
        toolName: "Bash",
        operationDescription: "Publish the verified branch to the configured GitHub remote",
        fullOperation: "git push -u origin agent/release-readiness",
        requestedAt: now,
        expiresAt: now.addingTimeInterval(settings.approvalTimeout)
      )
      localDemoApprovalIDs.insert(request.id)
      approvalQueue = [request]
      upsertSession(
        id: id, turnID: "demo-turn", projectName: request.projectName,
        cwd: request.workingDirectory, model: nil, status: .awaitingApproval(request),
        timestamp: now)
      isExpanded = true
    case .completed:
      upsertSession(
        id: id, turnID: "demo-turn", projectName: "Meetly", cwd: "/Demo/Meetly", model: nil,
        status: .completed(message: "All checks passed"), timestamp: now)
      var session = sessions[id]!
      session.completionVisibleUntil = now.addingTimeInterval(
        settings.completionVisibility.seconds ?? 86_400)
      sessions[id] = session
      isExpanded = false
    case .failed:
      upsertSession(
        id: id, turnID: "demo-turn", projectName: "Scoutly", cwd: "/Demo/Scoutly", model: nil,
        status: .failed(message: "Build verification failed"), timestamp: now)
      isExpanded = false
    case .sessionStart, .ping:
      reset()
    }
    notifyPresentationChanged()
  }

  func restoreLifecycleSessions(_ recovered: [PersistedLifecycleSession]) async {
    guard !recovered.isEmpty else { return }
    let resolved = await Task.detached(priority: .utility) {
      recovered.map { entry in
        (
          entry,
          ProjectNameResolver.resolve(workingDirectory: entry.workingDirectory)
        )
      }
    }.value
    for (entry, projectName) in resolved where sessions[entry.sessionID] == nil {
      upsertSession(
        id: entry.sessionID,
        turnID: entry.turnID,
        projectName: projectName,
        cwd: entry.workingDirectory,
        model: entry.model,
        status: .working(prompt: nil),
        timestamp: entry.updatedAt
      )
    }
    notifyPresentationChanged()
  }

  func testMultipleSessions() {
    approvalCoordinator.deferAll()
    approvalQueue.removeAll()
    localDemoApprovalIDs.removeAll()
    sessions.removeAll()
    let now = Date()
    upsertSession(
      id: "demo-primary", turnID: "demo-turn-1", projectName: "Scoutly",
      cwd: "/Demo/Scoutly", model: "gpt-5.6",
      status: .working(prompt: "Verify the release build"), timestamp: now)
    upsertSession(
      id: "demo-secondary", turnID: "demo-turn-2", projectName: "ActivityPilot",
      cwd: "/Demo/ActivityPilot", model: "gpt-5.6",
      status: .working(prompt: "Review the diagnostics flow"),
      timestamp: now.addingTimeInterval(0.01))
    isExpanded = true
    notifyPresentationChanged()
  }

  private func handleApproval(_ event: BridgeEvent, projectName: String) async -> ApprovalDecision {
    let replayCutoff = Date().addingTimeInterval(-15 * 60)
    let retainedRequestIDs = seenApprovalRequestIDs.filter { $0.value >= replayCutoff }
    seenApprovalRequestIDs = retainedRequestIDs
    guard seenApprovalRequestIDs[event.requestId] == nil else {
      eventLogger.record(event: .approvalRequested, project: projectName, outcome: "duplicate")
      return .deferDecision
    }
    seenApprovalRequestIDs[event.requestId] = Date()

    let fullOperation =
      event.toolInput?.prettyPrinted() ?? event.humanDescription ?? "Approval requested"
    let description =
      event.humanDescription
      ?? event.toolInput?.objectValue?["description"]?.stringValue
      ?? displayOperation(from: event.toolInput)
    let request = ApprovalRequest(
      id: event.requestId,
      sessionID: event.sessionId,
      turnID: event.turnId,
      projectName: projectName,
      workingDirectory: event.cwd,
      toolName: event.toolName ?? "Codex tool",
      operationDescription: description,
      fullOperation: fullOperation,
      requestedAt: event.timestamp,
      expiresAt: event.timestamp.addingTimeInterval(settings.approvalTimeout)
    )

    guard !request.isExpired else {
      eventLogger.record(event: .approvalRequested, project: projectName, outcome: "expired")
      return .deferDecision
    }

    approvalQueue.append(request)
    approvalQueue.sort { $0.requestedAt < $1.requestedAt }
    upsertSession(
      id: event.sessionId,
      turnID: event.turnId,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .awaitingApproval(request),
      timestamp: event.timestamp
    )
    if settings.autoExpandApprovals { isExpanded = true }
    eventLogger.record(event: .approvalRequested, project: projectName)
    if settings.capsLockEnabled { await capsLockService.start(.approval) }
    notifyPresentationChanged()

    let decision = await approvalCoordinator.waitForDecision(for: request)
    approvalQueue.removeAll { $0.id == request.id }

    if let next = approvalQueue.first(where: { $0.sessionID == request.sessionID }),
      var session = sessions[request.sessionID]
    {
      session.status = .awaitingApproval(next)
      session.updatedAt = Date()
      sessions[request.sessionID] = session
    } else if var session = sessions[request.sessionID],
      case .awaitingApproval(let pending) = session.status,
      pending.id == request.id
    {
      session.status = decision == .deferDecision ? .idle : .working(prompt: nil)
      session.updatedAt = Date()
      sessions[request.sessionID] = session
    }

    if decision == .deny {
      if settings.capsLockEnabled { await capsLockService.start(.failure) }
    } else if approvalQueue.isEmpty {
      await capsLockService.cancelAndRestore()
    }
    if approvalQueue.isEmpty { isExpanded = false }
    eventLogger.record(event: .approvalRequested, project: projectName, outcome: decision.rawValue)
    notifyPresentationChanged()
    return decision
  }

  private func complete(_ event: BridgeEvent, projectName: String) {
    deferApprovals(for: event.sessionId)
    let message = settings.showResultPreviews ? event.lastAssistantMessage : nil
    upsertSession(
      id: event.sessionId,
      turnID: event.turnId,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .completed(message: message),
      timestamp: event.timestamp
    )
    let visibility = settings.completionVisibility.seconds
    var session = sessions[event.sessionId]!
    let visibleUntil = visibility.map { Date().addingTimeInterval($0) } ?? .distantFuture
    session.completionVisibleUntil = visibleUntil
    sessions[event.sessionId] = session
    isExpanded = false
    if settings.capsLockEnabled { Task { await capsLockService.start(.completion) } }

    if let visibility {
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(visibility))
        guard let self,
          var current = self.sessions[event.sessionId],
          case .completed = current.status,
          current.completionVisibleUntil == visibleUntil
        else { return }
        current.completionVisibleUntil = .distantPast
        self.sessions[event.sessionId] = current
        self.notifyPresentationChanged()
      }
    }
    scheduleStaleRemoval(sessionID: event.sessionId, updatedAt: event.timestamp)
  }

  private func fail(_ event: BridgeEvent, projectName: String) {
    deferApprovals(for: event.sessionId)
    upsertSession(
      id: event.sessionId,
      turnID: event.turnId,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .failed(message: event.errorMessage),
      timestamp: event.timestamp
    )
    if settings.capsLockEnabled { Task { await capsLockService.start(.failure) } }
    scheduleStaleRemoval(sessionID: event.sessionId, updatedAt: event.timestamp)
  }

  private func upsertSession(
    id: String,
    turnID: String?,
    projectName: String,
    cwd: String,
    model: String?,
    status: AgentStatus,
    timestamp: Date
  ) {
    let existing = sessions[id]
    sessions[id] = AgentSession(
      id: id,
      turnID: turnID ?? existing?.turnID,
      projectName: projectName,
      workingDirectory: cwd,
      model: model ?? existing?.model,
      status: status,
      updatedAt: timestamp,
      completionVisibleUntil: existing?.completionVisibleUntil
    )
  }

  private func deferApprovals(for sessionID: String) {
    let requestIDs = approvalQueue.filter { $0.sessionID == sessionID }.map(\.id)
    for requestID in requestIDs {
      approvalCoordinator.resolve(requestID: requestID, decision: .deferDecision)
    }
    approvalQueue.removeAll { $0.sessionID == sessionID }
  }

  private func scheduleStaleRemoval(sessionID: String, updatedAt: Date) {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(15 * 60))
      guard let self, self.sessions[sessionID]?.updatedAt == updatedAt else { return }
      self.sessions.removeValue(forKey: sessionID)
      self.notifyPresentationChanged()
    }
  }

  private func displayOperation(from input: JSONValue?) -> String {
    guard let input else { return "Approval requested" }
    if let command = input.objectValue?["command"]?.stringValue { return command }
    return input.prettyPrinted()
  }

  private func sessionSort(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
    if lhs.status.priority != rhs.status.priority {
      return lhs.status.priority > rhs.status.priority
    }
    return lhs.updatedAt > rhs.updatedAt
  }

  private func notifyPresentationChanged() {
    presentationDidChange?()
  }
}
