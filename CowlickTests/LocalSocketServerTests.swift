import Darwin
import XCTest

@testable import Cowlick

final class LocalSocketServerTests: XCTestCase {
  func testStartupFailureCleansSocketAndCanRestartWithOwnerOnlyFiles() throws {
    let fixture = try ServerPathFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.paths.runtimeMetadataURL, withIntermediateDirectories: false)
    let server = fixture.makeServer()

    XCTAssertThrowsError(try server.start()) { error in
      guard case SocketServerError.insecureRuntimeMetadataFile = error else {
        return XCTFail("Expected insecureRuntimeMetadataFile, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.socketURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.runtimeMetadataURL.path))

    try FileManager.default.removeItem(at: fixture.paths.runtimeMetadataURL)
    try server.start()
    defer { server.stop() }

    XCTAssertEqual(try permissions(of: fixture.paths.tokenURL), 0o600)
    XCTAssertEqual(try permissions(of: fixture.paths.runtimeMetadataURL), 0o600)
  }

  func testExistingRuntimeFilesAreRepairedToOwnerOnlyPermissions() throws {
    let fixture = try ServerPathFixture()
    defer { fixture.cleanup() }
    let token = Data((Data(repeating: 7, count: 32).base64EncodedString()).utf8)
    try token.write(to: fixture.paths.tokenURL)
    try Data("stale".utf8).write(to: fixture.paths.runtimeMetadataURL)
    XCTAssertEqual(chmod(fixture.paths.tokenURL.path, 0o644), 0)
    XCTAssertEqual(chmod(fixture.paths.runtimeMetadataURL.path, 0o644), 0)
    let server = fixture.makeServer()

    try server.start()
    defer { server.stop() }

    XCTAssertEqual(try permissions(of: fixture.paths.tokenURL), 0o600)
    XCTAssertEqual(try permissions(of: fixture.paths.runtimeMetadataURL), 0o600)
  }

  func testRejectsTokenSymlinkBeforeOpeningSocket() throws {
    let fixture = try ServerPathFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("target-token")
    try Data(Data(repeating: 9, count: 32).base64EncodedString().utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.paths.tokenURL, withDestinationURL: target)
    let server = fixture.makeServer()

    XCTAssertThrowsError(try server.start()) { error in
      guard case SocketServerError.insecureTokenFile = error else {
        return XCTFail("Expected insecureTokenFile, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.socketURL.path))
  }

  func testRecoversOwnedStaleSocket() throws {
    let fixture = try SocketPathFixture(listening: false)
    defer { fixture.cleanup() }

    try LocalSocketServer.recoverStaleSocket(at: fixture.path)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
  }

  func testDoesNotReplaceLiveSocket() throws {
    let fixture = try SocketPathFixture(listening: true)
    defer { fixture.cleanup() }

    XCTAssertThrowsError(try LocalSocketServer.recoverStaleSocket(at: fixture.path)) { error in
      guard case SocketServerError.alreadyRunning = error else {
        return XCTFail("Expected alreadyRunning, got \(error)")
      }
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
  }

  func testRejectsRegularFileAtSocketPath() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("Cowlick-Regular-\(UUID().uuidString)").path
    FileManager.default.createFile(atPath: path, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertThrowsError(try LocalSocketServer.recoverStaleSocket(at: path)) { error in
      guard case SocketServerError.unsafeExistingSocketPath = error else {
        return XCTFail("Expected unsafeExistingSocketPath, got \(error)")
      }
    }
  }

  private func permissions(of url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    return info.st_mode & 0o777
  }

  private struct ServerPathFixture {
    let root: URL
    let paths: LocalSocketServerPaths

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Cowlick-Server-\(UUID().uuidString.prefix(8))", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      paths = LocalSocketServerPaths(
        tokenURL: root.appendingPathComponent("auth-token"),
        runtimeMetadataURL: root.appendingPathComponent("runtime.json"),
        socketURL: root.appendingPathComponent("bridge.sock")
      )
    }

    func makeServer() -> LocalSocketServer {
      LocalSocketServer(
        approvalTimeout: { 1 },
        paths: paths,
        prepareDirectories: {},
        eventHandler: { _ in nil }
      )
    }

    func cleanup() {
      unlink(paths.socketURL.path)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private struct SocketPathFixture {
    let path: String
    let descriptor: Int32

    init(listening: Bool) throws {
      path =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("Cowlick-Socket-\(UUID().uuidString.prefix(8))").path
      let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard socketDescriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
      unlink(path)

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
          Darwin.bind(socketDescriptor, $0, length)
        }
      }
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
      if listening {
        guard Darwin.listen(socketDescriptor, 1) == 0 else { throw POSIXError(.EINVAL) }
        descriptor = socketDescriptor
      } else {
        Darwin.close(socketDescriptor)
        descriptor = -1
      }
    }

    func cleanup() {
      if descriptor >= 0 { Darwin.close(descriptor) }
      unlink(path)
    }
  }
}
