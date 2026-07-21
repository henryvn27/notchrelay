import Darwin
import Foundation
import SQLite3

struct CodexPriorityTierSnapshot: Equatable, Sendable {
  let priorityTurnIDs: Set<String>
  let isComplete: Bool
  let supportsTurnCorrelation: Bool

  static let standardOnly = CodexPriorityTierSnapshot(
    priorityTurnIDs: [],
    isComplete: true,
    supportsTurnCorrelation: false
  )
  static let unavailable = CodexPriorityTierSnapshot(
    priorityTurnIDs: [],
    isComplete: false,
    supportsTurnCorrelation: true
  )
}

struct CodexPriorityTierScanMetrics: Equatable, Sendable {
  var scannedRowCount = 0
  var usedIncrementalScan = false
  var rejectedOversizedRowCount = 0
  var exhaustedBudget = false
  var wasCancelled = false
  var hasPendingBackfill = false
}

struct CodexPriorityTierScanPolicy: Equatable, Sendable {
  static let `default` = CodexPriorityTierScanPolicy()

  let batchSize: Int
  let maximumRowsPerSnapshot: Int

  init(batchSize: Int = 2_048, maximumRowsPerSnapshot: Int = 20_000) {
    precondition(batchSize > 0)
    precondition(maximumRowsPerSnapshot > 0)
    self.batchSize = batchSize
    self.maximumRowsPerSnapshot = maximumRowsPerSnapshot
  }
}

struct CodexPriorityTierReader {
  static let maximumBodySize = 1_048_576
  static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
    .appendingPathComponent("logs_2.sqlite")

  private let databaseURL: URL
  private let scanPolicy: CodexPriorityTierScanPolicy
  private let shouldContinue: @Sendable () -> Bool
  private var memo: Memo?
  private(set) var lastScanMetrics = CodexPriorityTierScanMetrics()

  init(
    databaseURL: URL = Self.defaultDatabaseURL,
    scanPolicy: CodexPriorityTierScanPolicy = .default,
    shouldContinue: @escaping @Sendable () -> Bool = {
      !Task<Never, Never>.isCancelled
    }
  ) {
    self.databaseURL = databaseURL
    self.scanPolicy = scanPolicy
    self.shouldContinue = shouldContinue
  }

  mutating func snapshot(for interval: DateInterval) -> CodexPriorityTierSnapshot {
    lastScanMetrics = CodexPriorityTierScanMetrics()
    guard interval.start < interval.end, let identity = fileIdentity() else { return .unavailable }

    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
        nil
      ) == SQLITE_OK,
      let database
    else {
      sqlite3_close(database)
      return .unavailable
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 250)
    guard fileIdentity() == identity else { return .unavailable }

    let requestedStart = Int64(interval.start.timeIntervalSince1970.rounded(.down))
    guard let maximumRowID = maximumRowID(in: database) else { return .unavailable }

    var state = memo
    if let current = state,
      current.identity != identity || maximumRowID < current.lastRowID
        || requestedStart < current.coverageStart
    {
      state = nil
    }

    var resolved =
      state
      ?? Memo(
        identity: identity,
        coverageStart: requestedStart,
        lastRowID: maximumRowID,
        backfillUpperRowID: maximumRowID == 0 ? nil : maximumRowID,
        scannedRowsAreComplete: true,
        sourcesByRowID: [:]
      )
    resolved.coverageStart = max(resolved.coverageStart, requestedStart)
    resolved.sourcesByRowID = resolved.sourcesByRowID.filter {
      $0.value.timestamp >= requestedStart
    }

    if state != nil, !revalidateSources(in: database, state: &resolved) {
      return .unavailable
    }

    var allowance = ScanAllowance(remainingRows: scanPolicy.maximumRowsPerSnapshot)
    var stoppedEarly = false
    if maximumRowID > resolved.lastRowID {
      lastScanMetrics.usedIncrementalScan = resolved.lastRowID > 0
      let result = scanForward(
        database,
        throughRowID: maximumRowID,
        since: resolved.coverageStart,
        allowance: &allowance,
        state: &resolved
      )
      guard result != .failed else { return .unavailable }
      stoppedEarly = result != .finished
      record(result)
    }

    if !stoppedEarly, resolved.backfillUpperRowID != nil {
      let result = scanBackward(
        database,
        since: resolved.coverageStart,
        allowance: &allowance,
        state: &resolved
      )
      guard result != .failed else { return .unavailable }
      record(result)
    }

