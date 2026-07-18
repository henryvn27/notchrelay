import Darwin
import XCTest

@testable import Cowlick

final class LocalSocketServerTests: XCTestCase {
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
