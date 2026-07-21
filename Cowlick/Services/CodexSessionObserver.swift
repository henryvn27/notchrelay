import CoreServices
import Darwin
import Foundation

struct ObservedCodexLifecycleEvent: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case working
    case completed
    case failed
    case stale
  }

  let kind: Kind
  let sessionID: String
  let turnID: String?
  let cwd: String
  let model: String?
  let timestamp: Date
  let parentSessionID: String?
  let agentType: String?

  var bridgeEvent: BridgeEvent? {
    let isSubagent = parentSessionID != nil
    let eventName: BridgeEventName
    switch (kind, isSubagent) {
    case (.working, false): eventName = .working
    case (.completed, false): eventName = .completed
    case (.failed, false): eventName = .failed
    case (.working, true): eventName = .subagentStarted
    case (.completed, true), (.failed, true), (.stale, true): eventName = .subagentStopped
    case (.stale, false): return nil
    }
    return BridgeEvent(
      event: eventName,
      timestamp: timestamp,
      sessionId: parentSessionID ?? sessionID,
      turnId: turnID,
      cwd: cwd,
      model: model,
      agentId: isSubagent ? sessionID : nil,
      agentType: isSubagent ? agentType ?? "Codex agent" : nil,
      errorMessage: kind == .failed ? "Codex turn interrupted" : nil,
      authToken: "",
      origin: .localObservation
    )
  }
}

struct CodexTranscriptAccumulator: Sendable {
  private(set) var sessionID: String?
  private(set) var cwd: String?
  private(set) var model: String?
  private(set) var turnID: String?
  private(set) var parentSessionID: String?
  private(set) var agentType: String?
  private var hasConsumedLine = false

  mutating func consume(line: Data) -> ObservedCodexLifecycleEvent? {
    let isFirstLine = !hasConsumedLine
    hasConsumedLine = true
    guard !line.isEmpty, line.count <= CodexSessionObserver.maximumLineSize,
      let record = try? JSONDecoder().decode(TranscriptRecord.self, from: line)
    else { return nil }

    switch record.type {
    case "session_meta":
      guard isFirstLine else { return nil }
      sessionID = record.payload.id ?? record.payload.sessionID ?? sessionID
      cwd = record.payload.cwd ?? cwd
      if let spawn = record.payload.source?.subagent?.threadSpawn {
        parentSessionID = spawn.parentThreadID
        agentType = spawn.agentRole ?? spawn.agentPath?.split(separator: "/").last.map(String.init)
      }
      return nil
    case "turn_context":
      cwd = record.payload.cwd ?? cwd
      model = record.payload.model ?? model
      turnID = record.payload.turnID ?? turnID
      return nil
    case "event_msg":
      break
    default:
      return nil
    }

    guard let eventType = record.payload.type,
      let sessionID,
      let cwd
    else { return nil }
    let kind: ObservedCodexLifecycleEvent.Kind
    switch eventType {
    case "task_started": kind = .working
    case "task_complete": kind = .completed
    case "turn_aborted": kind = .failed
    default: return nil
    }
    turnID = record.payload.turnID ?? turnID
    return ObservedCodexLifecycleEvent(
      kind: kind,
      sessionID: sessionID,
      turnID: turnID,
      cwd: cwd,
      model: model,
      timestamp: Self.date(from: record.timestamp) ?? Date(),
      parentSessionID: parentSessionID,
      agentType: agentType
    )
  }

  private static func date(from value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}

final class CodexSessionObserver: @unchecked Sendable {
  enum Status: Equatable, Sendable {
    case stopped
    case monitoring
    case unavailable

    var summary: String {
      switch self {
      case .stopped: "stopped"
      case .monitoring: "monitoring local Codex lifecycle events"
      case .unavailable: "unavailable; Codex session directory was not found"
      }
    }
  }

  static let maximumLineSize = 1_048_576
  static let initialTailSize = 32 * 1_048_576
  static let staleWorkingInterval: TimeInterval = 10 * 60
  static let initialTerminalVisibility: TimeInterval = 15
  static let maximumTrackedFiles = 128
  static let maximumTotalFragmentBytes = 4 * maximumLineSize
  static let stateRetentionInterval: TimeInterval = 15 * 60

