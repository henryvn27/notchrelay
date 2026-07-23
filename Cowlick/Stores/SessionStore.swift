import Foundation
import Observation

enum IntegrationSelfTestOwner: Equatable {
  case diagnostics
  case onboarding
}

struct IntegrationSelfTestLease: Equatable {
  fileprivate let id = UUID()
  let owner: IntegrationSelfTestOwner
}

@MainActor
@Observable
final class SessionStore {
  private static let authoritativeSequenceBit: UInt64 = 1 << 63

  private struct ParentEventOrder {
    let turnID: String?
    let timestamp: Date
    let origin: BridgeEventOrigin
    let deliverySequence: UInt64
  }

  private struct SubagentOrderingKey: Hashable {
    let sessionID: String
    let agentID: String
  }

  private(set) var sessions: [String: AgentSession] = [:]
  private(set) var approvalQueue: [ApprovalRequest] = []
  private var seenApprovalRequestIDs: [UUID: Date] = [:]
  private var localDemoApprovalIDs: Set<UUID> = []
  private var localDemoSessionIDs: Set<String> = []
  private var integrationDemoSessionIDs: Set<String> = []
  private var ignoredIntegrationDemoSessionIDs: Set<String> = []
  private var integrationSelfTestLease: IntegrationSelfTestLease?
  private var integrationSelfTestCancelled = false
  private var nextLocalDeliverySequence: UInt64 = 0
  private var nextHookDeliverySequence: UInt64 = 0
  private var latestParentEventOrder: [String: ParentEventOrder] = [:]
  private var latestSubagentBoundarySequence: [String: UInt64] = [:]
  private var latestSubagentEventSequence: [SubagentOrderingKey: UInt64] = [:]
  private var locallyObservedTurns: [String: String] = [:]
  private var unreadCompletionSessionIDs: Set<String> = []
  private var capsLockAttentionPattern: CapsLockPattern?
  private var chatTitleRefreshGeneration: UInt64 = 0
  private var pinnedThreadRefreshGeneration: UInt64 = 0
  private var pinnedThreadIDs: Set<String> = []
  private var pinnedThreadStateIsAvailable = false
  var isExpanded = false
  var presentationDidChange: (() -> Void)?

  let settings: SettingsStore
  let eventLogger: EventLogger
  let approvalCoordinator: ApprovalCoordinator
  let capsLockService: any CapsLockSignalService
  private let resolveChatTitle: @Sendable (String, Bool) -> String?
  private let resolvePinnedThreadIDs: @Sendable () -> Set<String>?

  init(
    settings: SettingsStore = SettingsStore(),
    eventLogger: EventLogger = EventLogger(),
    approvalCoordinator: ApprovalCoordinator = ApprovalCoordinator(),
    capsLockService: any CapsLockSignalService = NativeCapsLockSignalService(),
    resolveChatTitle: @escaping @Sendable (String, Bool) -> String? = {
      CodexThreadTitleReader().title(for: $0, allowPromptDerivedFallback: $1)
    },
    resolvePinnedThreadIDs: @escaping @Sendable () -> Set<String>? = {
      CodexPinnedThreadReader().threadIDs()
    }
  ) {
    self.settings = settings
    self.eventLogger = eventLogger
    self.approvalCoordinator = approvalCoordinator
    self.capsLockService = capsLockService
    self.resolveChatTitle = resolveChatTitle
    self.resolvePinnedThreadIDs = resolvePinnedThreadIDs
  }

  var currentApproval: ApprovalRequest? { approvalQueue.first }

  var integrationSelfTestInProgress: Bool { integrationSelfTestLease != nil }

  var activeSessionCount: Int {
    sessions.values.filter { $0.isActive && isVisibleSession($0) }.count
  }

  var activeSubagentCount: Int {
    sessions.values.filter { !$0.isRecovered && isVisibleSession($0) }
      .reduce(0) { $0 + $1.subagents.count }
  }

  var canPreviewTestStates: Bool {
    guard approvalQueue.allSatisfy({ localDemoApprovalIDs.contains($0.id) }) else { return false }
    return sessions.values.allSatisfy { session in
      guard !localDemoSessionIDs.contains(session.id) else { return true }
      return switch session.presentationStatus {
      case .working, .awaitingApproval, .failed: false
      case .idle, .completed: true
      }
    }
  }

  var displaySession: AgentSession? {
    sessions.values
      .filter { session in
        guard isVisibleSession(session) else { return false }
        if session.isRecovered { return false }
        if case .completed = session.presentationStatus {
          return (session.completionVisibleUntil ?? .distantPast) > Date()
        }
        if case .idle = session.presentationStatus { return false }
        return true
      }
      .sorted(by: sessionSort)
      .first
  }

