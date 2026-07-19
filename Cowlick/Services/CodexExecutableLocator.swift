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

  private let candidates: [URL]
  private let validator: Validator

  init(
    candidates: [URL]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    runningApplicationURLs: [URL]? = nil,
    installedApplicationURLs: [URL]? = nil,
    validator: @escaping Validator = Self.isWorkingCodexExecutable
  ) {
    self.validator = validator
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
      if validator(candidate) { return candidate }
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