  private struct FileState {
    var accumulator: CodexTranscriptAccumulator
    var offset: UInt64
    var fragment = Data()
    var activeEvent: ObservedCodexLifecycleEvent?
    var lastTouchedAt: Date
  }

  private let sessionsRoot: URL
  private let codexHome: URL
  private let handler: @Sendable (ObservedCodexLifecycleEvent) -> Void
  private let now: @Sendable () -> Date
  private let queue = DispatchQueue(
    label: "com.henryvn27.Cowlick.CodexSessionObserver", qos: .utility)
  private var stream: FSEventStreamRef?
  private var states: [String: FileState] = [:]
  private var staleWorkItems: [String: DispatchWorkItem] = [:]
  private var status: Status = .stopped

  init(
    codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true),
    now: @escaping @Sendable () -> Date = Date.init,
    handler: @escaping @Sendable (ObservedCodexLifecycleEvent) -> Void
  ) {
    self.codexHome = codexHome.standardizedFileURL
    sessionsRoot =
      codexHome.appendingPathComponent("sessions", isDirectory: true)
      .standardizedFileURL
    self.now = now
    self.handler = handler
  }

  var statusSummary: String { queue.sync { status.summary } }

  func start() {
    queue.async { [weak self] in self?.startOnQueue() }
  }

  func stop() {
    queue.sync { stopOnQueue() }
  }

  private func startOnQueue() {
    guard stream == nil else { return }
    guard let watchRoot = existingPrivateWatchRoot() else {
      status = .unavailable
      return
    }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer)
    guard
      let created = FSEventStreamCreate(
        kCFAllocatorDefault,
        { _, info, count, eventPaths, eventFlags, _ in
          guard let info else { return }
          let observer = Unmanaged<CodexSessionObserver>.fromOpaque(info).takeUnretainedValue()
          let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
          let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
          observer.handle(paths: Array(paths.prefix(count)), flags: flags)
        },
        &context,
        [watchRoot.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.15,
        flags
      )
    else {
      status = .unavailable
      return
    }
    stream = created
    FSEventStreamSetDispatchQueue(created, queue)
    guard FSEventStreamStart(created) else {
      FSEventStreamInvalidate(created)
      FSEventStreamRelease(created)
      stream = nil
      status = .unavailable
      return
    }
    status = directoryExists(codexHome) ? .monitoring : .unavailable
    scanRecentFiles(at: sessionsRoot)
  }

  private func stopOnQueue() {
    for item in staleWorkItems.values { item.cancel() }
    staleWorkItems.removeAll()
    states.removeAll()
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    status = .stopped
  }

