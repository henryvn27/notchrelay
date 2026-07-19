import Darwin
import Foundation

enum HookBridgeEventName: String, Codable, Sendable {
  case sessionStart
  case working
  case approvalRequested
  case completed
  case failed
  case ping
}

struct HookBridgeEvent: Codable, Sendable {
  static let currentVersion = ProductVersion.bridgeProtocol

  let version: Int
  let requestId: UUID
  let event: HookBridgeEventName
  let timestamp: Date
  let sessionId: String
  let turnId: String?
  let cwd: String
  let model: String?
  let prompt: String?
  let lastAssistantMessage: String?
  let errorMessage: String?
  let toolName: String?
  let toolInput: HookJSONValue?
  let humanDescription: String?
  let authToken: String

  init(
    requestId: UUID = UUID(),
    event: HookBridgeEventName,
    sessionId: String,
    turnId: String? = nil,
    cwd: String,
    model: String? = nil,
    prompt: String? = nil,
    lastAssistantMessage: String? = nil,
    errorMessage: String? = nil,
    toolName: String? = nil,
    toolInput: HookJSONValue? = nil,
    humanDescription: String? = nil,
    authToken: String = ""
  ) {
    version = Self.currentVersion
    self.requestId = requestId
    self.event = event
    timestamp = Date()
    self.sessionId = sessionId
    self.turnId = turnId
    self.cwd = cwd
    self.model = model
    self.prompt = prompt
    self.lastAssistantMessage = lastAssistantMessage
    self.errorMessage = errorMessage
    self.toolName = toolName
    self.toolInput = toolInput
    self.humanDescription = humanDescription
    self.authToken = authToken
  }

  func authenticated(with token: String) -> HookBridgeEvent {
    HookBridgeEvent(
      requestId: requestId,
      event: event,
      sessionId: sessionId,
      turnId: turnId,
      cwd: cwd,
      model: model,
      prompt: prompt,
      lastAssistantMessage: lastAssistantMessage,
      errorMessage: errorMessage,
      toolName: toolName,
      toolInput: toolInput,
      humanDescription: humanDescription,
      authToken: token
    )
  }
}

struct HookRuntimeMetadata: Codable, Sendable {
  let version: Int
  let socketPath: String
  let tokenPath: String
  let pid: Int32
  let uid: uid_t
  let appVersion: String
  let approvalTimeout: TimeInterval
}

enum HookBridgeError: LocalizedError {
  case appUnavailable
  case insecureMetadata
  case unsupportedVersion
  case oversizedMessage
  case socketFailure(Int32)
  case malformedResponse
  case mismatchedResponse
  case rejectedResponse

  var errorDescription: String? {
    switch self {
    case .appUnavailable: "Cowlick is not running."
    case .insecureMetadata: "Runtime metadata failed owner or permission validation."
    case .unsupportedVersion: "The app and hook use different bridge protocol versions."
    case .oversizedMessage: "The bridge message exceeds 1 MB."
    case .socketFailure(let code): "Local socket operation failed (errno \(code))."
    case .malformedResponse: "The app returned malformed bridge JSON."
    case .mismatchedResponse: "The app response did not match this approval request."
    case .rejectedResponse: "Cowlick rejected the bridge request."
    }
  }
}

struct HookBridgeClient {
  static let maximumMessageSize = 1_048_576
  private static let approvalResponseGracePeriod: TimeInterval = 0.5

  private let fileManager: FileManager
  private let homeDirectory: URL

  init(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
  }

  var runtimeMetadataURL: URL {
    homeDirectory.appendingPathComponent("Library/Application Support/Cowlick/runtime.json")
  }

