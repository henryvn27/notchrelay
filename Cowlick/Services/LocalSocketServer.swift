import Darwin
import Foundation
import OSLog
import Security

struct RuntimeMetadata: Codable, Equatable, Sendable {
  let version: Int
  let socketPath: String
  let tokenPath: String
  let pid: Int32
  let uid: uid_t
  let appVersion: String
  let sourceCommit: String
  let approvalTimeout: TimeInterval
}

enum SocketServerError: LocalizedError {
  case pathTooLong
  case socketCreation(Int32)
  case bind(Int32)
  case listen(Int32)
  case insecureTokenFile
  case insecureRuntimeMetadataFile
  case permissions(Int32)
  case alreadyRunning
  case unsafeExistingSocketPath

  var errorDescription: String? {
    switch self {
    case .pathTooLong: "The private socket path exceeds the Unix-domain socket limit."
    case .socketCreation(let code): "Could not create the local socket (errno \(code))."
    case .bind(let code): "Could not bind the local socket (errno \(code))."
    case .listen(let code): "Could not listen on the local socket (errno \(code))."
    case .insecureTokenFile: "The authentication token file is not a regular owner-only file."
    case .insecureRuntimeMetadataFile:
      "The runtime metadata file is not a regular owner-only file."
    case .permissions(let code):
      "Could not secure a private bridge file (errno \(code))."
    case .alreadyRunning: "Another Cowlick instance is already serving bridge requests."
    case .unsafeExistingSocketPath:
      "The bridge socket path is occupied by an unexpected file or cannot be verified."
    }
  }
}

struct LocalSocketServerPaths: Sendable {
  let tokenURL: URL
  let runtimeMetadataURL: URL
  let socketURL: URL

  static let applicationSupport = LocalSocketServerPaths(
    tokenURL: AppSupportPaths.tokenURL,
    runtimeMetadataURL: AppSupportPaths.runtimeMetadataURL,
    socketURL: AppSupportPaths.socketURL
  )
}

final class LocalSocketServer: @unchecked Sendable {
  static let maximumMessageSize = 1_048_576

  private let logger = Logger(subsystem: "com.henryvn27.Cowlick", category: "Socket")
  private let acceptQueue = DispatchQueue(
    label: "com.henryvn27.Cowlick.socket.accept", qos: .userInitiated)
  private let clientQueue = DispatchQueue(
    label: "com.henryvn27.Cowlick.socket.clients", qos: .userInitiated,
    attributes: .concurrent)
  private let eventHandler: @Sendable (BridgeEvent) async -> ApprovalDecision?
  private let approvalTimeout: () -> TimeInterval
  private let paths: LocalSocketServerPaths
  private let prepareDirectories: () throws -> Void
  private let stateLock = NSLock()

  private var listeningFileDescriptor: Int32 = -1
  private var running = false
  private var nextDeliverySequence: UInt64 = 0
  private(set) var authenticationToken = ""

  init(
    approvalTimeout: @escaping () -> TimeInterval,
    paths: LocalSocketServerPaths = .applicationSupport,
    prepareDirectories: @escaping () throws -> Void = AppSupportPaths.prepareDirectories,
    eventHandler: @escaping @Sendable (BridgeEvent) async -> ApprovalDecision?
  ) {
    self.approvalTimeout = approvalTimeout
    self.paths = paths
    self.prepareDirectories = prepareDirectories
    self.eventHandler = eventHandler
  }

  func start() throws {
    try prepareDirectories()
    authenticationToken = try loadOrCreateToken()

    let socketPath = paths.socketURL.path
    guard
      socketPath.utf8CString.count <= MemoryLayout<sockaddr_un>.size
        - MemoryLayout<sa_family_t>.size
    else {
      throw SocketServerError.pathTooLong
    }

    try Self.recoverStaleSocket(at: socketPath)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketServerError.socketCreation(errno) }
    var startupCommitted = false
    var socketBound = false
    var metadataPublicationAttempted = false
    defer {
      if !startupCommitted {
        Darwin.close(descriptor)
        if socketBound { unlink(socketPath) }
        if metadataPublicationAttempted {
          Self.removeOwnedRegularFileIfPresent(at: paths.runtimeMetadataURL)
        }
      }
    }