  var sessionSummaries: [AgentSession] {
    let now = Date()
    let cutoff = now.addingTimeInterval(-15 * 60)
    let recoveredCutoff = now.addingTimeInterval(-LifecycleLedger.staleInterval)
    return sessions.values
      .filter { session in
        guard isVisibleSession(session) else { return false }
        if case .idle = session.presentationStatus { return false }
        if session.isRecovered { return session.updatedAt >= recoveredCutoff }
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
    let deliverySequence = registerDeliverySequence(for: event)
    let titleResolver = resolveChatTitle
    let showChatNames = settings.showChatNames
    let allowPromptDerivedTitle = settings.showPromptPreviews
    let metadata = await Task.detached(priority: .utility) {
      (
        projectName: ProjectNameResolver.resolve(workingDirectory: event.cwd),
        chatTitle: showChatNames ? titleResolver(event.sessionId, allowPromptDerivedTitle) : nil
      )
    }.value
    let projectName = metadata.projectName
    let chatTitle =
      settings.showChatNames && settings.showPromptPreviews == allowPromptDerivedTitle
      ? metadata.chatTitle : nil
    if !settings.showChatNames { clearChatTitles() }
    if ignoredIntegrationDemoSessionIDs.contains(event.sessionId) { return nil }
    let isIntegrationDemo = integrationDemoSessionIDs.contains(event.sessionId)
    if isIntegrationDemo, !localDemoSessionIDs.contains(event.sessionId) { return nil }
    clearLocalDemoState(preservingSessionID: isIntegrationDemo ? event.sessionId : nil)
    switch event.event {
    case .ping:
      eventLogger.record(event: .ping, project: projectName)
      notifyPresentationChanged()
      return nil
    case .sessionStart:
      guard acceptParentEvent(event, deliverySequence: deliverySequence) else {
        recordIgnored(event, projectName: projectName)
        return nil
      }
      upsertSession(
        id: event.sessionId,
        turnID: event.turnId,
        chatTitle: chatTitle,
        projectName: projectName,
        cwd: event.cwd,
        model: event.model,
        status: .idle,
        timestamp: event.timestamp
      )
      clearSubagents(
        in: event.sessionId, throughDeliverySequence: deliverySequence)
    case .working:
      if event.agentId != nil {
        guard
          upsertSubagent(
            event, chatTitle: chatTitle, projectName: projectName,
            deliverySequence: deliverySequence)
        else {
          recordIgnored(event, projectName: projectName)
          return nil
        }
      } else {
        guard acceptParentEvent(event, deliverySequence: deliverySequence) else {
          recordIgnored(event, projectName: projectName)
          return nil
        }
        upsertSession(
          id: event.sessionId,
          turnID: event.turnId,
          chatTitle: chatTitle,
          projectName: projectName,
          cwd: event.cwd,
          model: event.model,
          status: .working(prompt: event.prompt),
          timestamp: event.timestamp
        )
        clearSubagents(
          in: event.sessionId, throughDeliverySequence: deliverySequence)
      }
      isExpanded = false
    case .approvalRequested:
      guard acceptParentEvent(event, deliverySequence: deliverySequence) else {
        recordIgnored(event, projectName: projectName)
        return .deferDecision
      }
      return await handleApproval(event, chatTitle: chatTitle, projectName: projectName)
    case .subagentStarted:
      guard
        upsertSubagent(
          event, chatTitle: chatTitle, projectName: projectName,
          deliverySequence: deliverySequence)
      else {
        recordIgnored(event, projectName: projectName)
        return nil
      }
    case .subagentStopped:
      guard stopSubagent(event, deliverySequence: deliverySequence) else {
        recordIgnored(event, projectName: projectName)
        return nil
      }
    case .completed:
      guard acceptParentEvent(event, deliverySequence: deliverySequence) else {
        recordIgnored(event, projectName: projectName)
        return nil
      }
      let shouldSignal = !matchesTerminalState(event, completed: true)
      complete(
        event,
        chatTitle: chatTitle,
        projectName: projectName,
        deliverySequence: deliverySequence,
        shouldSignal: shouldSignal
      )
      if isIntegrationDemo { integrationDemoSessionIDs.remove(event.sessionId) }
    case .failed:
      guard acceptParentEvent(event, deliverySequence: deliverySequence) else {
        recordIgnored(event, projectName: projectName)
        return nil
      }
      let shouldSignal = !matchesTerminalState(event, completed: false)
      fail(
        event,
        chatTitle: chatTitle,
        projectName: projectName,
        deliverySequence: deliverySequence,
        shouldSignal: shouldSignal
      )
    }

    updateLocalObservationOwnership(for: event)
    eventLogger.record(
      event: event.event,
      project: projectName,
      outcome: event.origin == .localObservation ? "observed" : "accepted"
    )
    notifyPresentationChanged()
    return nil
  }

  func refreshPinnedThreadIDs() async {
    pinnedThreadRefreshGeneration &+= 1
    let generation = pinnedThreadRefreshGeneration
    let resolver = resolvePinnedThreadIDs
    let resolved = await Task.detached(priority: .utility) { resolver() }.value
    guard generation == pinnedThreadRefreshGeneration else { return }
    guard let resolved else {
      if pinnedThreadStateIsAvailable {
        pinnedThreadStateIsAvailable = false
        notifyPresentationChanged()
      }
      return
    }
    let changed = !pinnedThreadStateIsAvailable || pinnedThreadIDs != resolved
    pinnedThreadIDs = resolved
    pinnedThreadStateIsAvailable = true
    if changed { notifyPresentationChanged() }
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
    if isExpanded { markVisibleCompletionsRead() }
    notifyPresentationChanged()
  }

  func expand() {
    guard !sessionSummaries.isEmpty, !isExpanded else { return }
    isExpanded = true
    markVisibleCompletionsRead()
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
      unreadCompletionSessionIDs.remove(sessionID)
      notifyPresentationChanged()
    }
  }

