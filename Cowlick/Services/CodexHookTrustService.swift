import Foundation

enum CodexHookTrustState: Equatable, Sendable {
  case notChecked
  case trusted
  case needsReview
  case incomplete
  case unavailable(String)

  var summary: String {
    switch self {
    case .notChecked: "Not checked"
    case .trusted: "Trusted"
    case .needsReview: "Review required in Codex /hooks"
    case .incomplete: "Cowlick hooks are missing or disabled"
    case .unavailable(let message): message
    }
  }
}

struct CodexHookTrustReport: Equatable, Sendable {
  let state: CodexHookTrustState
  let eventStatuses: [String: String]

  static let notChecked = CodexHookTrustReport(state: .notChecked, eventStatuses: [:])
}

enum CodexHookTrustServiceError: LocalizedError, Equatable {
  case processFailed
  case malformedResponse
  case responseTooLarge
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .processFailed: "Codex stopped before reporting hook trust."
    case .malformedResponse: "Codex returned an unreadable hook status."
    case .responseTooLarge: "Codex returned more hook data than Cowlick accepts."
    case .unavailable(let message): message
    }
  }
}

struct CodexHookTrustService: Sendable {
  static let maximumResponseSize = 1_048_576
  static let processTimeout: TimeInterval = 8

  private static let expectedEvents = [
    "sessionStart", "userPromptSubmit", "permissionRequest", "stop",
  ]

  private let locator: CodexExecutableLocator
  private let expectedCommand: String

  init(
    locator: CodexExecutableLocator = CodexExecutableLocator(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.locator = locator
    let shim = homeDirectory.appendingPathComponent(".local/bin/cowlick-hook").path
    expectedCommand = "'\(shim.replacingOccurrences(of: "'", with: "'\\''"))' hook"
  }

  func inspect(workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path)
    async -> CodexHookTrustReport
  {
    do {
      let executable = try locator.locate()
      let command = expectedCommand
      return try await Task.detached(priority: .utility) {
        try Self.runProbe(
          executable: executable,
          workingDirectory: workingDirectory,
          expectedCommand: command
        )
      }.value
    } catch {
      return CodexHookTrustReport(
        state: .unavailable(error.localizedDescription), eventStatuses: [:])
    }
  }

  static func parseResponse(
    _ data: Data,
    workingDirectory: String,
    expectedCommand: String
  ) throws -> CodexHookTrustReport {
    let decoder = JSONDecoder()
    var response: HooksListRPCResponse?
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      guard let candidate = try? decoder.decode(HooksListRPCResponse.self, from: Data(line)),
        candidate.id == 2
      else { continue }
      response = candidate
      break
    }

    guard let response else { throw CodexHookTrustServiceError.malformedResponse }
    if let error = response.error {
      throw CodexHookTrustServiceError.unavailable(error.message)
    }
    guard let entries = response.result?.data,
      let entry = entries.first(where: { $0.cwd == workingDirectory }) ?? entries.first
    else { throw CodexHookTrustServiceError.malformedResponse }

    let cowlickHooks = entry.hooks.filter { $0.command == expectedCommand }
    var statuses: [String: String] = [:]
    for event in expectedEvents {
      if let hook = cowlickHooks.first(where: { $0.eventName == event }) {
        statuses[event] = hook.enabled ? hook.trustStatus : "disabled"
      }
    }

    guard statuses.count == expectedEvents.count else {
      return CodexHookTrustReport(state: .incomplete, eventStatuses: statuses)
    }
    if statuses.values.contains(where: { $0 == "untrusted" || $0 == "modified" }) {
      return CodexHookTrustReport(state: .needsReview, eventStatuses: statuses)
    }
    if statuses.values.allSatisfy({ $0 == "trusted" || $0 == "managed" }) {
      return CodexHookTrustReport(state: .trusted, eventStatuses: statuses)
    }
    return CodexHookTrustReport(state: .incomplete, eventStatuses: statuses)
  }

  private static func runProbe(
    executable: URL,
    workingDirectory: String,
    expectedCommand: String
  ) throws -> CodexHookTrustReport {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    var environment = ProcessInfo.processInfo.environment
    let executableDirectory = executable.deletingLastPathComponent().path
    environment["PATH"] =
      environment["PATH"].map { "\(executableDirectory):\($0)" }
      ?? executableDirectory
    process.environment = environment
    try process.run()

    let timeout = DispatchWorkItem {
      if process.isRunning { process.terminate() }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + processTimeout, execute: timeout)
    defer {
      timeout.cancel()
      if process.isRunning { process.terminate() }
    }

    try write(
      [
        "method": "initialize",
        "id": 0,
        "params": [
          "clientInfo": [
            "name": "cowlick", "title": "Cowlick", "version": ProductVersion.marketing,
          ]
        ],
      ], to: input.fileHandleForWriting)

    var response = Data()
    guard try read(until: 0, from: output.fileHandleForReading, into: &response) else {
      throw CodexHookTrustServiceError.processFailed
    }
    try write(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
    try write(
      ["method": "hooks/list", "id": 2, "params": ["cwds": [workingDirectory]]],
      to: input.fileHandleForWriting)
    guard try read(until: 2, from: output.fileHandleForReading, into: &response) else {
      throw CodexHookTrustServiceError.processFailed
    }
    try? input.fileHandleForWriting.close()
    return try parseResponse(
      response, workingDirectory: workingDirectory, expectedCommand: expectedCommand)
  }

  private static func write(_ message: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  private static func read(
    until expectedID: Int,
    from handle: FileHandle,
    into response: inout Data
  ) throws -> Bool {
    while !containsResponse(id: expectedID, in: response) {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return false }
      guard response.count + chunk.count <= maximumResponseSize else {
        throw CodexHookTrustServiceError.responseTooLarge
      }
      response.append(chunk)
    }
    return true
  }

  private static func containsResponse(id: Int, in data: Data) -> Bool {
    data.split(separator: 0x0A).contains { line in
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
        let dictionary = object as? [String: Any]
      else { return false }
      return dictionary["id"] as? Int == id
    }
  }
}

private struct HooksListRPCResponse: Decodable {
  let id: Int?
  let result: HooksListResult?
  let error: HooksListRPCError?
}

private struct HooksListRPCError: Decodable {
  let message: String
}

private struct HooksListResult: Decodable {
  let data: [HooksListEntry]
}

private struct HooksListEntry: Decodable {
  let cwd: String
  let hooks: [HookMetadata]
}

private struct HookMetadata: Decodable {
  let eventName: String
  let command: String?
  let enabled: Bool
  let trustStatus: String
}
