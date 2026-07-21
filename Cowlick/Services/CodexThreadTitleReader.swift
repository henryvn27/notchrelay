import Darwin
import Foundation
import SQLite3

struct CodexThreadTitleReader: Sendable {
  static let maximumStoredTitleBytes = 2_048
  static let maximumDisplayLength = 80
  static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
    .appendingPathComponent("sqlite", isDirectory: true)
    .appendingPathComponent("codex-dev.db")
  static let defaultStateDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
    .appendingPathComponent("state_5.sqlite")

  private let databaseURL: URL
  private let stateDatabaseURL: URL?

  init(
    databaseURL: URL = Self.defaultDatabaseURL,
    stateDatabaseURL: URL? = Self.defaultStateDatabaseURL
  ) {
    self.databaseURL = databaseURL
    self.stateDatabaseURL = stateDatabaseURL
  }

  func title(for sessionID: String, allowPromptDerivedFallback: Bool = false) -> String? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    if let title = catalogTitle(for: sessionID) { return title }
    guard allowPromptDerivedFallback, let stateDatabaseURL else { return nil }
    return stateTitle(for: sessionID, databaseURL: stateDatabaseURL)
  }

  private func catalogTitle(for sessionID: String) -> String? {
    let query = """
      SELECT catalog.display_title
      FROM local_thread_catalog AS catalog
      INNER JOIN local_thread_catalog_hosts AS host ON host.host_id = catalog.host_id
      WHERE catalog.thread_id = ?1
        AND host.host_kind = 'local'
        AND length(CAST(catalog.display_title AS BLOB)) BETWEEN 1 AND ?2
      ORDER BY catalog.observation_sequence DESC
      LIMIT 1
      """
    return readTitle(from: databaseURL, sessionID: sessionID, query: query)
  }

  private func stateTitle(for sessionID: String, databaseURL: URL) -> String? {
    let query = """
      SELECT title
      FROM threads
      WHERE id = ?1
        AND length(CAST(title AS BLOB)) BETWEEN 1 AND ?2
      LIMIT 1
      """
    return readTitle(from: databaseURL, sessionID: sessionID, query: query)
  }

  private func readTitle(from url: URL, sessionID: String, query: String) -> String? {
    guard Self.isOwnedRegularFile(url) else { return nil }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
        nil
      ) == SQLITE_OK,
      let database
    else {
      sqlite3_close(database)
      return nil
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 150)

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, sessionID, -1, transient)
    sqlite3_bind_int(statement, 2, Int32(Self.maximumStoredTitleBytes))
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_type(statement, 0) == SQLITE_TEXT,
      let bytes = sqlite3_column_text(statement, 0)
    else { return nil }

    let byteCount = Int(sqlite3_column_bytes(statement, 0))
    guard byteCount > 0, byteCount <= Self.maximumStoredTitleBytes else { return nil }
    let data = Data(bytes: bytes, count: byteCount)
    guard let rawTitle = String(data: data, encoding: .utf8) else { return nil }
    return Self.displayTitle(from: rawTitle)
  }

  static func displayTitle(from value: String) -> String? {
    let normalized = value.precomposedStringWithCanonicalMapping
    let collapsed = EventLogger.sanitizeError(normalized)
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }

    var result = ""
    for character in collapsed {
      let candidate = result + String(character)
      guard candidate.count <= maximumDisplayLength,
        candidate.lengthOfBytes(using: .utf8) <= 512
      else {
        while !result.isEmpty,
          (result + "…").count > maximumDisplayLength
            || (result + "…").lengthOfBytes(using: .utf8) > 512
        {
          result.removeLast()
        }
        return result.isEmpty ? nil : result + "…"
      }
      result = candidate
    }
    return result
  }

  private static func isOwnedRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid()
    else { return false }
    return true
  }
}