  func reset() {
    approvalCoordinator.deferAll()
    approvalQueue.removeAll()
    seenApprovalRequestIDs.removeAll()
    localDemoApprovalIDs.removeAll()
    localDemoSessionIDs.removeAll()
    ignoredIntegrationDemoSessionIDs.formUnion(integrationDemoSessionIDs)
    integrationDemoSessionIDs.removeAll()
    integrationSelfTestCancelled = integrationSelfTestLease != nil
    sessions.removeAll()
    latestParentEventOrder.removeAll()
    latestSubagentBoundarySequence.removeAll()
    latestSubagentEventSequence.removeAll()
    locallyObservedTurns.removeAll()
    unreadCompletionSessionIDs.removeAll()
    isExpanded = false
    eventLogger.reset()
    Task.detached(priority: .utility) { LifecycleLedger.clear() }
    Task { await capsLockService.cancelAndRestore() }
    notifyPresentationChanged()
  }

  func updateChatNameVisibility(_ isVisible: Bool) async {
    guard isVisible == settings.showChatNames else { return }
    await refreshChatNames()
  }

  func refreshChatNames() async {
    chatTitleRefreshGeneration &+= 1
    let generation = chatTitleRefreshGeneration
    let showChatNames = settings.showChatNames
    guard showChatNames else {
      clearChatTitles()
      notifyPresentationChanged()
      return
    }

    let sessionIDs = Array(sessions.keys)
    let titleResolver = resolveChatTitle
    let allowPromptDerivedTitle = settings.showPromptPreviews
    let titles = await Task.detached(priority: .utility) {
      Dictionary(
        uniqueKeysWithValues: sessionIDs.compactMap { id in
          titleResolver(id, allowPromptDerivedTitle).map { (id, $0) }
        })
    }.value
    guard generation == chatTitleRefreshGeneration,
      settings.showChatNames == showChatNames,
      settings.showPromptPreviews == allowPromptDerivedTitle
    else { return }
    for id in sessionIDs where sessions[id] != nil {
      sessions[id]?.chatTitle = titles[id]
    }
    for index in approvalQueue.indices {
      let request = approvalQueue[index]
      approvalQueue[index] = request.with(chatTitle: titles[request.sessionID])
    }
    for (id, session) in sessions {
      guard case .awaitingApproval(let request) = session.status,
        let current = approvalQueue.first(where: { $0.id == request.id })
      else { continue }
      sessions[id]?.status = .awaitingApproval(current)
    }
    notifyPresentationChanged()
  }

  private func clearChatTitles() {
    for id in sessions.keys {
      sessions[id]?.chatTitle = nil
      guard case .awaitingApproval(let request) = sessions[id]?.status else { continue }
      sessions[id]?.status = .awaitingApproval(request.with(chatTitle: nil))
    }
    for index in approvalQueue.indices {
      approvalQueue[index] = approvalQueue[index].with(chatTitle: nil)
    }
  }