    lastScanMetrics.hasPendingBackfill = resolved.backfillUpperRowID != nil
    memo = resolved
    let end = Int64(interval.end.timeIntervalSince1970.rounded(.up))
    let turnIDs = Set(
      resolved.sourcesByRowID.values.lazy
        .filter { $0.timestamp >= requestedStart && $0.timestamp < end }
        .map(\.turnID)
    )
    return CodexPriorityTierSnapshot(
      priorityTurnIDs: turnIDs,
      isComplete: resolved.scannedRowsAreComplete && resolved.backfillUpperRowID == nil
        && resolved.lastRowID >= maximumRowID,
      supportsTurnCorrelation: true
    )
  }

  mutating func reset() {
    memo = nil
    lastScanMetrics = CodexPriorityTierScanMetrics()
  }

  private func fileIdentity() -> FileIdentity? {
    var value = stat()
    guard lstat(databaseURL.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
      return nil
    }
    return FileIdentity(device: value.st_dev, inode: value.st_ino)
  }

  private func maximumRowID(in database: OpaquePointer) -> Int64? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "SELECT max(rowid) FROM logs", -1, &statement, nil)
        == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_type(statement, 0) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, 0)
  }

  private func revalidateSources(in database: OpaquePointer, state: inout Memo) -> Bool {
    let rowIDs = Array(state.sourcesByRowID.keys)
    guard !rowIDs.isEmpty else { return true }

    var retained = Set<Int64>()
    for start in stride(from: 0, to: rowIDs.count, by: 400) {
      let succeeded: Bool = {
        let chunk = rowIDs[start..<min(start + 400, rowIDs.count)]
        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
        var statement: OpaquePointer?
        guard
          sqlite3_prepare_v2(
            database,
            "SELECT rowid FROM logs WHERE rowid IN (\(placeholders))",
            -1,
            &statement,
            nil
          ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        for (offset, rowID) in chunk.enumerated() {
          sqlite3_bind_int64(statement, Int32(offset + 1), rowID)
        }
        while true {
          let result = sqlite3_step(statement)
          if result == SQLITE_DONE { return true }
          guard result == SQLITE_ROW else { return false }
          retained.insert(sqlite3_column_int64(statement, 0))
        }
      }()
      if !succeeded { return false }
    }
    state.sourcesByRowID = state.sourcesByRowID.filter { retained.contains($0.key) }
    return true
  }

  private mutating func scanForward(
    _ database: OpaquePointer,
    throughRowID: Int64,
    since: Int64,
    allowance: inout ScanAllowance,
    state: inout Memo
  ) -> ScanResult {
    while state.lastRowID < throughRowID {
      let result = scanPage(
        database,
        direction: .forward(after: state.lastRowID, through: throughRowID),
        since: since,
        allowance: &allowance,
        state: &state
      )
      switch result {
      case .page(let rowCount, let boundaryRowID, let pageLimit):
        guard rowCount > 0, let boundaryRowID else {
          state.lastRowID = throughRowID
          return .finished
        }
        state.lastRowID = boundaryRowID
        if state.lastRowID >= throughRowID || rowCount < pageLimit {
          state.lastRowID = throughRowID
          return .finished
        }
      case .budgetExhausted:
        return .budgetExhausted
      case .cancelled:
        return .cancelled
      case .failed:
        return .failed
      }
    }
    return .finished
  }

  private mutating func scanBackward(
    _ database: OpaquePointer,
    since: Int64,
    allowance: inout ScanAllowance,
    state: inout Memo
  ) -> ScanResult {
    while let upperRowID = state.backfillUpperRowID {
      let result = scanPage(
        database,
        direction: .backward(through: upperRowID),
        since: since,
        allowance: &allowance,
        state: &state
      )
      switch result {
      case .page(let rowCount, let boundaryRowID, let pageLimit):
        guard rowCount > 0, let boundaryRowID else {
          state.backfillUpperRowID = nil
          return .finished
        }
        if rowCount < pageLimit || boundaryRowID == Int64.min {
          state.backfillUpperRowID = nil
          return .finished
        }
        state.backfillUpperRowID = boundaryRowID - 1
      case .budgetExhausted:
        return .budgetExhausted
      case .cancelled:
        return .cancelled
      case .failed:
        return .failed
      }
    }
    return .finished
  }

  private mutating func scanPage(
    _ database: OpaquePointer,
    direction: ScanDirection,
    since: Int64,
    allowance: inout ScanAllowance,
    state: inout Memo
  ) -> PageResult {
    guard allowance.remainingRows > 0 else { return .budgetExhausted }
    let limit = min(scanPolicy.batchSize, allowance.remainingRows)
    let query =
      switch direction {
      case .forward:
        """
        SELECT rowid, ts,
               CASE WHEN ts >= ? AND instr(feedback_log_body, 'websocket request:') > 0
                    THEN length(CAST(feedback_log_body AS BLOB)) END,
               CASE WHEN ts >= ? AND instr(feedback_log_body, 'websocket request:') > 0
                         AND length(CAST(feedback_log_body AS BLOB)) <= ?
                    THEN feedback_log_body END
        FROM logs
        WHERE rowid > ? AND rowid <= ?
        ORDER BY rowid ASC
        LIMIT ?
        """
      case .backward:
        """
        SELECT rowid, ts,
               CASE WHEN ts >= ? AND instr(feedback_log_body, 'websocket request:') > 0
                    THEN length(CAST(feedback_log_body AS BLOB)) END,
               CASE WHEN ts >= ? AND instr(feedback_log_body, 'websocket request:') > 0
                         AND length(CAST(feedback_log_body AS BLOB)) <= ?
                    THEN feedback_log_body END
        FROM logs
        WHERE rowid <= ?
        ORDER BY rowid DESC
        LIMIT ?
        """
      }

    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      return .failed
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, since)
    sqlite3_bind_int64(statement, 2, since)
    sqlite3_bind_int64(statement, 3, Int64(Self.maximumBodySize))
    switch direction {
    case .forward(let afterRowID, let throughRowID):
      sqlite3_bind_int64(statement, 4, afterRowID)
      sqlite3_bind_int64(statement, 5, throughRowID)
      sqlite3_bind_int(statement, 6, Int32(limit))
    case .backward(let throughRowID):
      sqlite3_bind_int64(statement, 4, throughRowID)
      sqlite3_bind_int(statement, 5, Int32(limit))
    }

    var rowCount = 0
    var boundaryRowID: Int64?
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE {
        return .page(rowCount: rowCount, boundaryRowID: boundaryRowID, pageLimit: limit)
      }
      guard result == SQLITE_ROW else { return .failed }
      guard shouldContinue() else { return .cancelled }
      guard allowance.remainingRows > 0 else { return .budgetExhausted }
      allowance.remainingRows -= 1
      rowCount += 1
      lastScanMetrics.scannedRowCount += 1

      let rowID = sqlite3_column_int64(statement, 0)
      boundaryRowID = rowID
      processRow(statement, rowID: rowID, since: since, state: &state)
    }
  }

  private mutating func processRow(
    _ statement: OpaquePointer,
    rowID: Int64,
    since: Int64,
    state: inout Memo
  ) {
    let timestamp = sqlite3_column_int64(statement, 1)
    guard timestamp >= since, sqlite3_column_type(statement, 2) != SQLITE_NULL else { return }
    let bodySize = sqlite3_column_int64(statement, 2)
    guard bodySize <= Self.maximumBodySize else {
      state.scannedRowsAreComplete = false
      lastScanMetrics.rejectedOversizedRowCount += 1
      return
    }
    guard let text = sqlite3_column_text(statement, 3) else {
      state.scannedRowsAreComplete = false
      return
    }
    let body = String(cString: text)
    guard body.utf8.count <= Self.maximumBodySize else {
      state.scannedRowsAreComplete = false
      lastScanMetrics.rejectedOversizedRowCount += 1
      return
    }

    switch Self.parse(body) {
    case .priority(let turnID):
      state.sourcesByRowID[rowID] = PrioritySource(turnID: turnID, timestamp: timestamp)
    case .notPriority:
      break
    case .malformed:
      state.scannedRowsAreComplete = false
    }
  }

  private mutating func record(_ result: ScanResult) {
    switch result {
    case .finished:
      break
    case .budgetExhausted:
      lastScanMetrics.exhaustedBudget = true
    case .cancelled:
      lastScanMetrics.wasCancelled = true
    case .failed:
      break
    }
  }

  private static func parse(_ body: String) -> ParseResult {
    let marker = "websocket request:"
    guard let markerRange = body.range(of: marker) else { return .notPriority }
    let prefix = body[..<markerRange.lowerBound]
    let json = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = json.data(using: .utf8),
      let request = try? JSONDecoder().decode(Request.self, from: data)
    else { return .malformed }
    guard request.type == "response.create" else { return .notPriority }
    guard request.serviceTier == "priority" else { return .notPriority }

    let turnID =
      value(named: "turn.id", in: prefix)
      ?? value(named: "turn_id", in: prefix)
      ?? request.turnID
    guard let turnID, !turnID.isEmpty else { return .malformed }
    return .priority(turnID)
  }

  private static func value(named name: String, in text: Substring) -> String? {
    guard let range = text.range(of: "\(name)=", options: .backwards) else { return nil }
    let value = text[range.upperBound...].prefix {
      !$0.isWhitespace && $0 != "," && $0 != "]" && $0 != ")" && $0 != ":" && $0 != "}"
    }
    return value.isEmpty ? nil : String(value)
  }
}

private struct FileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
}

private struct PrioritySource {
  let turnID: String
  let timestamp: Int64
}

private struct Memo {
  let identity: FileIdentity
  var coverageStart: Int64
  var lastRowID: Int64
  var backfillUpperRowID: Int64?
  var scannedRowsAreComplete: Bool
  var sourcesByRowID: [Int64: PrioritySource]
}

private struct ScanAllowance {
  var remainingRows: Int
}

private enum ScanDirection {
  case forward(after: Int64, through: Int64)
  case backward(through: Int64)
}

private enum PageResult {
  case page(rowCount: Int, boundaryRowID: Int64?, pageLimit: Int)
  case budgetExhausted
  case cancelled
  case failed
}

private enum ScanResult: Equatable {
  case finished
  case budgetExhausted
  case cancelled
  case failed
}

private enum ParseResult {
  case priority(String)
  case notPriority
  case malformed
}

private struct Request: Decodable {
  let type: String
  let serviceTier: String?
  let turnID: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case serviceTier = "service_tier"
    case turnID = "turn_id"
  }
}