  private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
    let recoveryFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
    if flags.contains(where: { $0 & recoveryFlags != 0 }) {
      scanRecentFiles(at: sessionsRoot)
    }
    for path in Set(paths) {
      let url = URL(fileURLWithPath: path)
      guard isCodexPath(url) else { continue }
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        status = .monitoring
        if isDirectory.boolValue {
          scanRecentFiles(at: isContainedInSessionsRoot(url) ? url : sessionsRoot)
        } else if url.pathExtension == "jsonl" {
          processFile(url)
        }
      } else if url.pathExtension == "jsonl" {
        removeState(at: url.path, emitStale: true)
      }
    }
    pruneStates(now: now())
  }

  private func scanRecentFiles(at root: URL) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return }
    let cutoff = now().addingTimeInterval(-Self.staleWorkingInterval)
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true,
        values.contentModificationDate ?? .distantPast >= cutoff
      else { continue }
      processFile(url)
    }
    pruneStates(now: now())
  }

  private func processFile(_ url: URL) {
    guard let validated = validatedSessionFile(url) else { return }
    let url = validated.url
    let path = url.path
    let attributes = validated.attributes
    guard
      let size = (attributes[.size] as? NSNumber)?.uint64Value
    else {
      removeState(at: path, emitStale: true)
      return
    }

    guard var state = states[path], size >= state.offset else {
      processInitialFile(url, size: size, attributes: attributes)
      return
    }
    guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: state.offset)
      while state.offset < size {
        let readCount = Int(min(UInt64(Self.maximumLineSize), size - state.offset))
        guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else { break }
        state.offset += UInt64(chunk.count)
        consume(chunk: chunk, state: &state)
      }
      state.lastTouchedAt = now()
      if let activeEvent = state.activeEvent { scheduleStale(activeEvent) }
      store(state, at: path)
    } catch {
      removeState(at: path, emitStale: true)
    }
  }

  private func processInitialFile(
    _ url: URL,
    size: UInt64,
    attributes: [FileAttributeKey: Any]
  ) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    var accumulator = CodexTranscriptAccumulator()
    if let firstLine = try? readFirstLine(from: handle) { _ = accumulator.consume(line: firstLine) }
    let start = size > UInt64(Self.initialTailSize) ? size - UInt64(Self.initialTailSize) : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let tail = try? handle.readToEnd()
    else { return }
    let usableTail: Data
    if start > 0 {
      if let newline = tail.firstIndex(of: 0x0A) {
        usableTail = Data(tail[tail.index(after: newline)...])
      } else {
        usableTail = Data()
      }
    } else {
      usableTail = tail
    }
    var lines = usableTail.split(separator: 0x0A, omittingEmptySubsequences: false)
    var fragment = Data()
    if usableTail.last != 0x0A, let trailing = lines.popLast() {
      if trailing.count <= Self.maximumLineSize { fragment = Data(trailing) }
    }
    var latestEvent: ObservedCodexLifecycleEvent?
    for line in lines where !line.isEmpty {
      if let event = accumulator.consume(line: Data(line)) { latestEvent = event }
    }

    var state = FileState(
      accumulator: accumulator,
      offset: size,
      fragment: fragment,
      lastTouchedAt: now()
    )
    if let latestEvent {
      let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
      switch latestEvent.kind {
      case .working
      where modificationDate >= now().addingTimeInterval(-Self.staleWorkingInterval):
        handler(latestEvent)
        state.activeEvent = latestEvent
        scheduleStale(latestEvent)
      case .completed,
        .failed
      where latestEvent.timestamp >= now().addingTimeInterval(-Self.initialTerminalVisibility):
        handler(latestEvent)
      default:
        break
      }
    }
    store(state, at: url.path)
  }

  private func validatedSessionFile(_ candidate: URL) -> (
    url: URL, attributes: [FileAttributeKey: Any]
  )? {
    let standardized = candidate.standardizedFileURL
    let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard isContainedInSessionsRoot(resolved) else { return nil }
    var information = stat()
    guard lstat(standardized.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_uid == getuid(),
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
    else { return nil }
    return (resolved, attributes)
  }

  private func isContainedInSessionsRoot(_ candidate: URL) -> Bool {
    let rootPath = sessionsRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func isCodexPath(_ candidate: URL) -> Bool {
    let rootPath = codexHome.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func existingPrivateWatchRoot() -> URL? {
    var candidate = directoryExists(codexHome) ? codexHome : codexHome.deletingLastPathComponent()
    while !directoryExists(candidate), candidate.path != "/" {
      candidate.deleteLastPathComponent()
    }
    var information = stat()
    guard lstat(candidate.path, &information) == 0,
      information.st_mode & S_IFMT == S_IFDIR,
      information.st_uid == getuid(),
      information.st_mode & 0o022 == 0
    else { return nil }
    return candidate
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func readFirstLine(from handle: FileHandle) throws -> Data? {
    try handle.seek(toOffset: 0)
    let data = try handle.read(upToCount: Self.maximumLineSize) ?? Data()
    guard let newline = data.firstIndex(of: 0x0A) else { return nil }
    return Data(data[..<newline])
  }

  private func consume(chunk: Data, state: inout FileState) {
    state.fragment.append(chunk)
    while let newline = state.fragment.firstIndex(of: 0x0A) {
      let line = Data(state.fragment[..<newline])
      state.fragment.removeSubrange(...newline)
      guard let event = state.accumulator.consume(line: line) else { continue }
      apply(event, state: &state)
    }
    if state.fragment.count > Self.maximumLineSize {
      state.fragment.removeAll(keepingCapacity: false)
    }
  }

  private func apply(_ event: ObservedCodexLifecycleEvent, state: inout FileState) {
    handler(event)
    switch event.kind {
    case .working:
      state.activeEvent = event
      scheduleStale(event)
    case .completed, .failed, .stale:
      state.activeEvent = nil
      cancelStale(for: event.sessionID)
    }
  }

  private func store(_ state: FileState, at path: String) {
    states[path] = state
    pruneStates(now: now(), preserving: path)
  }

  private func pruneStates(now: Date, preserving preservedPath: String? = nil) {
    let expired = states.compactMap { path, state in
      now.timeIntervalSince(state.lastTouchedAt) > Self.stateRetentionInterval ? path : nil
    }
    for path in expired { removeState(at: path, emitStale: true) }

    let deleted = states.keys.filter { !FileManager.default.fileExists(atPath: $0) }
    for path in deleted { removeState(at: path, emitStale: true) }

    while states.count > Self.maximumTrackedFiles
      || states.values.reduce(0, { $0 + $1.fragment.count })
        > Self.maximumTotalFragmentBytes
    {
      guard
        let path =
          states
          .filter({ $0.key != preservedPath })
          .min(by: {
            ($0.value.lastTouchedAt, $0.key) < ($1.value.lastTouchedAt, $1.key)
          })?.key
      else { break }
      removeState(at: path, emitStale: true)
    }
  }

  private func removeState(at path: String, emitStale: Bool) {
    guard let state = states.removeValue(forKey: path), let event = state.activeEvent else {
      return
    }
    cancelStale(for: event.sessionID)
    guard emitStale else { return }
    handler(
      ObservedCodexLifecycleEvent(
        kind: .stale,
        sessionID: event.sessionID,
        turnID: event.turnID,
        cwd: event.cwd,
        model: event.model,
        timestamp: now(),
        parentSessionID: event.parentSessionID,
        agentType: event.agentType
      ))
  }

  #if DEBUG
    var testingStateMetrics: (fileCount: Int, fragmentBytes: Int) {
      queue.sync {
        (states.count, states.values.reduce(0, { $0 + $1.fragment.count }))
      }
    }

    func pruneStateForTesting() {
      queue.sync { pruneStates(now: now()) }
    }

    var testingTrackedPaths: Set<String> {
      queue.sync { Set(states.keys) }
    }

    func processFileForTesting(_ url: URL) {
      queue.sync { processFile(url) }
    }
  #endif

  private func scheduleStale(_ event: ObservedCodexLifecycleEvent) {
    cancelStale(for: event.sessionID)
    let staleEvent = ObservedCodexLifecycleEvent(
      kind: .stale,
      sessionID: event.sessionID,
      turnID: event.turnID,
      cwd: event.cwd,
      model: event.model,
      timestamp: Date().addingTimeInterval(Self.staleWorkingInterval),
      parentSessionID: event.parentSessionID,
      agentType: event.agentType
    )
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.staleWorkItems.removeValue(forKey: event.sessionID)
      self.handler(staleEvent)
    }
    staleWorkItems[event.sessionID] = item
    queue.asyncAfter(deadline: .now() + Self.staleWorkingInterval, execute: item)
  }

  private func cancelStale(for sessionID: String) {
    staleWorkItems.removeValue(forKey: sessionID)?.cancel()
  }
}

private struct TranscriptRecord: Decodable {
  let type: String
  let timestamp: String?
  let payload: Payload

  struct Payload: Decodable {
    let type: String?
    let id: String?
    let sessionID: String?
    let cwd: String?
    let model: String?
    let turnID: String?
    let source: Source?

    enum CodingKeys: String, CodingKey {
      case type, id, cwd, model, source
      case sessionID = "session_id"
      case turnID = "turn_id"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decodeIfPresent(String.self, forKey: .type)
      id = try container.decodeIfPresent(String.self, forKey: .id)
      sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
      cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
      model = try container.decodeIfPresent(String.self, forKey: .model)
      turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
      source = try? container.decode(Source.self, forKey: .source)
    }
  }

  struct Source: Decodable {
    let subagent: Subagent?
  }

  struct Subagent: Decodable {
    let threadSpawn: ThreadSpawn?

    enum CodingKeys: String, CodingKey {
      case threadSpawn = "thread_spawn"
    }
  }

  struct ThreadSpawn: Decodable {
    let parentThreadID: String?
    let agentPath: String?
    let agentRole: String?

    enum CodingKeys: String, CodingKey {
      case parentThreadID = "parent_thread_id"
      case agentPath = "agent_path"
      case agentRole = "agent_role"
    }
  }
}