  private func isVisibleSession(_ session: AgentSession) -> Bool {
    guard settings.showOnlyPinnedSessions, pinnedThreadStateIsAvailable else { return true }
    if case .awaitingApproval = session.presentationStatus { return true }
    return pinnedThreadIDs.contains(session.id.lowercased())
  }

  func expireLocalObservation(sessionID: String, turnID: String?) {
    let key = turnID ?? ""
    guard locallyObservedTurns[sessionID] == key,
      let session = sessions[sessionID],
      session.turnID == turnID,
      session.subagents.isEmpty,
      case .working = session.presentationStatus
    else { return }
    locallyObservedTurns.removeValue(forKey: sessionID)
    sessions.removeValue(forKey: sessionID)
    latestParentEventOrder.removeValue(forKey: sessionID)
    notifyPresentationChanged()
  }

  func testState(_ state: BridgeEventName) {
    guard canPreviewTestStates else { return }
    clearLocalDemoState()
    let id = "demo-visual-state"
    let now = Date()
    switch state {
    case .working:
      localDemoSessionIDs.insert(id)
      upsertSession(
        id: id, turnID: "demo-turn", chatTitle: demoChatTitle("Polish release onboarding"),
        projectName: "Scoutly", cwd: "/Demo/Scoutly", model: "gpt-5.6",
        status: .working(prompt: "Refine the match scouting flow"), timestamp: now)
      isExpanded = false
    case .approvalRequested:
      let request = ApprovalRequest(
        id: UUID(),
        sessionID: id,
        turnID: "demo-turn",
        chatTitle: demoChatTitle("Ship the verified release"),
        projectName: "ActivityPilot",
        workingDirectory: "/Demo/ActivityPilot",
        toolName: "Bash",
        operationDescription: "Publish the verified branch to the configured GitHub remote",
        operationSummary: "git push -u origin agent/release-readiness",
        fullOperation: "git push -u origin agent/release-readiness",
        requestedAt: now,
        expiresAt: now.addingTimeInterval(settings.approvalTimeout)
      )
      localDemoApprovalIDs.insert(request.id)
      localDemoSessionIDs.insert(id)
      approvalQueue.append(request)
      upsertSession(
        id: id, turnID: "demo-turn", chatTitle: request.chatTitle,
        projectName: request.projectName,
        cwd: request.workingDirectory, model: nil, status: .awaitingApproval(request),
        timestamp: now)
      isExpanded = true
    case .completed:
      localDemoSessionIDs.insert(id)
      upsertSession(
        id: id, turnID: "demo-turn", chatTitle: demoChatTitle("Verify installation flow"),
        projectName: "Meetly", cwd: "/Demo/Meetly", model: nil,
        status: .completed(message: "All checks passed"), timestamp: now)
      var session = sessions[id]!
      session.completionVisibleUntil = now.addingTimeInterval(
        settings.completionVisibility.seconds ?? 86_400)
      sessions[id] = session
      isExpanded = false
    case .failed:
      localDemoSessionIDs.insert(id)
      upsertSession(
        id: id, turnID: "demo-turn", chatTitle: demoChatTitle("Repair bridge health"),
        projectName: "Scoutly", cwd: "/Demo/Scoutly", model: nil,
        status: .failed(message: "Bridge self-test failed"), timestamp: now)
      isExpanded = false
    case .sessionStart, .subagentStarted, .subagentStopped, .ping:
      break
    }
    notifyPresentationChanged()
  }

  func restoreLifecycleSessions(_ recovered: [PersistedLifecycleSession]) async {
    guard !recovered.isEmpty else { return }
    let titleResolver = resolveChatTitle
    let showChatNames = settings.showChatNames
    let allowPromptDerivedTitle = settings.showPromptPreviews
    let resolved = await Task.detached(priority: .utility) {
      recovered.map { entry in
        (
          entry,
          ProjectNameResolver.resolve(workingDirectory: entry.workingDirectory),
          showChatNames ? titleResolver(entry.sessionID, allowPromptDerivedTitle) : nil
        )
      }
    }.value
    clearLocalDemoState()
    for (entry, projectName, resolvedChatTitle) in resolved where sessions[entry.sessionID] == nil {
      upsertSession(
        id: entry.sessionID,
        turnID: entry.turnID,
        chatTitle: settings.showChatNames && settings.showPromptPreviews == allowPromptDerivedTitle
          ? resolvedChatTitle : nil,
        projectName: projectName,
        cwd: entry.workingDirectory,
        model: entry.model,
        status: .working(prompt: nil),
        timestamp: entry.updatedAt,
        isRecovered: true
      )
    }
    notifyPresentationChanged()
  }

