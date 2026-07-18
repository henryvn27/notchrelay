import Darwin
import Foundation

enum AppSupportPaths {
  static let applicationName = ProductIdentity.name

  static var applicationSupportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(applicationName, isDirectory: true)
  }

  static var binDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("bin", isDirectory: true)
  }

  static var tokenURL: URL {
    applicationSupportDirectory.appendingPathComponent("auth-token")
  }

  static var runtimeMetadataURL: URL {
    applicationSupportDirectory.appendingPathComponent("runtime.json")
  }

  static var logDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
  }

  static var privateTemporaryDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("Cowlick-\(getuid())", isDirectory: true)
  }

  static var socketURL: URL {
    privateTemporaryDirectory.appendingPathComponent("bridge.sock")
  }

  static func prepareDirectories() throws {
    try createPrivateDirectory(applicationSupportDirectory)
    try createPrivateDirectory(binDirectory)
    try createPrivateDirectory(logDirectory)
    try createPrivateDirectory(privateTemporaryDirectory)
  }

  private static func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
}