    var noSigPipe: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
        for index in pathBytes.indices { destination[index] = pathBytes[index] }
      }
    }

    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0 else {
      let code = errno
      throw SocketServerError.bind(code)
    }
    socketBound = true

    guard chmod(socketPath, 0o600) == 0 else {
      let code = errno
      throw SocketServerError.permissions(code)
    }

    guard Darwin.listen(descriptor, 16) == 0 else {
      let code = errno
      throw SocketServerError.listen(code)
    }

    metadataPublicationAttempted = true
    try publishRuntimeMetadata()
    stateLock.withLock {
      listeningFileDescriptor = descriptor
      running = true
      nextDeliverySequence = 0
    }
    startupCommitted = true
    logger.info("Socket server started")
    acceptQueue.async { [weak self] in self?.acceptLoop() }
  }

  static func recoverStaleSocket(at path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { return }
      throw SocketServerError.unsafeExistingSocketPath
    }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
      throw SocketServerError.unsafeExistingSocketPath
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketServerError.socketCreation(errno) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard
      pathBytes.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size
    else { throw SocketServerError.pathTooLong }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
        for index in pathBytes.indices { destination[index] = pathBytes[index] }
      }
    }
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    if result == 0 { throw SocketServerError.alreadyRunning }
    guard errno == ECONNREFUSED || errno == ENOENT else {
      throw SocketServerError.unsafeExistingSocketPath
    }
    guard unlink(path) == 0 || errno == ENOENT else {
      throw SocketServerError.unsafeExistingSocketPath
    }
  }

  func stop() {
    let descriptor = stateLock.withLock { () -> Int32 in
      running = false
      let current = listeningFileDescriptor
      listeningFileDescriptor = -1
      return current
    }
    if descriptor >= 0 {
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
    }
    unlink(paths.socketURL.path)
    Self.removeOwnedRegularFileIfPresent(at: paths.runtimeMetadataURL)
    logger.info("Socket server stopped")
  }

  private func acceptLoop() {
    while stateLock.withLock({ running }) {
      let descriptor = stateLock.withLock { listeningFileDescriptor }
      guard descriptor >= 0 else { return }
      let client = Darwin.accept(descriptor, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        if stateLock.withLock({ running }) { logger.error("Accept failed: \(errno)") }
        return
      }
      let deliverySequence = stateLock.withLock { () -> UInt64 in
        nextDeliverySequence &+= 1
        return nextDeliverySequence
      }
      clientQueue.async { [weak self] in
        self?.handle(client: client, deliverySequence: deliverySequence)
      }
    }
  }

  private func handle(client: Int32, deliverySequence: UInt64) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
      writeAcknowledgement(
        client: client, requestID: UUID(), accepted: false, error: "Peer user mismatch")
      Darwin.close(client)
      return
    }

    guard let data = readLine(from: client) else {
      Darwin.close(client)
      return
    }

    var event: BridgeEvent
    do {
      event = try JSONDecoder.bridge.decode(BridgeEvent.self, from: data)
    } catch {
      writeAcknowledgement(
        client: client, requestID: UUID(), accepted: false, error: "Malformed bridge event")
      Darwin.close(client)
      logger.error("Rejected malformed bridge JSON")
      return
    }

    guard event.version == BridgeEvent.currentVersion else {
      writeAcknowledgement(
        client: client, requestID: event.requestId, accepted: false,
        error: "Unsupported protocol version")
      Darwin.close(client)
      return
    }
    guard constantTimeEquals(event.authToken, authenticationToken) else {
      writeAcknowledgement(
        client: client, requestID: event.requestId, accepted: false, error: "Authentication failed")
      Darwin.close(client)
      logger.error("Rejected bridge authentication")
      return
    }
    let age = Date().timeIntervalSince(event.timestamp)
    guard age >= -300, age <= 15 * 60 else {
      writeAcknowledgement(
        client: client, requestID: event.requestId, accepted: false, error: "Stale bridge event")
      Darwin.close(client)
      return
    }
    event.deliverySequence = deliverySequence

    Task { [eventHandler] in
      let decision = await eventHandler(event)
      if event.event == .approvalRequested {
        let response = ApprovalResponse(
          requestId: event.requestId, decision: decision ?? .deferDecision)
        self.write(response, to: client)
      } else {
        self.writeAcknowledgement(
          client: client, requestID: event.requestId, accepted: true, error: nil)
      }
      Darwin.close(client)
    }
  }

  private func readLine(from descriptor: Int32) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.count <= Self.maximumMessageSize {
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if let newline = buffer[..<count].firstIndex(of: 0x0A) {
        guard data.count + newline <= Self.maximumMessageSize else { return nil }
        data.append(contentsOf: buffer[..<newline])
        return data
      }
      data.append(contentsOf: buffer[..<count])
    }
    guard !data.isEmpty, data.count <= Self.maximumMessageSize else { return nil }
    return data
  }

  private func writeAcknowledgement(client: Int32, requestID: UUID, accepted: Bool, error: String?)
  {
    write(
      BridgeAcknowledgement(
        version: BridgeEvent.currentVersion, requestId: requestID, accepted: accepted, error: error),
      to: client)
  }

  private func write<Value: Encodable>(_ value: Value, to descriptor: Int32) {
    guard var data = try? JSONEncoder.bridge.encode(value) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var sent = 0
      while sent < bytes.count {
        let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
        if count <= 0 { return }
        sent += count
      }
    }
  }

  private func loadOrCreateToken() throws -> String {
    let url = paths.tokenURL
    if try Self.secureExistingRegularFile(at: url, invalid: .insecureTokenFile) {
      let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard Data(base64Encoded: token)?.count == 32 else {
        throw SocketServerError.insecureTokenFile
      }
      return token
    }

    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw SocketServerError.insecureTokenFile
    }
    let token = Data(bytes).base64EncodedString()
    try Data(token.utf8).write(to: url, options: .atomic)
    try Self.secureRegularFile(at: url, invalid: .insecureTokenFile)
    return token
  }

  private func publishRuntimeMetadata() throws {
    let url = paths.runtimeMetadataURL
    _ = try Self.secureExistingRegularFile(at: url, invalid: .insecureRuntimeMetadataFile)
    let metadata = RuntimeMetadata(
      version: BridgeEvent.currentVersion,
      socketPath: paths.socketURL.path,
      tokenPath: paths.tokenURL.path,
      pid: getpid(),
      uid: getuid(),
      appVersion: ProductVersion.marketing,
      sourceCommit: ProductVersion.sourceCommit,
      approvalTimeout: approvalTimeout()
    )
    let data = try JSONEncoder.bridge.encode(metadata)
    try data.write(to: url, options: .atomic)
    try Self.secureRegularFile(at: url, invalid: .insecureRuntimeMetadataFile)
  }

  private static func secureExistingRegularFile(
    at url: URL, invalid: SocketServerError
  ) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return false }
      throw invalid
    }
    try secureRegularFile(at: url, invalid: invalid)
    return true
  }

  private static func secureRegularFile(at url: URL, invalid: SocketServerError) throws {
    var initial = stat()
    guard lstat(url.path, &initial) == 0,
      (initial.st_mode & S_IFMT) == S_IFREG,
      initial.st_uid == getuid()
    else { throw invalid }
    guard chmod(url.path, 0o600) == 0 else { throw SocketServerError.permissions(errno) }

    var secured = stat()
    guard lstat(url.path, &secured) == 0,
      (secured.st_mode & S_IFMT) == S_IFREG,
      secured.st_uid == getuid(),
      secured.st_mode & 0o777 == 0o600
    else { throw invalid }
  }

  private static func removeOwnedRegularFileIfPresent(at url: URL) {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else { return }
    unlink(url.path)
  }

  private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
}