  func testMultipleSessions() {
    guard canPreviewTestStates else { return }
    clearLocalDemoState()
    let now = Date()
    localDemoSessionIDs.formUnion(["demo-primary", "demo-secondary"])
    upsertSession(
      id: "demo-primary", turnID: "demo-turn-1",
      chatTitle: demoChatTitle("Prepare the release candidate"),
      projectName: "Scoutly",
      cwd: "/Demo/Scoutly", model: "gpt-5.6",
      status: .working(prompt: "Verify the release build"), timestamp: now)
    upsertSession(
      id: "demo-secondary", turnID: "demo-turn-2",
      chatTitle: demoChatTitle("Review diagnostics privacy"),
      projectName: "ActivityPilot",
      cwd: "/Demo/ActivityPilot", model: "gpt-5.6",
      status: .working(prompt: "Review the diagnostics flow"),
      timestamp: now.addingTimeInterval(0.01))
    isExpanded = true
    notifyPresentationChanged()
  }

  func testOverflowSessions() {
    guard canPreviewTestStates else { return }
    clearLocalDemoState()
    let now = Date()
    let demos = [
      ("demo-overflow-1", "Polish notch motion", "Cowlick"),
      ("demo-overflow-2", "Verify release hooks", "Scoutly"),
      ("demo-overflow-3", "Review diagnostics", "ActivityPilot"),
      ("demo-overflow-4", "Prepare website copy", "Cowlick Web"),
    ]
    localDemoSessionIDs.formUnion(demos.map(\.0))
    for (index, demo) in demos.enumerated() {
      upsertSession(
        id: demo.0,
        turnID: "demo-overflow-turn-\(index + 1)",
        chatTitle: demoChatTitle(demo.1),
        projectName: demo.2,
        cwd: "/Demo/\(demo.2.replacingOccurrences(of: " ", with: ""))",
        model: "gpt-5.6",
        status: .working(prompt: demo.1),
        timestamp: now.addingTimeInterval(Double(index) * 0.01)
      )
    }
    isExpanded = true
    notifyPresentationChanged()
  }

  private func demoChatTitle(_ value: String) -> String? {
    settings.showChatNames ? value : nil
  }

  @discardableResult
  func beginIntegrationSelfTest(owner: IntegrationSelfTestOwner) -> IntegrationSelfTestLease? {
    guard integrationSelfTestLease == nil, canPreviewTestStates else { return nil }
    let lease = IntegrationSelfTestLease(owner: owner)
    integrationSelfTestLease = lease
    integrationSelfTestCancelled = false
    return lease
  }

  func isIntegrationSelfTestActive(_ lease: IntegrationSelfTestLease) -> Bool {
    integrationSelfTestLease == lease && !integrationSelfTestCancelled
  }

  func finishIntegrationSelfTest(_ lease: IntegrationSelfTestLease) {
    guard integrationSelfTestLease == lease else { return }
    integrationSelfTestLease = nil
    integrationSelfTestCancelled = false
  }

  @discardableResult
  func beginIntegrationDemoSession(_ sessionID: String, lease: IntegrationSelfTestLease) -> Bool {
    guard isIntegrationSelfTestActive(lease),
      integrationDemoSessionIDs.isEmpty,
      canPreviewTestStates
    else { return false }
    clearLocalDemoState()
    ignoredIntegrationDemoSessionIDs.remove(sessionID)
    integrationDemoSessionIDs.insert(sessionID)
    localDemoSessionIDs.insert(sessionID)
    return true
  }

  func isIntegrationDemoSessionActive(_ sessionID: String) -> Bool {
    integrationDemoSessionIDs.contains(sessionID) && localDemoSessionIDs.contains(sessionID)
  }

  func hasObservedIntegrationDemoEvent(_ event: IntegrationDemoEvent, sessionID: String) -> Bool {
    guard localDemoSessionIDs.contains(sessionID),
      !ignoredIntegrationDemoSessionIDs.contains(sessionID),
      let session = sessions[sessionID]
    else {
      return false
    }
    return switch (event, session.status) {
    case (.working, .working), (.completed, .completed): true
    default: false
    }
  }

  func finishIntegrationDemoSession(_ sessionID: String, discardPresentedState: Bool) {
    guard discardPresentedState else { return }
    integrationDemoSessionIDs.remove(sessionID)
    ignoredIntegrationDemoSessionIDs.insert(sessionID)
    guard localDemoSessionIDs.remove(sessionID) != nil else { return }
    let requestIDs = Set(
      approvalQueue
        .filter { $0.sessionID == sessionID && localDemoApprovalIDs.contains($0.id) }
        .map(\.id)
    )
    approvalQueue.removeAll { requestIDs.contains($0.id) }
    localDemoApprovalIDs.subtract(requestIDs)
    let removedSession = sessions.removeValue(forKey: sessionID) != nil
    if removedSession || !requestIDs.isEmpty { notifyPresentationChanged() }
  }

