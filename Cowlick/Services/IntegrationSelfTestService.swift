import Foundation

enum IntegrationDemoEvent: String, Sendable {
  case working
  case completed
}

enum IntegrationSelfTestError: LocalizedError, Equatable {
  case helperUnavailable
  case launchFailed
  case timedOut
  case processFailed(Int32)
  case outputReadFailed
  case responseTooLarge
  case malformedResponse

  var errorDescription: String? {
    switch self {
    case .helperUnavailable:
      "The installed Cowlick helper is unavailable. Repair Codex integration first."
    case .launchFailed:
      "Cowlick could not launch its installed helper."
    case .timedOut:
      "The helper could not reach Cowlick before the self-test timed out."
    case .processFailed:
      "The helper could not reach Cowlick. Repair the integration and try again."
    case .outputReadFailed:
      "Cowlick could not read the helper's self-test response."
    case .responseTooLarge:
      "The helper returned more self-test data than Cowlick accepts."
    case .malformedResponse:
      "The helper returned an unreadable self-test response."
    }
  }
}

struct IntegrationSelfTestService: Sendable {
  static let maximumResponseSize = 1_048_576

  let helperURL: URL
  let timeout: TimeInterval

  init(helperURL: URL, timeout: TimeInterval = 5) {
    self.helperURL = helperURL
    self.timeout = timeout
  }

  func ping() async throws {
    let helperURL = helperURL
    let timeout = timeout
    try await runBoundedProcessOperation {
      let response = try Self.run(helperURL: helperURL, arguments: ["ping"], timeout: timeout)
      let object = try Self.decodeObject(response)
      guard object["ok"] as? Bool == true else {
        throw IntegrationSelfTestError.malformedResponse
      }
    }
  }

  func sendDemo(_ event: IntegrationDemoEvent, sessionID: String) async throws {
    let helperURL = helperURL
    let timeout = timeout
    try await runBoundedProcessOperation {
      let response = try Self.run(
        helperURL: helperURL,
        arguments: ["demo", event.rawValue],
        timeout: timeout,
        environment: ["COWLICK_DEMO_SESSION_ID": sessionID]
      )
      let object = try Self.decodeObject(response)
      guard object["sent"] as? Bool == true else {
        throw IntegrationSelfTestError.malformedResponse
      }
    }
  }

  static func decodeObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= maximumResponseSize,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw data.count > maximumResponseSize
        ? IntegrationSelfTestError.responseTooLarge
        : IntegrationSelfTestError.malformedResponse
    }
    return object
  }

  private static func run(
    helperURL: URL,
    arguments: [String],
    timeout: TimeInterval,
    environment: [String: String] = [:]
  ) throws -> Data {
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw IntegrationSelfTestError.helperUnavailable
    }

    do {
      let runner = try BoundedProcessRunner(
        executableURL: helperURL,
        arguments: arguments,
        environment: environment.isEmpty
          ? nil
          : ProcessInfo.processInfo.environment.merging(environment) { _, new in new },
        timeout: timeout,
        maximumOutputSize: maximumResponseSize
      )
      defer { runner.stop() }
      try runner.readToExit()
      return runner.output
    } catch let error as BoundedProcessRunnerError {
      switch error {
      case .outputReadFailed, .processStatusFailed:
        throw IntegrationSelfTestError.outputReadFailed
      case .responseTooLarge:
        throw IntegrationSelfTestError.responseTooLarge
      case .timedOut:
        throw IntegrationSelfTestError.timedOut
      case .processFailed(let status):
        throw IntegrationSelfTestError.processFailed(status)
      case .incompleteOutput:
        throw IntegrationSelfTestError.outputReadFailed
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw IntegrationSelfTestError.launchFailed
    }
  }
}
