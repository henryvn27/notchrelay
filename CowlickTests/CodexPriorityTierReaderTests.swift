import Foundation
import SQLite3
import XCTest

@testable import Cowlick

final class CodexPriorityTierReaderTests: XCTestCase {
  private var directory: URL!
  private var databaseURL: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-priority-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appendingPathComponent("logs_2.sqlite")
    try createDatabase()
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testAcceptsOnlyExactPriorityResponseCreateRows() throws {
    try insert(
      "turn.id=priority-turn: websocket request: "
        + #"{"type":"response.create","service_tier":"priority"}"#)
    try insert(
      "turn.id=standard-turn: websocket request: "
        + #"{"type":"response.create","service_tier":"auto"}"#)
    try insert(
      "websocket request: "
        + #"{"type":"response.create","service_tier":"priority","turn_id":"fallback-turn"}"#)
    try insert(
      "turn.id=case-turn: websocket request: "
        + #"{"type":"response.create","service_tier":"Priority"}"#)
    var reader = CodexPriorityTierReader(databaseURL: databaseURL)

    let snapshot = reader.snapshot(for: interval)

    XCTAssertEqual(snapshot.priorityTurnIDs, ["priority-turn", "fallback-turn"])
    XCTAssertTrue(snapshot.isComplete)
    XCTAssertTrue(snapshot.supportsTurnCorrelation)
  }

  func testMalformedAndOversizedRowsMarkPartialWithoutDroppingConfirmedTurns() throws {
    let secret = "TRACE-BODY-SECRET-DO-NOT-RETAIN"
    try insert(
      "turn.id=confirmed: websocket request: "
        + #"{"type":"response.create","service_tier":"priority","metadata":"\#(secret)"}"#)
    try insert("turn.id=malformed: websocket request: {not-json")
    try insert(
      "turn.id=oversized: websocket request: "
        + String(repeating: "x", count: CodexPriorityTierReader.maximumBodySize + 1))
    var reader = CodexPriorityTierReader(databaseURL: databaseURL)

    let snapshot = reader.snapshot(for: interval)

    XCTAssertEqual(snapshot.priorityTurnIDs, ["confirmed"])
    XCTAssertFalse(snapshot.isComplete)
    XCTAssertEqual(reader.lastScanMetrics.rejectedOversizedRowCount, 1)
    XCTAssertFalse(String(reflecting: reader).contains(secret))
  }

  func testSecondScanReadsOnlyAppendedRows() throws {
    try insert(
      "turn.id=first: websocket request: "
        + #"{"type":"response.create","service_tier":"priority"}"#)
    var reader = CodexPriorityTierReader(databaseURL: databaseURL)
    XCTAssertEqual(reader.snapshot(for: interval).priorityTurnIDs, ["first"])
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 1)
    XCTAssertFalse(reader.lastScanMetrics.usedIncrementalScan)

    try insert(
      "turn.id=second: websocket request: "
        + #"{"type":"response.create","service_tier":"priority"}"#)
    XCTAssertEqual(reader.snapshot(for: interval).priorityTurnIDs, ["first", "second"])
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 1)
    XCTAssertTrue(reader.lastScanMetrics.usedIncrementalScan)
  }

  func testInitialScanStopsAtBudgetAndReturnsConfirmedPartialResult() throws {
    for turn in ["oldest", "older", "middle", "newer", "newest"] {
      try insert(
        "turn.id=\(turn): websocket request: "
          + #"{"type":"response.create","service_tier":"priority"}"#)
    }
    var reader = CodexPriorityTierReader(
      databaseURL: databaseURL,
      scanPolicy: CodexPriorityTierScanPolicy(batchSize: 2, maximumRowsPerSnapshot: 3)
    )

    let snapshot = reader.snapshot(for: interval)

    XCTAssertEqual(snapshot.priorityTurnIDs, ["middle", "newer", "newest"])
    XCTAssertFalse(snapshot.isComplete)
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 3)
    XCTAssertTrue(reader.lastScanMetrics.exhaustedBudget)
    XCTAssertTrue(reader.lastScanMetrics.hasPendingBackfill)
  }

  func testPartialBackfillResumesFromCursorWithoutRescanningNewerRows() throws {
    for turn in ["oldest", "middle", "newest"] {
      try insert(
        "turn.id=\(turn): websocket request: "
          + #"{"type":"response.create","service_tier":"priority"}"#)
    }
    var reader = CodexPriorityTierReader(
      databaseURL: databaseURL,
      scanPolicy: CodexPriorityTierScanPolicy(batchSize: 2, maximumRowsPerSnapshot: 2)
    )

    XCTAssertEqual(reader.snapshot(for: interval).priorityTurnIDs, ["middle", "newest"])
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 2)
    let resumed = reader.snapshot(for: interval)
    XCTAssertTrue(resumed.isComplete)
    XCTAssertEqual(resumed.priorityTurnIDs, ["oldest", "middle", "newest"])
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 1)
  }

  func testExactResultCompletesWhenRowsFitWithinBudget() throws {
    try insert(
      "turn.id=priority: websocket request: "
        + #"{"type":"response.create","service_tier":"priority"}"#)
    try insert("ordinary log row")
    var reader = CodexPriorityTierReader(
      databaseURL: databaseURL,
      scanPolicy: CodexPriorityTierScanPolicy(batchSize: 4, maximumRowsPerSnapshot: 4)
    )

    let snapshot = reader.snapshot(for: interval)

    XCTAssertEqual(snapshot.priorityTurnIDs, ["priority"])
    XCTAssertTrue(snapshot.isComplete)
    XCTAssertEqual(reader.lastScanMetrics.scannedRowCount, 2)
    XCTAssertFalse(reader.lastScanMetrics.exhaustedBudget)
  }

  func testCancellationReturnsPartialAndResumesSafely() throws {
    for turn in ["oldest", "middle", "newest"] {
      try insert(
        "turn.id=\(turn): websocket request: "
          + #"{"type":"response.create","service_tier":"priority"}"#)
    }
    let gate = ContinuationGate(allowedRows: 1)
    var reader = CodexPriorityTierReader(
      databaseURL: databaseURL,
      scanPolicy: CodexPriorityTierScanPolicy(batchSize: 3, maximumRowsPerSnapshot: 3),
      shouldContinue: { gate.shouldContinue() }
    )

    let interrupted = reader.snapshot(for: interval)

    XCTAssertEqual(interrupted.priorityTurnIDs, ["newest"])
    XCTAssertFalse(interrupted.isComplete)
    XCTAssertTrue(reader.lastScanMetrics.wasCancelled)
    gate.allowAllRows()
    XCTAssertEqual(reader.snapshot(for: interval).priorityTurnIDs, ["oldest", "middle", "newest"])
    XCTAssertTrue(reader.snapshot(for: interval).isComplete)
  }

  func testInvalidSchemaReturnsUnavailableInsteadOfPartialData() throws {
    try execute("DROP TABLE logs")
    var reader = CodexPriorityTierReader(databaseURL: databaseURL)

    XCTAssertEqual(reader.snapshot(for: interval), .unavailable)
  }

  func testDeletedPrioritySourceIsRemovedFromMemo() throws {
    try insert(
      "turn.id=deleted: websocket request: "
        + #"{"type":"response.create","service_tier":"priority"}"#)
    var reader = CodexPriorityTierReader(databaseURL: databaseURL)
    XCTAssertEqual(reader.snapshot(for: interval).priorityTurnIDs, ["deleted"])
    try execute("DELETE FROM logs")

    XCTAssertTrue(reader.snapshot(for: interval).priorityTurnIDs.isEmpty)
  }

  func testUnavailableDatabaseFailsSafe() {
    var reader = CodexPriorityTierReader(
      databaseURL: directory.appendingPathComponent("missing.sqlite"))

    XCTAssertEqual(reader.snapshot(for: interval), .unavailable)
  }

  private var interval: DateInterval {
    DateInterval(
      start: Date(timeIntervalSince1970: 1_784_505_600),
      end: Date(timeIntervalSince1970: 1_784_592_000)
    )
  }

  private func createDatabase() throws {
    try execute(
      """
      CREATE TABLE logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        feedback_log_body TEXT
      );
      CREATE INDEX idx_logs_ts ON logs(ts DESC, id DESC);
      """)
  }

  private func insert(_ body: String, timestamp: Int64 = 1_784_509_000) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    guard let database else { throw SQLiteFixtureError.openFailed }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "INSERT INTO logs(ts, feedback_log_body) VALUES (?, ?)",
        -1,
        &statement,
        nil
      ) == SQLITE_OK
    else { throw SQLiteFixtureError.prepareFailed }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, timestamp)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 2, body, -1, transient)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFixtureError.writeFailed }
  }

  private func execute(_ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      sqlite3_close(database)
      throw SQLiteFixtureError.openFailed
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw SQLiteFixtureError.writeFailed
    }
  }
}

enum SQLiteFixtureError: Error {
  case openFailed
  case prepareFailed
  case writeFailed
}

private final class ContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var remainingRows: Int?

  init(allowedRows: Int) {
    remainingRows = allowedRows
  }

  func shouldContinue() -> Bool {
    lock.withLock {
      guard let remainingRows else { return true }
      guard remainingRows > 0 else { return false }
      self.remainingRows = remainingRows - 1
      return true
    }
  }

  func allowAllRows() {
    lock.withLock { remainingRows = nil }
  }
}