  private func clearLocalDemoState(preservingSessionID: String? = nil) {
    approvalQueue.removeAll { localDemoApprovalIDs.contains($0.id) }
    localDemoApprovalIDs.removeAll()
    for sessionID in localDemoSessionIDs where sessionID != preservingSessionID {
      sessions.removeValue(forKey: sessionID)
    }
    if let preservingSessionID, localDemoSessionIDs.contains(preservingSessionID) {
      localDemoSessionIDs = [preservingSessionID]
    } else {
      localDemoSessionIDs.removeAll()
    }
  }

  private func handleApproval(
    _ event: BridgeEvent,
    chatTitle: String?,
    projectName: String
  ) async -> ApprovalDecision {
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
    let reason =
      event.humanDescription
      ?? event.toolInput?.objectValue?["description"]?.stringValue
      ?? "Approval requested"
    let operationSummary = displayOperation(from: event.toolInput)
    let request = ApprovalRequest(
      id: event.requestId,
      sessionID: event.sessionId,
      turnID: event.turnId,
      chatTitle: chatTitle,
      projectName: projectName,
      workingDirectory: event.cwd,
      toolName: event.toolName ?? "Codex tool",
      operationDescription: reason,
      operationSummary: operationSummary,
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
      chatTitle: chatTitle,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .awaitingApproval(request),
      timestamp: event.timestamp
    )
    if settings.autoExpandApprovals { isExpanded = true }
    eventLogger.record(event: .approvalRequested, project: projectName)
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

  private func complete(
    _ event: BridgeEvent,
    chatTitle: String?,
    projectName: String,
    deliverySequence: UInt64,
    shouldSignal: Bool = true
  ) {
    deferApprovals(for: event.sessionId)
    let message = settings.showResultPreviews ? event.lastAssistantMessage : nil
    upsertSession(
      id: event.sessionId,
      turnID: event.turnId,
      chatTitle: chatTitle,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .completed(message: message),
      timestamp: event.timestamp
    )
    clearSubagents(
      in: event.sessionId, throughDeliverySequence: deliverySequence)
    let visibility = settings.completionVisibility.seconds
    var session = sessions[event.sessionId]!
    let visibleUntil = visibility.map { Date().addingTimeInterval($0) } ?? .distantFuture
    session.completionVisibleUntil = visibleUntil
    sessions[event.sessionId] = session
    if shouldSignal { unreadCompletionSessionIDs.insert(event.sessionId) }
    if shouldSignal, settings.capsLockEnabled {
      let flashCount = settings.capsLockFlashCount
      Task { await capsLockService.start(.completion(flashes: flashCount)) }
    }
    isExpanded = false

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
    scheduleStaleRemoval(sessionID: event.sessionId, updatedAt: session.updatedAt)
  }

  private func fail(
    _ event: BridgeEvent,
    chatTitle: String?,
    projectName: String,
    deliverySequence: UInt64,
    shouldSignal: Bool = true
  ) {
    deferApprovals(for: event.sessionId)
    upsertSession(
      id: event.sessionId,
      turnID: event.turnId,
      chatTitle: chatTitle,
      projectName: projectName,
      cwd: event.cwd,
      model: event.model,
      status: .failed(message: event.errorMessage),
      timestamp: event.timestamp
    )
    clearSubagents(
      in: event.sessionId, throughDeliverySequence: deliverySequence)
    if shouldSignal, settings.capsLockEnabled {
      Task { await capsLockService.start(.failure) }
    }
    scheduleStaleRemoval(
      sessionID: event.sessionId,
      updatedAt: sessions[event.sessionId]?.updatedAt ?? event.timestamp)
  }

  private func upsertSession(
    id: String,
    turnID: String?,
    chatTitle: String? = nil,
    projectName: String,
    cwd: String,
    model: String?,
    status: AgentStatus,
    timestamp: Date,
    isRecovered: Bool = false,
    preserveSubagents: Bool = true
  ) {
    let existing = sessions[id]
    sessions[id] = AgentSession(
      id: id,
      turnID: turnID ?? existing?.turnID,
      chatTitle: chatTitle,
      projectName: projectName,
      workingDirectory: cwd,
      model: model ?? existing?.model,
      subagents: preserveSubagents ? existing?.subagents ?? [:] : [:],
      status: status,
      updatedAt: max(timestamp, existing?.updatedAt ?? .distantPast),
      completionVisibleUntil: existing?.completionVisibleUntil,
      isRecovered: isRecovered
    )
  }

  @discardableResult
  private func upsertSubagent(
    _ event: BridgeEvent,
    chatTitle: String?,
    projectName: String,
    deliverySequence: UInt64
  ) -> Bool {
    if event.origin == .localObservation,
      sessions[event.sessionId]?.status.isAwaitingApproval == true
    {
      return false
    }
    guard let agentID = event.agentId, !agentID.isEmpty,
      let agentType = event.agentType, !agentType.isEmpty,
      let turnID = event.turnId, !turnID.isEmpty
    else { return false }

    let orderingKey = SubagentOrderingKey(sessionID: event.sessionId, agentID: agentID)
    guard deliverySequence > latestSubagentBoundarySequence[event.sessionId, default: 0],
      deliverySequence > latestSubagentEventSequence[orderingKey, default: 0]
    else { return false }
    latestSubagentEventSequence[orderingKey] = deliverySequence

    if sessions[event.sessionId] == nil {
      upsertSession(
        id: event.sessionId,
        turnID: turnID,
        chatTitle: chatTitle,
        projectName: projectName,
        cwd: event.cwd,
        model: event.model,
        status: .idle,
        timestamp: event.timestamp
      )
    }
    guard var session = sessions[event.sessionId] else { return false }
    session.subagents[agentID] = SubagentActivity(
      id: agentID, turnID: turnID, deliverySequence: deliverySequence, updatedAt: event.timestamp)
    session.updatedAt = max(session.updatedAt, event.timestamp)
    session.isRecovered = false
    sessions[event.sessionId] = session
    return true
  }

  @discardableResult
  private func stopSubagent(_ event: BridgeEvent, deliverySequence: UInt64) -> Bool {
    if event.origin == .localObservation,
      sessions[event.sessionId]?.status.isAwaitingApproval == true
    {
      return false
    }
    guard let agentID = event.agentId,
      let turnID = event.turnId
    else { return false }
    let orderingKey = SubagentOrderingKey(sessionID: event.sessionId, agentID: agentID)
    guard deliverySequence > latestSubagentBoundarySequence[event.sessionId, default: 0],
      deliverySequence > latestSubagentEventSequence[orderingKey, default: 0]
    else { return false }
    latestSubagentEventSequence[orderingKey] = deliverySequence
    guard
      var session = sessions[event.sessionId],
      session.subagents[agentID]?.turnID == turnID
    else { return false }
    session.subagents.removeValue(forKey: agentID)
    session.updatedAt = max(session.updatedAt, event.timestamp)
    sessions[event.sessionId] = session
    if session.subagents.isEmpty {
      switch session.status {
      case .idle, .completed, .failed:
        scheduleStaleRemoval(sessionID: event.sessionId, updatedAt: session.updatedAt)
      case .working, .awaitingApproval:
        break
      }
    }
    return true
  }

  private func registerDeliverySequence(for event: BridgeEvent) -> UInt64 {
    if event.origin == .hook {
      let acceptedSequence: UInt64
      if let deliverySequence = event.deliverySequence {
        nextHookDeliverySequence = max(nextHookDeliverySequence, deliverySequence)
        acceptedSequence = deliverySequence
      } else {
        nextHookDeliverySequence = min(
          nextHookDeliverySequence + 1,
          Self.authoritativeSequenceBit - 1
        )
        acceptedSequence = nextHookDeliverySequence
      }
      return Self.authoritativeSequenceBit
        | min(acceptedSequence, Self.authoritativeSequenceBit - 1)
    }
    nextLocalDeliverySequence =
      (nextLocalDeliverySequence + 1)
      & (Self.authoritativeSequenceBit - 1)
    if nextLocalDeliverySequence == 0 { nextLocalDeliverySequence = 1 }
    return nextLocalDeliverySequence
  }

  private func acceptParentEvent(_ event: BridgeEvent, deliverySequence: UInt64) -> Bool {
    if event.origin == .localObservation,
      sessions[event.sessionId]?.status.isAwaitingApproval == true
    {
      return false
    }
    if let latest = latestParentEventOrder[event.sessionId] {
      if latest.turnID == event.turnId {
        if latest.origin == .hook, event.origin == .localObservation { return false }
        if latest.origin == event.origin,
          deliverySequence <= latest.deliverySequence
        {
          return false
        }
      } else {
        guard event.timestamp >= latest.timestamp else { return false }
        resetOrderingForNewTurn(sessionID: event.sessionId)
      }
    }
    latestParentEventOrder[event.sessionId] = ParentEventOrder(
      turnID: event.turnId,
      timestamp: event.timestamp,
      origin: event.origin,
      deliverySequence: deliverySequence
    )
    if event.origin == .hook {
      locallyObservedTurns.removeValue(forKey: event.sessionId)
    }
    return true
  }

  private func clearSubagents(in sessionID: String, throughDeliverySequence: UInt64) {
    latestSubagentBoundarySequence[sessionID] = max(
      latestSubagentBoundarySequence[sessionID, default: 0], throughDeliverySequence)
    guard var session = sessions[sessionID] else { return }
    let removedAgentIDs = session.subagents.values
      .filter { $0.deliverySequence <= throughDeliverySequence }
      .map(\.id)
    guard !removedAgentIDs.isEmpty else { return }
    for agentID in removedAgentIDs {
      session.subagents.removeValue(forKey: agentID)
      let key = SubagentOrderingKey(sessionID: sessionID, agentID: agentID)
      if latestSubagentEventSequence[key, default: 0] <= throughDeliverySequence {
        latestSubagentEventSequence.removeValue(forKey: key)
      }
    }
    sessions[sessionID] = session
  }

  private func recordIgnored(_ event: BridgeEvent, projectName: String) {
    eventLogger.record(event: event.event, project: projectName, outcome: "ignored")
  }

  private func updateLocalObservationOwnership(for event: BridgeEvent) {
    guard event.agentId == nil else { return }
    guard event.origin == .localObservation else { return }
    switch event.event {
    case .working:
      locallyObservedTurns[event.sessionId] = event.turnId ?? ""
    case .completed, .failed:
      locallyObservedTurns.removeValue(forKey: event.sessionId)
    case .sessionStart, .approvalRequested, .subagentStarted, .subagentStopped, .ping:
      break
    }
  }

  private func resetOrderingForNewTurn(sessionID: String) {
    latestParentEventOrder.removeValue(forKey: sessionID)
    latestSubagentBoundarySequence.removeValue(forKey: sessionID)
    latestSubagentEventSequence = latestSubagentEventSequence.filter {
      $0.key.sessionID != sessionID
    }
    if var session = sessions[sessionID] {
      session.subagents.removeAll()
      sessions[sessionID] = session
    }
  }

  private func matchesTerminalState(_ event: BridgeEvent, completed: Bool) -> Bool {
    guard let session = sessions[event.sessionId], session.turnID == event.turnId else {
      return false
    }
    if completed, case .completed = session.status { return true }
    if !completed, case .failed = session.status { return true }
    return false
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
      self.latestParentEventOrder.removeValue(forKey: sessionID)
      self.latestSubagentBoundarySequence.removeValue(forKey: sessionID)
      self.latestSubagentEventSequence = self.latestSubagentEventSequence.filter {
        $0.key.sessionID != sessionID
      }
      self.unreadCompletionSessionIDs.remove(sessionID)
      self.notifyPresentationChanged()
    }
  }

