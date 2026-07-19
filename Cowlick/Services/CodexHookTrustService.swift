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
  private let timeout: TimeInterval

  init(
    locator: CodexExecutableLocator = CodexExecutableLocator(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    timeout: TimeInterval = Self.processTimeout
  ) {
    self.locator = locator
    self.timeout = timeout
    let shim = homeDirectory.appendingPathComponent(".local/bin/cowlick-hook").path
    expectedCommand = "'\(shim.replacingOccurrences(of: "'", with: "'\\''"))' hook"
  }

  func inspect(workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path)
    async -> CodexHookTrustReport
  {
    do {
      let locator = locator
      let command = expectedCommand
      let timeout = timeout
      return try await runBoundedProcessOperation {
        let executable = try locator.locate()
        return try Self.runProbe(
          executable: executable,
          workingDirectory: workingDirectory,
          expectedCommand: command,
          timeout: timeout
        )
      }
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
    expectedCommand: String,
    timeout: TimeInterval
  ) throws -> CodexHookTrustReport {
    var environment = ProcessInfo.processInfo.environment
    let executableDirectory = executable.deletingLastPathComponent().path
    environment["PATH"] =
      environment["PATH"].map { "\(executableDirectory):\($0)" }
      ?? executableDirectory
    do {
      let runner = try BoundedProcessRunner(
        executableURL: executable,
        arguments: ["app-server", "--stdio"],
        environment: environment,
        acceptsInput: true,
        timeout: timeout,
        maximumOutputSize: maximumResponseSize
      )
      defer { runner.stop() }

      try runner.write(
        encoded(
          [
            "method": "initialize",
            "id": 0,
            "params": [
              "clientInfo": [
                "name": "cowlick", "title": "Cowlick", "version": ProductVersion.marketing,
              ]
            ],
          ]))
      try runner.read { containsResponse(id: 0, in: $0) }
      try runner.write(encoded(["method": "initialized", "params": [:]]))
      try runner.write(
        encoded(["method": "hooks/list", "id": 2, "params": ["cwds": [workingDirectory]]]))
      try runner.read { containsResponse(id: 2, in: $0) }
      return try parseResponse(
        runner.output, workingDirectory: workingDirectory, expectedCommand: expectedCommand)
    } catch let error as BoundedProcessRunnerError {
      if error == .responseTooLarge {
        throw CodexHookTrustServiceError.responseTooLarge
      }
      throw CodexHookTrustServiceError.processFailed
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CodexHookTrustServiceError {
      throw error
    } catch {
      throw CodexHookTrustServiceError.processFailed
    }
  }

  private static func encoded(_ message: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    data.append(0x0A)
    return data
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
