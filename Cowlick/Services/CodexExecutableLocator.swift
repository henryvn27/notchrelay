import Foundation

enum CodexExecutableLocatorError: LocalizedError, Equatable {
  case notFound

  var errorDescription: String? {
    "Codex is installed, but Cowlick could not locate a working Codex executable."
  }
}

struct CodexExecutableLocator: Sendable {
  private let candidates: [URL]

  init(
    candidates: [URL]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    if let candidates {
      self.candidates = candidates
      return
    }

    var resolved: [URL] = []
    if let explicit = environment["COWLICK_CODEX_PATH"], !explicit.isEmpty {
      resolved.append(URL(fileURLWithPath: explicit))
    }
    resolved.append(contentsOf: [
      URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
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
      let path = candidate.standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      if FileManager.default.isExecutableFile(atPath: path) { return candidate }
    }
    throw CodexExecutableLocatorError.notFound
  }
}