  func send(_ unauthenticatedEvent: HookBridgeEvent, waitForResponse: Bool) throws
    -> ApprovalBridgeResponse?
  {
    let metadata = try loadMetadata()
    guard metadata.version == HookBridgeEvent.currentVersion else {
      throw HookBridgeError.unsupportedVersion
    }
    guard metadata.uid == getuid(), kill(metadata.pid, 0) == 0 else {
      throw HookBridgeError.appUnavailable
    }
    let token = try loadPrivateFile(at: URL(fileURLWithPath: metadata.tokenPath))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let event = unauthenticatedEvent.authenticated(with: token)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var payload = try encoder.encode(event)
    guard payload.count < Self.maximumMessageSize else { throw HookBridgeError.oversizedMessage }
    payload.append(0x0A)

    let responseTimeout: TimeInterval
    switch event.event {
    case .approvalRequested:
      responseTimeout = metadata.approvalTimeout + Self.approvalResponseGracePeriod
    default:
      responseTimeout = 1
    }
    let descriptor = try connect(
      path: metadata.socketPath,
      timeout: waitForResponse ? responseTimeout : 1)
    defer { Darwin.close(descriptor) }
    try write(payload, to: descriptor)
    guard waitForResponse else { return nil }

    let responseData = try readLine(from: descriptor)
    let decoder = JSONDecoder()
    switch event.event {
    case .approvalRequested:
      guard
        let response = try? decoder.decode(ApprovalBridgeResponse.self, from: responseData)
      else {
        throw HookBridgeError.malformedResponse
      }
      guard response.version == HookBridgeEvent.currentVersion,
        response.requestId == event.requestId
      else { throw HookBridgeError.mismatchedResponse }
      return response
    default:
      guard
        let acknowledgement = try? decoder.decode(
          HookBridgeAcknowledgement.self, from: responseData)
      else { throw HookBridgeError.malformedResponse }
      guard acknowledgement.version == HookBridgeEvent.currentVersion,
        acknowledgement.requestId == event.requestId
      else { throw HookBridgeError.mismatchedResponse }
      guard acknowledgement.accepted else { throw HookBridgeError.rejectedResponse }
      return nil
    }
  }

  func diagnostics() -> [String: Any] {
    do {
      let metadata = try loadMetadata()
      let event = HookBridgeEvent(
        event: .ping, sessionId: "diagnostics", cwd: fileManager.currentDirectoryPath)
      _ = try send(event, waitForResponse: true)
      return [
        "ok": true,
        "appVersion": metadata.appVersion,
        "protocolVersion": metadata.version,
        "socket": "reachable",
      ]
    } catch {
      return ["ok": false, "error": error.localizedDescription]
    }
  }

  private func loadMetadata() throws -> HookRuntimeMetadata {
    let data = try Data(loadPrivateFile(at: runtimeMetadataURL).utf8)
    guard let metadata = try? JSONDecoder().decode(HookRuntimeMetadata.self, from: data) else {
      throw HookBridgeError.appUnavailable
    }
    return metadata
  }

  private func loadPrivateFile(at url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      (info.st_mode & 0o077) == 0
    else { throw HookBridgeError.insecureMetadata }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func connect(path: String, timeout: TimeInterval) throws -> Int32 {
    guard path.utf8CString.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size
    else {
      throw HookBridgeError.appUnavailable
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HookBridgeError.socketFailure(errno) }

    var noSigPipe: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var time = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
        for index in pathBytes.indices { destination[index] = pathBytes[index] }
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, length)
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw HookBridgeError.socketFailure(code)
    }
    return descriptor
  }

  private func write(_ data: Data, to descriptor: Int32) throws {
    let success = data.withUnsafeBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
        if count <= 0 { return false }
        sent += count
      }
      return true
    }
    if !success { throw HookBridgeError.socketFailure(errno) }
  }

  private func readLine(from descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= Self.maximumMessageSize {
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if count <= 0 { throw HookBridgeError.socketFailure(errno) }
      if let newline = buffer[..<count].firstIndex(of: 0x0A) {
        guard data.count + newline <= Self.maximumMessageSize else {
          throw HookBridgeError.oversizedMessage
        }
        data.append(contentsOf: buffer[..<newline])
        return data
      }
      data.append(contentsOf: buffer[..<count])
    }
    throw HookBridgeError.oversizedMessage
  }
}
