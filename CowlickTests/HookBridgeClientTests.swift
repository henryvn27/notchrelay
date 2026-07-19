import Darwin
import XCTest

final class HookBridgeClientTests: XCTestCase {
  func testUnavailableAppFailsSafely() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let client = HookBridgeClient(homeDirectory: home)
    let event = HookBridgeEvent(event: .approvalRequested, sessionId: "s", cwd: "/tmp")

    XCTAssertThrowsError(try client.send(event, waitForResponse: true))
  }

  func testRejectsInsecureRuntimeMetadata() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let metadataURL = home.appendingPathComponent(
      "Library/Application Support/Cowlick/runtime.json")
    try FileManager.default.createDirectory(
      at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: metadataURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: metadataURL.path)

    let client = HookBridgeClient(homeDirectory: home)
    XCTAssertThrowsError(
      try client.send(
        HookBridgeEvent(event: .ping, sessionId: "s", cwd: "/tmp"), waitForResponse: false)
    ) { error in
      XCTAssertEqual(error as? HookBridgeError, .insecureMetadata)
    }
  }

  func testRejectsMismatchedApprovalResponseID() throws {
    let fixture = try makeSocketFixture(responseRequestID: UUID(), responseDecision: .allow)
    defer { fixture.cleanup() }
    let event = HookBridgeEvent(
      requestId: UUID(), event: .approvalRequested, sessionId: "s", cwd: "/tmp")

    XCTAssertThrowsError(try fixture.client.send(event, waitForResponse: true)) { error in
      XCTAssertEqual(error as? HookBridgeError, .mismatchedResponse)
    }
  }

  func testRejectsMalformedSocketResponse() throws {
    let fixture = try makeSocketFixture(rawResponse: Data("not-json\n".utf8))
    defer { fixture.cleanup() }

    XCTAssertThrowsError(
      try fixture.client.send(
        HookBridgeEvent(event: .approvalRequested, sessionId: "s", cwd: "/tmp"),
        waitForResponse: true)
    ) { error in
      XCTAssertEqual(error as? HookBridgeError, .malformedResponse)
    }
  }

  func testApprovalResponseTimeoutFailsSafely() throws {
    let fixture = try makeSocketFixture(responseDelay: 2, approvalTimeout: 0.01)
    defer { fixture.cleanup() }

    XCTAssertThrowsError(
      try fixture.client.send(
        HookBridgeEvent(event: .approvalRequested, sessionId: "s", cwd: "/tmp"),
        waitForResponse: true)
    ) { error in
      guard case HookBridgeError.socketFailure = error else {
        return XCTFail("Expected socket timeout, got \(error)")
      }
    }
  }

  func testPingWaitsForMatchingAcceptedAcknowledgement() throws {
    let requestID = UUID()
    let acknowledgement = HookBridgeAcknowledgement(
      version: HookBridgeEvent.currentVersion,
      requestId: requestID,
      accepted: true,
      error: nil
    )
    var response = try JSONEncoder().encode(acknowledgement)
    response.append(0x0A)
    let fixture = try makeSocketFixture(rawResponse: response)
    defer { fixture.cleanup() }

    XCTAssertNoThrow(
      try fixture.client.send(
        HookBridgeEvent(
          requestId: requestID, event: .ping, sessionId: "diagnostics", cwd: "/tmp"),
        waitForResponse: true)
    )
  }

  func testPingRejectsNegativeAcknowledgement() throws {
    let requestID = UUID()
    let acknowledgement = HookBridgeAcknowledgement(
      version: HookBridgeEvent.currentVersion,
      requestId: requestID,
      accepted: false,
      error: "Authentication failed"
    )
    var response = try JSONEncoder().encode(acknowledgement)
    response.append(0x0A)
    let fixture = try makeSocketFixture(rawResponse: response)
    defer { fixture.cleanup() }

    XCTAssertThrowsError(
      try fixture.client.send(
        HookBridgeEvent(
          requestId: requestID, event: .ping, sessionId: "diagnostics", cwd: "/tmp"),
        waitForResponse: true)
    ) { error in
      XCTAssertEqual(error as? HookBridgeError, .rejectedResponse)
    }
  }

  private func makeTemporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CowlickTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private struct SocketFixture {
    let client: HookBridgeClient
    let home: URL
    let socketPath: String
    let listener: Int32

    func cleanup() {
      Darwin.close(listener)
      unlink(socketPath)
      try? FileManager.default.removeItem(at: home)
    }
  }

  private func makeSocketFixture(
    responseRequestID: UUID = UUID(),
    responseDecision: HookApprovalDecision = .allow,
    rawResponse: Data? = nil,
    responseDelay: TimeInterval = 0,
    approvalTimeout: TimeInterval = 2
  ) throws -> SocketFixture {
    let home = try makeTemporaryHome()
    let runtimeDirectory = home.appendingPathComponent("Library/Application Support/Cowlick")
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    let socketPath = "/tmp/cowlick-\(UUID().uuidString.prefix(8)).sock"
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    unlink(socketPath)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
        for index in bytes.indices { destination[index] = bytes[index] }
      }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, length)
      }
    }
    XCTAssertEqual(bindResult, 0)
    XCTAssertEqual(Darwin.listen(listener, 1), 0)

    let tokenURL = runtimeDirectory.appendingPathComponent("auth-token")
    try Data("test-token".utf8).write(to: tokenURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    let metadata = HookRuntimeMetadata(
      version: HookBridgeEvent.currentVersion,
      socketPath: socketPath,
      tokenPath: tokenURL.path,
      pid: getpid(),
      uid: getuid(),
      appVersion: "1.0.0",
      approvalTimeout: approvalTimeout
    )
    let metadataURL = runtimeDirectory.appendingPathComponent("runtime.json")
    try JSONEncoder().encode(metadata).write(to: metadataURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

    let response =
      rawResponse
      ?? {
        let value = ApprovalBridgeResponse(
          version: HookBridgeEvent.currentVersion, requestId: responseRequestID,
          decision: responseDecision)
        var data = try! JSONEncoder().encode(value)
        data.append(0x0A)
        return data
      }()
    DispatchQueue.global(qos: .userInitiated).async {
      let client = Darwin.accept(listener, nil, nil)
      guard client >= 0 else { return }
      var noSigPipe: Int32 = 1
      _ = withUnsafePointer(to: &noSigPipe) { pointer in
        Darwin.setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, pointer,
          socklen_t(MemoryLayout<Int32>.size)
        )
      }
      var buffer = [UInt8](repeating: 0, count: 4_096)
      _ = Darwin.recv(client, &buffer, buffer.count, 0)
      if responseDelay > 0 { Thread.sleep(forTimeInterval: responseDelay) }
      response.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress { _ = Darwin.send(client, base, bytes.count, 0) }
      }
      Darwin.close(client)
    }

    return SocketFixture(
      client: HookBridgeClient(homeDirectory: home), home: home, socketPath: socketPath,
      listener: listener)
  }
}

extension HookBridgeError: Equatable {
  static func == (lhs: HookBridgeError, rhs: HookBridgeError) -> Bool {
    switch (lhs, rhs) {
    case (.appUnavailable, .appUnavailable), (.insecureMetadata, .insecureMetadata),
      (.unsupportedVersion, .unsupportedVersion), (.oversizedMessage, .oversizedMessage),
      (.malformedResponse, .malformedResponse), (.mismatchedResponse, .mismatchedResponse),
      (.rejectedResponse, .rejectedResponse):
      true
    case (.socketFailure(let left), .socketFailure(let right)): left == right
    default: false
    }
  }
}