  private func displayOperation(from input: JSONValue?) -> String {
    guard let input else { return "" }
    if let command = input.objectValue?["command"]?.stringValue { return command }
    return input.prettyPrinted()
  }

  private func sessionSort(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
    if lhs.presentationStatus.priority != rhs.presentationStatus.priority {
      return lhs.presentationStatus.priority > rhs.presentationStatus.priority
    }
    return lhs.updatedAt > rhs.updatedAt
  }

  private func notifyPresentationChanged() {
    refreshCapsLockAttention()
    presentationDidChange?()
  }

  func refreshCapsLockAttention(force: Bool = false) {
    unreadCompletionSessionIDs = unreadCompletionSessionIDs.filter { sessionID in
      guard let session = sessions[sessionID] else { return false }
      if case .completed = session.status { return true }
      return false
    }
    let desiredPattern: CapsLockPattern? =
      if settings.capsLockEnabled, currentApproval != nil {
        .approval
      } else {
        nil
      }
    guard force || desiredPattern != capsLockAttentionPattern else { return }
    capsLockAttentionPattern = desiredPattern
    Task { [weak self] in
      guard let self, self.capsLockAttentionPattern == desiredPattern else { return }
      await self.capsLockService.setPersistentAttention(desiredPattern)
    }
  }

  private func markVisibleCompletionsRead() {
    guard currentApproval == nil else { return }
    unreadCompletionSessionIDs.subtract(
      sessions.values.lazy.filter { session in
        if case .completed = session.status { return true }
        return false
      }.map(\.id)
    )
  }
}
