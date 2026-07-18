import Darwin
import Foundation

struct PersistedLifecycleSession: Codable, Equatable, Sendable {
  let sessionID: String
  let turnID: String?
  let workingDirectory: String
  let model: String?
  let updatedAt: Date
}

enum LifecycleLedger {
  static let currentVersion = 1
  static let staleInterval: TimeInterval = 24 * 60 * 60

  static func load(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    now: Date = Date()
  ) -> [PersistedLifecycleSession] {
    withLock(homeDirectory: homeDirectory) {
      let entries = readLedger(homeDirectory: homeDirectory)?.sessions ?? []
      return active(entries, now: now)
    } ?? []
  }

  static func markWorking(
    sessionID: String,
    turnID: String?,
    workingDirectory: String,
    model: String?,
    updatedAt: Date,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    try mutate(homeDirectory: homeDirectory, now: updatedAt) { sessions in
      sessions.removeAll { $0.sessionID == sessionID }
      sessions.append(
        PersistedLifecycleSession(
          sessionID: sessionID,
          turnID: turnID,
          workingDirectory: workingDirectory,
          model: model,
          updatedAt: updatedAt
        ))
    }
  }

  static func remove(
    sessionID: String,
    now: Date = Date(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    try mutate(homeDirectory: homeDirectory, now: now) { sessions in
      sessions.removeAll { $0.sessionID == sessionID }
    }
  }

  static func clear(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    _ = withLock(homeDirectory: homeDirectory) {
      try? FileManager.default.removeItem(at: ledgerURL(homeDirectory: homeDirectory))
    }
  }

  private struct LedgerFile: Codable {
    let version: Int
    let sessions: [PersistedLifecycleSession]
  }

  private static func mutate(
    homeDirectory: URL,
    now: Date,
    change: (inout [PersistedLifecycleSession]) -> Void
  ) throws {
    var capturedError: Error?
    let locked: Bool? = withLock(homeDirectory: homeDirectory) {
      do {
        var sessions = active(readLedger(homeDirectory: homeDirectory)?.sessions ?? [], now: now)
        change(&sessions)
        try writeLedger(sessions, homeDirectory: homeDirectory)
      } catch {
        capturedError = error
      }
      return true
    }
    if let capturedError { throw capturedError }
    if locked == nil { throw CocoaError(.fileLocking) }
  }

  private static func active(
    _ sessions: [PersistedLifecycleSession],
    now: Date
  ) -> [PersistedLifecycleSession] {
    let cutoff = now.addingTimeInterval(-staleInterval)
    return sessions.filter { $0.updatedAt >= cutoff && $0.updatedAt <= now.addingTimeInterval(60) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private static func readLedger(homeDirectory: URL) -> LedgerFile? {
    let url = ledgerURL(homeDirectory: homeDirectory)
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      (info.st_mode & 0o077) == 0,
      let data = try? Data(contentsOf: url)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let ledger = try? decoder.decode(LedgerFile.self, from: data),
      ledger.version == currentVersion
    else { return nil }
    return ledger
  }

  private static func writeLedger(
    _ sessions: [PersistedLifecycleSession],
    homeDirectory: URL
  ) throws {
    let directory = supportDirectory(homeDirectory: homeDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(LedgerFile(version: currentVersion, sessions: sessions))
    let temporaryURL = directory.appendingPathComponent(".active-sessions.\(UUID().uuidString).tmp")
    try data.write(to: temporaryURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    guard Darwin.rename(temporaryURL.path, ledgerURL(homeDirectory: homeDirectory).path) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temporaryURL)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

  private static func withLock<T>(homeDirectory: URL, operation: () -> T) -> T? {
    let directory = supportDirectory(homeDirectory: homeDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let lockURL = directory.appendingPathComponent("active-sessions.lock")
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { return nil }
    defer { flock(descriptor, LOCK_UN) }
    return operation()
  }

  private static func supportDirectory(homeDirectory: URL) -> URL {
    homeDirectory.appendingPathComponent("Library/Application Support/Cowlick", isDirectory: true)
  }

  private static func ledgerURL(homeDirectory: URL) -> URL {
    supportDirectory(homeDirectory: homeDirectory).appendingPathComponent("active-sessions.json")
  }
}
