import AppKit
import Darwin
import Foundation

enum CodexExecutableLocatorError: LocalizedError, Equatable {
  case notFound

  var errorDescription: String? {
    "Codex is installed, but Cowlick could not locate a working Codex executable."
  }
}

struct CodexExecutableLocator: Sendable {
  typealias Validator = @Sendable (URL) -> Bool
  private static let defaultValidator: Validator = { url in
    isWorkingCodexExecutable(url)
  }

  private let candidates: [URL]
  private let validator: Validator
  private let validationCache: ExecutableValidationCache?

  init(
    candidates: [URL]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    runningApplicationURLs: [URL]? = nil,
    installedApplicationURLs: [URL]? = nil,
    validator: Validator? = nil
  ) {
    self.validator = validator ?? Self.defaultValidator
    validationCache = validator == nil ? ExecutableValidationCache() : nil
    if let candidates {
      self.candidates = candidates
      return
    }

    var resolved: [URL] = []
    if let explicit = environment["COWLICK_CODEX_PATH"], !explicit.isEmpty {
      resolved.append(URL(fileURLWithPath: explicit))
    }
    let runningApplications = runningApplicationURLs ?? Self.runningCodexApplicationURLs()
    let installedApplications =
      installedApplicationURLs ?? [
        URL(fileURLWithPath: "/Applications/Codex.app"),
        URL(fileURLWithPath: "/Applications/ChatGPT.app"),
      ]
    resolved.append(
      contentsOf: Self.applicationExecutableURLs(
        runningApplications + Self.newestFirst(installedApplications)))
    resolved.append(contentsOf: [
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
      URL(fileURLWithPath: "/usr/local/bin/codex"),
      homeDirectory.appendingPathComponent(".local/bin/codex"),
    ])

    if let path = environment["PATH"] {
      resolved.append(
        contentsOf: path.split(separator: ":").map {
          URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
        })
    }
    self.candidates = resolved
  }

  func locate() throws -> URL {
    var seen = Set<String>()
    for candidate in candidates {
      try Task.checkCancellation()
      let path = candidate.standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      if let identity = Self.executableIdentity(at: candidate),
        validationCache?.matches(path: path, identity: identity) == true
      {
        return candidate
      }
      if validator(candidate) {
        if let identity = Self.executableIdentity(at: candidate) {
          validationCache?.store(path: path, identity: identity)
        } else {
          validationCache?.clear()
        }
        return candidate
      }
      validationCache?.clear(path: path)
      try Task.checkCancellation()
    }
    throw CodexExecutableLocatorError.notFound
  }

  static func applicationExecutableURLs(_ applicationURLs: [URL]) -> [URL] {
    applicationURLs.map {
      $0.appendingPathComponent("Contents/Resources/codex", isDirectory: false)
    }
  }

  static func newestFirst(_ applicationURLs: [URL]) -> [URL] {
    applicationURLs.sorted {
      applicationVersion(at: $0).compare(
        applicationVersion(at: $1), options: .numeric) == .orderedDescending
    }
  }

  static func isWorkingCodexExecutable(_ url: URL) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
    var info = stat()
    guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }

    do {
      let runner = try BoundedProcessRunner(
        executableURL: url,
        arguments: ["--version"],
        timeout: 2,
        maximumOutputSize: 4_096
      )
      defer { runner.stop() }
      try runner.readToExit()
      guard let version = String(data: runner.output, encoding: .utf8)?.lowercased() else {
        return false
      }
      return version.hasPrefix("codex-cli ") || version.hasPrefix("codex ")
    } catch {
      return false
    }
  }

  private static func executableIdentity(at url: URL) -> ExecutableIdentity? {
    guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
    var info = stat()
    guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    return ExecutableIdentity(
      device: UInt64(info.st_dev),
      inode: UInt64(info.st_ino),
      mode: UInt32(info.st_mode),
      size: Int64(info.st_size),
      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changeSeconds: Int64(info.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
    )
  }

  private static func runningCodexApplicationURLs() -> [URL] {
    NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier == "com.openai.codex" }
      .sorted {
        if $0.isActive != $1.isActive { return $0.isActive }
        guard let left = $0.bundleURL, let right = $1.bundleURL else {
          return $0.bundleURL != nil
        }
        return applicationVersion(at: left).compare(
          applicationVersion(at: right), options: .numeric) == .orderedDescending
      }
      .compactMap(\.bundleURL)
  }

  private static func applicationVersion(at applicationURL: URL) -> String {
    let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
      let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let info = value as? [String: Any]
    else { return "0" }
    return info["CFBundleVersion"] as? String
      ?? info["CFBundleShortVersionString"] as? String
      ?? "0"
  }
}

private struct ExecutableIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt32
  let size: Int64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
  let changeSeconds: Int64
  let changeNanoseconds: Int64
}

private final class ExecutableValidationCache: @unchecked Sendable {
  private let lock = NSLock()
  private var validatedPath: String?
  private var validatedIdentity: ExecutableIdentity?

  func matches(path: String, identity: ExecutableIdentity) -> Bool {
    lock.withLock {
      validatedPath == path && validatedIdentity == identity
    }
  }

  func store(path: String, identity: ExecutableIdentity) {
    lock.withLock {
      validatedPath = path
      validatedIdentity = identity
    }
  }

  func clear(path: String? = nil) {
    lock.withLock {
      guard path == nil || validatedPath == path else { return }
      validatedPath = nil
      validatedIdentity = nil
    }
  }
}
