import Foundation
import SQLite3
import XCTest

@testable import Cowlick

final class CodexThreadTitleReaderTests: XCTestCase {
  func testReadsValidatedPinnedThreadIDsFromCodexGlobalState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Pinned-Threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstID = UUID().uuidString.lowercased()
    let secondID = UUID().uuidString.lowercased()
    let stateURL = directory.appendingPathComponent(".codex-global-state.json")
    let data = try JSONSerialization.data(withJSONObject: [
      "pinned-thread-ids": [firstID, secondID, firstID],
      "unrelated-setting": true,
    ])
    try data.write(to: stateURL)

    XCTAssertEqual(
      CodexPinnedThreadReader(stateURL: stateURL).threadIDs(),
      Set([firstID, secondID]))
  }

  func testPinnedThreadReaderFailsOpenForUnsafeOrMalformedState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Cowlick-Pinned-Threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    try Data(#"{"pinned-thread-ids":["not-a-thread"]}"#.utf8).write(to: stateURL)
    XCTAssertNil(CodexPinnedThreadReader(stateURL: stateURL).threadIDs())

    let linkURL = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: stateURL)
    XCTAssertNil(CodexPinnedThreadReader(stateURL: linkURL).threadIDs())
  }

  func testReadsLatestLocalTitleForExactSession() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sessionID = UUID().uuidString
    try fixture.insertHost(id: "local-host", kind: "local")
    try fixture.insertHost(id: "remote-host", kind: "ssh")
    try fixture.insert(
      hostID: "remote-host", sessionID: sessionID, title: "Remote spoof", sequence: 99)
    try fixture.insert(
      hostID: "local-host", sessionID: sessionID, title: "  Polish\n the\t notch  ", sequence: 3)

    let reader = CodexThreadTitleReader(databaseURL: fixture.databaseURL, stateDatabaseURL: nil)
    let title = reader.title(for: sessionID)

    XCTAssertEqual(title, "Polish the notch")
    XCTAssertNil(
      reader.title(for: UUID().uuidString))
  }

  func testRejectsNonUUIDAndOversizedTitle() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let sessionID = UUID().uuidString
    try fixture.insertHost(id: "local-host", kind: "local")
    try fixture.insert(
      hostID: "local-host",
      sessionID: sessionID,
      title: String(repeating: "x", count: CodexThreadTitleReader.maximumStoredTitleBytes + 1),
      sequence: 1)

    let reader = CodexThreadTitleReader(databaseURL: fixture.databaseURL, stateDatabaseURL: nil)
    XCTAssertNil(reader.title(for: sessionID))
    XCTAssertNil(reader.title(for: "not-a-session-id"))
  }

  func testRejectsSymlinkedDatabase() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let link = fixture.directory.appendingPathComponent("linked.db")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.databaseURL)

    XCTAssertNil(
      CodexThreadTitleReader(databaseURL: link, stateDatabaseURL: nil).title(
        for: UUID().uuidString))
  }

  func testPromptDerivedStateTitleRequiresExplicitPreviewPermission() throws {
    let catalog = try Fixture()
    let state = try StateFixture()
    defer {
      catalog.remove()
      state.remove()
    }
    let sessionID = UUID().uuidString
    try state.insert(sessionID: sessionID, title: "Review a private release command")
    let reader = CodexThreadTitleReader(
      databaseURL: catalog.databaseURL,
      stateDatabaseURL: state.databaseURL
    )

    XCTAssertNil(reader.title(for: sessionID, allowPromptDerivedFallback: false))
    XCTAssertEqual(
      reader.title(for: sessionID, allowPromptDerivedFallback: true),
      "Review a private release command")
  }

  func testDisplayTitleRedactsUnsafeAndSensitiveContent() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let value = "Release\u{202E}\n token=secret-value from \(home)/Private"
    let title = CodexThreadTitleReader.displayTitle(from: value)

    XCTAssertFalse(title?.contains("\u{202E}") == true)
    XCTAssertFalse(title?.contains("secret-value") == true)
    XCTAssertFalse(title?.contains(home) == true)
    XCTAssertTrue(title?.contains("<redacted>") == true)
    XCTAssertLessThanOrEqual(title?.count ?? .max, CodexThreadTitleReader.maximumDisplayLength + 1)
    XCTAssertLessThanOrEqual(title?.lengthOfBytes(using: .utf8) ?? .max, 512)
  }

  private final class Fixture {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Cowlick-Thread-Titles-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      databaseURL = directory.appendingPathComponent("codex-dev.db")
      guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, database != nil else {
        throw CocoaError(.fileReadUnknown)
      }
      try execute(
        """
        CREATE TABLE local_thread_catalog_hosts (
          host_id TEXT PRIMARY KEY,
          host_kind TEXT NOT NULL
        );
        CREATE TABLE local_thread_catalog (
          host_id TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          display_title TEXT NOT NULL,
          observation_sequence INTEGER NOT NULL,
          PRIMARY KEY (host_id, thread_id)
        );
        """)
    }

    deinit { sqlite3_close(database) }

    func remove() {
      sqlite3_close(database)
      database = nil
      try? FileManager.default.removeItem(at: directory)
    }

    func insertHost(id: String, kind: String) throws {
      try execute("INSERT INTO local_thread_catalog_hosts VALUES ('\(id)', '\(kind)');")
    }

    func insert(hostID: String, sessionID: String, title: String, sequence: Int) throws {
      var statement: OpaquePointer?
      let sql = "INSERT INTO local_thread_catalog VALUES (?1, ?2, ?3, ?4);"
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw CocoaError(.fileWriteUnknown) }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, hostID, -1, transient)
      sqlite3_bind_text(statement, 2, sessionID, -1, transient)
      sqlite3_bind_text(statement, 3, title, -1, transient)
      sqlite3_bind_int(statement, 4, Int32(sequence))
      guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    private func execute(_ sql: String) throws {
      guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
  }

  private final class StateFixture {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Cowlick-Thread-State-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      databaseURL = directory.appendingPathComponent("state_5.sqlite")
      guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, database != nil else {
        throw CocoaError(.fileReadUnknown)
      }
      guard
        sqlite3_exec(
          database,
          "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);",
          nil,
          nil,
          nil
        ) == SQLITE_OK
      else { throw CocoaError(.fileWriteUnknown) }
    }

    deinit { sqlite3_close(database) }

    func remove() {
      sqlite3_close(database)
      database = nil
      try? FileManager.default.removeItem(at: directory)
    }

    func insert(sessionID: String, title: String) throws {
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database,
          "INSERT INTO threads VALUES (?1, ?2);",
          -1,
          &statement,
          nil
        ) == SQLITE_OK,
        let statement
      else { throw CocoaError(.fileWriteUnknown) }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, sessionID, -1, transient)
      sqlite3_bind_text(statement, 2, title, -1, transient)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
  }
}
