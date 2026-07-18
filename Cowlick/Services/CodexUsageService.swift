import Foundation

protocol CodexUsageFetching: Sendable {
  func fetchUsage() async throws -> CodexUsageSnapshot
}

enum CodexUsageServiceError: LocalizedError, Equatable {
  case processFailed
  case malformedResponse
  case responseTooLarge
  case unavailable(String?)

  var errorDescription: String? {
    switch self {
    case .processFailed: "Codex stopped before returning usage."
    case .malformedResponse: "Codex returned an unreadable usage response."
    case .responseTooLarge: "Codex returned more usage data than Cowlick accepts."
    case .unavailable(let message): message ?? "Codex usage is unavailable."
    }
  }
}

struct CodexUsageService: CodexUsageFetching, Sendable {
  static let maximumResponseSize = 1_048_576
  static let processTimeout: TimeInterval = 8

  private let locator: CodexExecutableLocator

  init(locator: CodexExecutableLocator = CodexExecutableLocator()) {
    self.locator = locator
  }

  func fetchUsage() async throws -> CodexUsageSnapshot {
    let executable = try locator.locate()
    return try await Task.detached(priority: .utility) {
      try Self.runProbe(executable: executable)
    }.value
  }

  static func parseResponse(_ data: Data, fetchedAt: Date = Date()) throws
    -> CodexUsageSnapshot
  {
    let decoder = JSONDecoder()
    var response: RateLimitsRPCResponse?
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      guard let candidate = try? decoder.decode(RateLimitsRPCResponse.self, from: Data(line)),
        candidate.id == 2
      else { continue }
      response = candidate
      break
    }

    guard let response else { throw CodexUsageServiceError.malformedResponse }
    if let error = response.error {
      throw CodexUsageServiceError.unavailable(error.message)
    }
    guard let result = response.result else { throw CodexUsageServiceError.malformedResponse }

    let keyedBuckets = result.rateLimitsByLimitId ?? [:]
    let buckets: [(key: String, value: RawRateLimitBucket)]
    if keyedBuckets.isEmpty {
      guard let bucket = result.rateLimits else {
        throw CodexUsageServiceError.unavailable(nil)
      }
      buckets = [(bucket.limitId ?? "codex", bucket)]
    } else {
      buckets = keyedBuckets.keys.sorted().compactMap { key in
        keyedBuckets[key].map { (key, $0) }
      }
    }

    let showBucketName = buckets.count > 1
    let limits = buckets.flatMap { entry -> [CodexUsageLimit] in
      let bucketID = entry.value.limitId ?? entry.key
      let bucketName = entry.value.limitName?.nilIfBlank ?? humanize(bucketID)
      return [
        entry.value.primary.map {
          makeLimit(
            bucketID: bucketID, bucketName: bucketName, role: "primary", window: $0,
            showBucketName: showBucketName)
        },
        entry.value.secondary.map {
          makeLimit(
            bucketID: bucketID, bucketName: bucketName, role: "secondary", window: $0,
            showBucketName: showBucketName)
        },
      ].compactMap { $0 }
    }
    guard !limits.isEmpty else { throw CodexUsageServiceError.unavailable(nil) }

    return CodexUsageSnapshot(
      limits: limits,
      planType: buckets.compactMap(\.value.planType).first,
      fetchedAt: fetchedAt
    )
  }

  private static func runProbe(executable: URL) throws -> CodexUsageSnapshot {
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
    guard read(until: 0, from: output.fileHandleForReading, into: &response) else {
      throw CodexUsageServiceError.processFailed
    }
    try write(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
    try write(
      ["method": "account/rateLimits/read", "id": 2, "params": [:]],
      to: input.fileHandleForWriting)
    guard read(until: 2, from: output.fileHandleForReading, into: &response) else {
      throw CodexUsageServiceError.processFailed
    }
    try? input.fileHandleForWriting.close()
    return try parseResponse(response)
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
  ) -> Bool {
    while !containsResponse(id: expectedID, in: response) {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return false }
      guard response.count + chunk.count <= maximumResponseSize else { return false }
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

  private static func makeLimit(
    bucketID: String,
    bucketName: String,
    role: String,
    window: RawRateLimitWindow,
    showBucketName: Bool
  ) -> CodexUsageLimit {
    let windowName = displayName(minutes: window.windowDurationMins, role: role)
    let name = showBucketName ? "\(windowName) · \(bucketName)" : windowName
    return CodexUsageLimit(
      id: "\(bucketID).\(role)",
      name: name,
      usedPercent: min(max(window.usedPercent, 0), 100),
      resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)),
      windowDurationMinutes: window.windowDurationMins
    )
  }

  private static func displayName(minutes: Int?, role: String) -> String {
    switch minutes {
    case 300: "5-hour window"
    case 10_080: "Weekly window"
    case let value? where value.isMultiple(of: 1_440): "\(value / 1_440)-day window"
    case let value? where value.isMultiple(of: 60): "\(value / 60)-hour window"
    case let value?: "\(value)-minute window"
    case nil: role == "primary" ? "Primary window" : "Secondary window"
    }
  }

  private static func humanize(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

private struct RateLimitsRPCResponse: Decodable {
  let id: Int?
  let result: RawRateLimitsResult?
  let error: RawRPCError?
}

private struct RawRPCError: Decodable {
  let message: String
}

private struct RawRateLimitsResult: Decodable {
  let rateLimits: RawRateLimitBucket?
  let rateLimitsByLimitId: [String: RawRateLimitBucket]?
}

private struct RawRateLimitBucket: Decodable {
  let limitId: String?
  let limitName: String?
  let planType: String?
  let primary: RawRateLimitWindow?
  let secondary: RawRateLimitWindow?
}

private struct RawRateLimitWindow: Decodable {
  let usedPercent: Double
  let windowDurationMins: Int?
  let resetsAt: TimeInterval?
}

extension String {
  fileprivate var nilIfBlank: String? { isEmpty ? nil : self }
}
