import Darwin
import Foundation

@testable import Cowlick

@MainActor
func makeTestSettings(_ name: String = UUID().uuidString) -> SettingsStore {
  let suite = "com.henryvn27.CowlickTests.\(name)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return SettingsStore(defaults: defaults)
}

func makeBridgeEvent(
  event: BridgeEventName,
  requestID: UUID = UUID(),
  sessionID: String = "session-1",
  turnID: String? = "turn-1",
  cwd: String = "/tmp/Scoutly",
  timestamp: Date = Date(),
  prompt: String? = nil,
  result: String? = nil,
  error: String? = nil,
  toolName: String? = nil,
  toolInput: JSONValue? = nil,
  description: String? = nil
) -> BridgeEvent {
  BridgeEvent(
    requestId: requestID,
    event: event,
    timestamp: timestamp,
    sessionId: sessionID,
    turnId: turnID,
    cwd: cwd,
    prompt: prompt,
    lastAssistantMessage: result,
    errorMessage: error,
    toolName: toolName,
    toolInput: toolInput,
    humanDescription: description,
    authToken: "test-token"
  )
}

actor RecordingCapsLockService: CapsLockSignalService {
  private(set) var patterns: [CapsLockPattern] = []
  private(set) var cancellationCount = 0

  func supportStatus() -> CapsLockSupport { .available }
  func testSignal() -> CapsLockSupport { .available }
  func start(_ pattern: CapsLockPattern) { patterns.append(pattern) }
  func cancelAndRestore() { cancellationCount += 1 }

  func snapshot() -> ([CapsLockPattern], Int) { (patterns, cancellationCount) }
}

@MainActor
func waitUntil(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

struct ExecutableFixture {
  let url: URL

  init(script: String) throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-executable-fixture-\(UUID().uuidString)")
    try Data(script.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}

func stubbornProcessTreeScript(parentPID: URL, descendantPID: URL) -> String {
  """
  #!/bin/sh
  trap '' TERM
  (trap '' TERM; while :; do :; done) &
  printf '%s' "$$" > '\(parentPID.path)'
  printf '%s' "$!" > '\(descendantPID.path)'
  while :; do :; done
  """
}

func waitForProcessID(at url: URL, timeout: TimeInterval = 1) async -> pid_t? {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let data = try? Data(contentsOf: url),
      let value = String(data: data, encoding: .utf8),
      let processID = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return processID
    }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return nil
}

func processIsAlive(_ processID: pid_t) -> Bool {
  errno = 0
  return Darwin.kill(processID, 0) == 0 || errno == EPERM
}

func waitForProcessesToExit(_ processIDs: [pid_t], timeout: TimeInterval = 1) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if processIDs.allSatisfy({ !processIsAlive($0) }) { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return processIDs.allSatisfy { !processIsAlive($0) }
}
