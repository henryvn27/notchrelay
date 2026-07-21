import CryptoKit
import Darwin
import Foundation

enum LocalCodexCostServiceError: LocalizedError, Equatable {
  case invalidInterval

  var errorDescription: String? {
    switch self {
    case .invalidInterval: "The requested cost interval is invalid."
    }
  }
}

actor LocalCodexCostService: LocalCodexCostEstimating {
  static let maximumLineSize = 1_048_576
  static let pricingAsOf = Date(timeIntervalSince1970: 1_784_505_600)

  private static let defaultParserPricingFingerprint =
    "codex-jsonl-v3-openai-standard-priority-2026-07-20"
  private static let readChunkSize = 256 * 1_024
  private static let probeSize = 4 * 1_024

  private let roots: [URL]
  private let now: @Sendable () -> Date
  private let parserPricingFingerprint: @Sendable () -> String
  private var priorityTierReader: CodexPriorityTierReader?
  private var decoder = JSONDecoder()
  private var cache: [InodeIdentity: CachedFile] = [:]
  private var metrics = LocalCodexCostScanMetrics()

  init(
    roots: [URL]? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    priorityTierReader: CodexPriorityTierReader? = CodexPriorityTierReader(),
    parserPricingFingerprint: @escaping @Sendable () -> String = {
      LocalCodexCostService.defaultParserPricingFingerprint
    }
  ) {
    if let roots {
      self.roots = roots
    } else {
      let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
      self.roots = [
        codex.appendingPathComponent("sessions", isDirectory: true),
        codex.appendingPathComponent("archived_sessions", isDirectory: true),
      ]
    }
    self.now = now
    self.priorityTierReader = priorityTierReader
    self.parserPricingFingerprint = parserPricingFingerprint
  }

  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate {
    let estimate = try performEstimate(interval: interval)
    if metrics.bytesRead >= 16 * 1_024 * 1_024 {
      malloc_zone_pressure_relief(nil, 0)
    }
    return estimate
  }

  private func performEstimate(interval: DateInterval) throws -> LocalCodexCostEstimate {
    guard interval.start < interval.end else { throw LocalCodexCostServiceError.invalidInterval }

    var scanMetrics = LocalCodexCostScanMetrics()
    defer { metrics = scanMetrics }

    let activeFingerprint = parserPricingFingerprint()
    let discoveredFiles = try discoverFiles()
    var seenInodes = Set<InodeIdentity>()
    var retainedCacheInodes = Set<InodeIdentity>()
    var summaries: [FileSummary] = []

    for discovered in discoveredFiles {
      try Task.checkCancellation()
      let fileState = discovered.state
      guard seenInodes.insert(fileState.inode).inserted else { continue }

      if shouldSkipHistorical(fileState, for: interval) {
        scanMetrics.skippedHistoricalFileCount += 1
        continue
      }

      let cached = cache[fileState.inode]
      let result = try autoreleasepool {
        try loadSummary(
          at: discovered.url,
          state: fileState,
          interval: interval,
          activeFingerprint: activeFingerprint,
          cached: cached,
          metrics: &scanMetrics
        )
      }
      summaries.append(result.summary)
      if let updatedCache = result.cache {
        cache[fileState.inode] = updatedCache
        retainedCacheInodes.insert(fileState.inode)
      } else {
        cache.removeValue(forKey: fileState.inode)
      }
    }
    cache = cache.filter { retainedCacheInodes.contains($0.key) }

    let prioritySnapshot = priorityTierReader?.snapshot(for: interval) ?? .standardOnly
    let aggregation = try aggregate(summaries, prioritySnapshot: prioritySnapshot)
    let estimate = LocalCodexCostEstimate(
      measurement: CostMeasurement(
        kind: .apiEquivalentEstimate,
        amount: aggregation.amount,
        currency: "USD",
        interval: interval,
        coverage: aggregation.reasons.isEmpty ? .thisMac : .partial,
        pricingAsOf: Self.pricingAsOf
      ),
      pricedTokenCount: aggregation.pricedTokens.clampedToInt,
      unpricedTokenCount: aggregation.unpricedTokens.clampedToInt,
      excludedToolFees: true,
      exclusionReasons: aggregation.reasons.sorted { $0.rawValue < $1.rawValue },
      scannedFileCount: summaries.count,
      refreshedAt: now()
    )
    return estimate
  }

  func resetCache() async {
    cache.removeAll(keepingCapacity: false)
    priorityTierReader?.reset()
    metrics = LocalCodexCostScanMetrics()
  }

  func lastScanMetrics() -> LocalCodexCostScanMetrics {
    metrics
  }

  private func discoverFiles() throws -> [DiscoveredFile] {
    var files: [DiscoveredFile] = []
    for root in roots {
      try Task.checkCancellation()
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else { continue }

      var inspected = 0
      for case let url as URL in enumerator {
        inspected += 1
        if inspected.isMultiple(of: 32) { try Task.checkCancellation() }
        guard url.pathExtension == "jsonl", let state = fileState(at: url) else { continue }
        files.append(DiscoveredFile(url: url, state: state))
      }
    }
    return files.sorted { $0.url.path < $1.url.path }
  }

  private func fileState(at url: URL) -> FileState? {
    var value = stat()
    guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
    return FileState(
      inode: InodeIdentity(device: value.st_dev, inode: value.st_ino),
      size: value.st_size,
      modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
      changedSeconds: Int64(value.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
    )
  }

  private func shouldSkipHistorical(_ state: FileState, for interval: DateInterval) -> Bool {
    state.modifiedAt < interval.start
  }

  private func loadSummary(
    at url: URL,
    state: FileState,
    interval: DateInterval,
    activeFingerprint: String,
    cached: CachedFile?,
    metrics: inout LocalCodexCostScanMetrics
  ) throws -> LoadedSummary {
    if let cached, cached.parserPricingFingerprint == activeFingerprint,
      let stable = cached.stableState.adapted(to: interval),
      let final = cached.finalState.adapted(to: interval)
    {
      if state == cached.sourceState {
        metrics.reusedFileCount += 1
        var updated = cached
        updated.stableState = stable
        updated.finalState = final
        return LoadedSummary(summary: final.summary, cache: updated)
      }

      if state.size > cached.sourceState.size, cached.stableOffset > 0,
        let expectedProbe = cached.prefixProbe,
        try prefixProbe(at: url, through: cached.stableOffset, metrics: &metrics)
          == expectedProbe
      {
        metrics.incrementallyReadFileCount += 1
        let parsed = try parse(
          url,
          from: cached.stableOffset,
          initialState: stable,
          metrics: &metrics
        )
        return try finishLoad(
          parsed,
          url: url,
          initialState: state,
          parserPricingFingerprint: activeFingerprint,
          metrics: &metrics
        )
      }
    }

    if cached != nil { metrics.invalidatedFileCount += 1 }
    metrics.fullyReadFileCount += 1
    let parsed = try parse(
      url,
      from: 0,
      initialState: FileParserState(interval: interval),
      metrics: &metrics
    )
    return try finishLoad(
      parsed,
      url: url,
      initialState: state,
      parserPricingFingerprint: activeFingerprint,
      metrics: &metrics
    )
  }

  private func finishLoad(
    _ parsed: ParsedScan,
    url: URL,
    initialState: FileState,
    parserPricingFingerprint: String,
    metrics: inout LocalCodexCostScanMetrics
  ) throws -> LoadedSummary {
    try Task.checkCancellation()
    guard let currentState = fileState(at: url), currentState == initialState else {
      var summary = FileSummary()
      summary.reasons.insert(.fileChangedDuringScan)
      return LoadedSummary(summary: summary, cache: nil)
    }

    let probe = try prefixProbe(at: url, through: parsed.stableOffset, metrics: &metrics)
    guard fileState(at: url) == initialState else {
      var summary = FileSummary()
      summary.reasons.insert(.fileChangedDuringScan)
      return LoadedSummary(summary: summary, cache: nil)
    }

    let cached = CachedFile(
      sourceState: initialState,
      parserPricingFingerprint: parserPricingFingerprint,
      stableOffset: parsed.stableOffset,
      prefixProbe: probe,
      stableState: parsed.stableState,
      finalState: parsed.finalState
    )
    return LoadedSummary(summary: parsed.finalState.summary, cache: cached)
  }

  private func parse(
    _ url: URL,
    from offset: UInt64,
    initialState: FileParserState,
    metrics: inout LocalCodexCostScanMetrics
  ) throws -> ParsedScan {
    decoder = JSONDecoder()
    defer { decoder = JSONDecoder() }
    var state = initialState
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      state.summary.reasons.insert(.malformedRecord)
      return ParsedScan(stableOffset: offset, stableState: state, finalState: state)
    }
    defer { try? handle.close() }

    do {
      try handle.seek(toOffset: offset)
    } catch {
      state.summary.reasons.insert(.malformedRecord)
      return ParsedScan(stableOffset: offset, stableState: state, finalState: state)
    }

    var buffer = Data()
    var discardingOversizedLine = false
    var absoluteOffset = offset
    var stableOffset = offset

    while true {
      try Task.checkCancellation()
      let chunk: Data
      do {
        guard let next = try handle.read(upToCount: Self.readChunkSize), !next.isEmpty else {
          break
        }
        chunk = next
      } catch {
        state.summary.reasons.insert(.malformedRecord)
        break
      }
      metrics.bytesRead = metrics.bytesRead.saturatedAdding(chunk.count)

      try autoreleasepool {
        try consume(
          chunk,
          absoluteOffset: &absoluteOffset,
          stableOffset: &stableOffset,
          buffer: &buffer,
          discardingOversizedLine: &discardingOversizedLine,
          state: &state,
          metrics: &metrics
        )
      }
    }

    let stableState = state
    var finalState = stableState
    if discardingOversizedLine {
      finalState.summary.reasons.insert(.oversizedRecord)
    } else if !buffer.isEmpty {
      parseLine(
        buffer,
        into: &finalState,
        metrics: &metrics,
        failureReason: .incompleteFinalRecord
      )
    }
    return ParsedScan(
      stableOffset: stableOffset,
      stableState: stableState,
      finalState: finalState
    )
  }

  private func consume(
    _ chunk: Data,
    absoluteOffset: inout UInt64,
    stableOffset: inout UInt64,
    buffer: inout Data,
    discardingOversizedLine: inout Bool,
    state: inout FileParserState,
    metrics: inout LocalCodexCostScanMetrics
  ) throws {
    guard !chunk.isEmpty else { return }
    let chunkStartOffset = absoluteOffset

    try chunk.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      var segmentStart = 0

      while segmentStart < bytes.count {
        try Task.checkCancellation()
        let searchAddress = baseAddress.advanced(by: segmentStart)
        let remaining = bytes.count - segmentStart
        let found = memchr(searchAddress, Int32(0x0A), remaining)
        let segmentEnd =
          found.map {
            Int(bitPattern: $0) - Int(bitPattern: baseAddress)
          } ?? bytes.count
        let hasNewline = found != nil

        consumeSegment(
          bytes[segmentStart..<segmentEnd],
          terminatesRecord: hasNewline,
          buffer: &buffer,
          discardingOversizedLine: &discardingOversizedLine,
          state: &state,
          metrics: &metrics
        )

        if hasNewline {
          stableOffset = chunkStartOffset + UInt64(segmentEnd + 1)
          segmentStart = segmentEnd + 1
        } else {
          segmentStart = bytes.count
        }
      }
    }
    absoluteOffset = chunkStartOffset + UInt64(chunk.count)
  }

  private func consumeSegment(
    _ segment: Slice<UnsafeBufferPointer<UInt8>>,
    terminatesRecord: Bool,
    buffer: inout Data,
    discardingOversizedLine: inout Bool,
    state: inout FileParserState,
    metrics: inout LocalCodexCostScanMetrics
  ) {
    if !discardingOversizedLine, !segment.isEmpty {
      let available = Self.maximumLineSize - buffer.count
      if segment.count <= available {
        buffer.append(contentsOf: segment)
        metrics.recordBufferAppendCount += 1
        metrics.peakRetainedRecordBytes = max(metrics.peakRetainedRecordBytes, buffer.count)
      } else {
        buffer.removeAll(keepingCapacity: true)
        discardingOversizedLine = true
      }
    }

    guard terminatesRecord else { return }
    metrics.completeRecordCount += 1
    if discardingOversizedLine {
      state.summary.reasons.insert(.oversizedRecord)
      discardingOversizedLine = false
    } else if !buffer.isEmpty {
      parseLine(buffer, into: &state, metrics: &metrics)
    }
    buffer.removeAll(keepingCapacity: true)
  }

  private func prefixProbe(
    at url: URL,
    through stableOffset: UInt64,
    metrics: inout LocalCodexCostScanMetrics
  ) throws -> PrefixProbe? {
    guard stableOffset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let headCount = Int(min(UInt64(Self.probeSize), stableOffset))
    try handle.seek(toOffset: 0)
    let head = try handle.read(upToCount: headCount) ?? Data()
    metrics.bytesRead = metrics.bytesRead.saturatedAdding(head.count)

    let tailCount = Int(min(UInt64(Self.probeSize), stableOffset))
    try handle.seek(toOffset: stableOffset - UInt64(tailCount))
    let tail = try handle.read(upToCount: tailCount) ?? Data()
    metrics.bytesRead = metrics.bytesRead.saturatedAdding(tail.count)
    return PrefixProbe(
      stableOffset: stableOffset,
      headDigest: Data(SHA256.hash(data: head)),
      tailDigest: Data(SHA256.hash(data: tail))
    )
  }

  private func parseLine(
    _ data: Data,
    into state: inout FileParserState,
    metrics: inout LocalCodexCostScanMetrics,
    failureReason: LocalCodexCostExclusionReason = .malformedRecord
  ) {
    metrics.decodedRecordCount += 1
    metrics.decodedRecordBytes = metrics.decodedRecordBytes.saturatedAdding(data.count)
    let record: LogRecord
    do {
      record = try decoder.decode(LogRecord.self, from: data)
    } catch {
      state.summary.reasons.insert(failureReason)
      return
    }

    switch record.type {
    case "session_meta":
      guard let rolloutID = record.payload?.id, !rolloutID.isEmpty else {
        state.summary.reasons.insert(.missingRolloutIdentifier)
        return
      }
      if let existing = state.summary.rolloutID, existing != rolloutID {
        state.summary.reasons.insert(.unresolvedLineage)
      } else {
        state.summary.rolloutID = rolloutID
      }
      state.summary.parentRolloutID =
        record.payload?.forkedFromID ?? record.payload?.parentThreadID
    case "turn_context":
      state.currentModel = record.payload?.model
      if let turnID = record.payload?.turnID, !turnID.isEmpty { state.currentTurnID = turnID }
    case "event_msg" where record.payload?.type == "task_started":
      if let turnID = record.payload?.turnID, !turnID.isEmpty { state.currentTurnID = turnID }
    case "event_msg" where record.payload?.type == "token_count":
      guard let timestamp = parsedDate(record.timestamp), let info = record.payload?.info else {
        state.summary.reasons.insert(.malformedRecord)
        return
      }
      guard let total = info.totalTokenUsage else {
        state.summary.reasons.insert(.malformedRecord)
        return
      }
      consumeTokenEvent(
        timestamp: timestamp,
        model: state.currentModel,
        turnID: record.payload?.turnID ?? state.currentTurnID,
        total: total,
        last: info.lastTokenUsage,
        state: &state
      )
    default:
      break
    }
  }

  private func consumeTokenEvent(
    timestamp: Date,
    model: String?,
    turnID: String?,
    total: TokenUsage,
    last: TokenUsage?,
    state: inout FileParserState
  ) {
    state.summary.tokenEventCount += 1
    state.observe(timestamp)

    guard let previous = state.highWatermark else {
      if let last, last != total { state.summary.reasons.insert(.inconsistentTokenCounters) }
      state.summary.firstObservation = FirstObservation(
        usage: total,
        model: model,
        turnID: turnID,
        disposition: pricingDisposition(for: total, last: last, reasons: &state.summary.reasons),
        includedInInterval: state.includes(timestamp)
      )
      state.highWatermark = total
      state.summary.highWatermark = total
      return
    }

    guard let contribution = total.delta(from: previous) else {
      state.summary.reasons.insert(.counterDiscontinuity)
      state.highWatermark = previous.componentwiseMaximum(total)
      state.summary.highWatermark = state.highWatermark
      return
    }

    if !contribution.isZero, let last, last != contribution {
      state.summary.reasons.insert(.inconsistentTokenCounters)
    }
    state.highWatermark = total
    state.summary.highWatermark = total
    guard !contribution.isZero, state.includes(timestamp) else { return }

    let key = ContributionKey(
      model: model,
      turnID: turnID,
      disposition: pricingDisposition(
        for: contribution,
        last: last,
        reasons: &state.summary.reasons
      )
    )
    state.summary.contributions[key, default: .zero].formSaturatedAddition(contribution)
  }

  private func pricingDisposition(
    for contribution: TokenUsage,
    last: TokenUsage?,
    reasons: inout Set<LocalCodexCostExclusionReason>
  ) -> PricingDisposition {
    guard contribution.inputTokens > 272_000 else { return .ordinary }
    guard last == contribution else {
      reasons.insert(.ambiguousLongContextPricing)
      return .ambiguousLongContext
    }
    return .longContext
  }

  private func parsedDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    var result: Date?
    let usedContiguousStorage =
      value.utf8.withContiguousStorageIfAvailable { bytes in
        result = parsedDate(bytes)
        return true
      } ?? false
    if usedContiguousStorage { return result }
    return parsedDate(Array(value.utf8))
  }

  private func parsedDate<C: RandomAccessCollection>(_ bytes: C) -> Date?
  where C.Element == UInt8, C.Index == Int {
    guard bytes.count >= 20 else { return nil }

    func digit(_ index: Int) -> Int? {
      let value = bytes[index]
      guard value >= 0x30, value <= 0x39 else { return nil }
      return Int(value - 0x30)
    }

    func twoDigits(_ index: Int) -> Int? {
      guard let first = digit(index), let second = digit(index + 1) else { return nil }
      return first * 10 + second
    }

    guard
      bytes[4] == 0x2D,
      bytes[7] == 0x2D,
      bytes[10] == 0x54,
      bytes[13] == 0x3A,
      bytes[16] == 0x3A,
      let yearThousands = digit(0),
      let yearHundreds = digit(1),
      let yearTens = digit(2),
      let yearOnes = digit(3),
      let month = twoDigits(5),
      let day = twoDigits(8),
      let hour = twoDigits(11),
      let minute = twoDigits(14),
      let second = twoDigits(17)
    else { return nil }

    let year = yearThousands * 1_000 + yearHundreds * 100 + yearTens * 10 + yearOnes
    guard
      (1...12).contains(month),
      (0...23).contains(hour),
      (0...59).contains(minute),
      (0...59).contains(second),
      (1...daysInMonth(month, year: year)).contains(day)
    else { return nil }

    var index = 19
    var fractionalSeconds = 0.0
    if index < bytes.count, bytes[index] == 0x2E {
      index += 1
      let fractionStart = index
      var place = 0.1
      while index < bytes.count, let value = digit(index) {
        if place >= 0.000_000_001 {
          fractionalSeconds += Double(value) * place
          place *= 0.1
        }
        index += 1
      }
      guard index > fractionStart else { return nil }
    }

    guard index < bytes.count else { return nil }

    let timeZoneOffset: Int
    if bytes[index] == 0x5A {
      index += 1
      timeZoneOffset = 0
    } else {
      let suffixLength = bytes.count - index
      guard suffixLength == 3 || suffixLength == 5 || suffixLength == 6 else { return nil }
      guard bytes[index] == 0x2B || bytes[index] == 0x2D,
        let offsetHour = twoDigits(index + 1), (0...23).contains(offsetHour)
      else { return nil }
      let offsetMinute: Int
      switch suffixLength {
      case 3:
        offsetMinute = 0
      case 5:
        guard let minute = twoDigits(index + 3) else { return nil }
        offsetMinute = minute
      case 6:
        guard bytes[index + 3] == 0x3A, let minute = twoDigits(index + 4) else { return nil }
        offsetMinute = minute
      default:
        return nil
      }
      guard (0...59).contains(offsetMinute) else { return nil }
      let magnitude = offsetHour * 3_600 + offsetMinute * 60
      timeZoneOffset = bytes[index] == 0x2B ? magnitude : -magnitude
      index = bytes.count
    }
    guard index == bytes.count else { return nil }

    let wholeSeconds =
      daysSinceUnixEpoch(year: year, month: month, day: day) * 86_400
      + Int64(hour * 3_600 + minute * 60 + second - timeZoneOffset)
    return Date(timeIntervalSince1970: Double(wholeSeconds) + fractionalSeconds)
  }

  private func daysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let leapYear =
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
      return leapYear ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }

  private func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int64 {
    let adjustedYear = year - (month <= 2 ? 1 : 0)
    let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
    let yearOfEra = adjustedYear - era * 400
    let adjustedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return Int64(era * 146_097 + dayOfEra - 719_468)
  }

  private func aggregate(
    _ summaries: [FileSummary],
    prioritySnapshot: CodexPriorityTierSnapshot
  ) throws -> Aggregation {
    var reasons = summaries.reduce(into: Set<LocalCodexCostExclusionReason>()) {
      $0.formUnion($1.reasons)
    }
    if !prioritySnapshot.isComplete { reasons.insert(.priorityMetadataUnavailable) }
    var filesByRollout: [String: FileSummary] = [:]

    for (index, file) in summaries.enumerated() {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      guard let rolloutID = file.rolloutID else {
        reasons.insert(.missingRolloutIdentifier)
        continue
      }
      if let existing = filesByRollout[rolloutID] {
        reasons.insert(.duplicateRollout)
        if file.tokenEventCount > existing.tokenEventCount { filesByRollout[rolloutID] = file }
      } else {
        filesByRollout[rolloutID] = file
      }
    }

    var resolved: [String: LineageResult] = [:]
    var visiting = Set<String>()

    func resolve(_ rolloutID: String) throws -> LineageResult {
      try Task.checkCancellation()
      if let existing = resolved[rolloutID] { return existing }
      guard let file = filesByRollout[rolloutID] else { return .unresolved }
      guard visiting.insert(rolloutID).inserted else {
        reasons.insert(.unresolvedLineage)
        return .unresolved
      }
      defer { visiting.remove(rolloutID) }

      var contributions = file.contributions
      let lineageResolved: Bool
      if let parentID = file.parentRolloutID, !parentID.isEmpty {
        reasons.insert(.forkLineageUncertainty)
        guard let first = file.firstObservation, filesByRollout[parentID] != nil else {
          reasons.insert(.unresolvedLineage)
          let result = LineageResult(
            highWatermark: file.highWatermark,
            contributions: [:],
            lineageResolved: false
          )
          resolved[rolloutID] = result
          return result
        }
        let parent = try resolve(parentID)
        lineageResolved = parent.lineageResolved && parent.highWatermark == first.usage
        if !lineageResolved {
          reasons.insert(.unresolvedLineage)
          contributions.removeAll(keepingCapacity: false)
        }
      } else {
        lineageResolved = true
        if let first = file.firstObservation, first.includedInInterval, !first.usage.isZero {
          let key = ContributionKey(
            model: first.model,
            turnID: first.turnID,
            disposition: first.disposition
          )
          contributions[key, default: .zero].formSaturatedAddition(first.usage)
        }
      }

      let result = LineageResult(
        highWatermark: file.highWatermark,
        contributions: contributions,
        lineageResolved: lineageResolved
      )
      resolved[rolloutID] = result
      return result
    }

    var amount = Decimal.zero
    var pricedTokens: Int64 = 0
    var unpricedTokens: Int64 = 0

    for rolloutID in filesByRollout.keys.sorted() {
      try Task.checkCancellation()
      for (key, usage) in try resolve(rolloutID).contributions {
        let billableTokens = usage.billableTokens
        guard key.disposition != .ambiguousLongContext else {
          unpricedTokens = unpricedTokens.saturatedAdding(billableTokens)
          reasons.insert(.ambiguousLongContextPricing)
          continue
        }
        guard let model = key.model, let prices = Prices(model: model) else {
          unpricedTokens = unpricedTokens.saturatedAdding(billableTokens)
          reasons.insert(.unknownModel)
          continue
        }

        let longContext = key.disposition == .longContext
        let priority: Bool
        if let turnID = key.turnID {
          priority = prioritySnapshot.priorityTurnIDs.contains(turnID)
        } else if prioritySnapshot.supportsTurnCorrelation {
          priority = false
          reasons.insert(.missingTurnIdentifier)
        } else {
          priority = false
        }
        if priority, longContext { reasons.insert(.ambiguousPriorityPricing) }
        guard usage.hasValidInputPartition else {
          amount += prices.outputCost(
            for: usage,
            longContext: longContext,
            priority: priority && !longContext
          )
          pricedTokens = pricedTokens.saturatedAdding(usage.outputTokens)
          unpricedTokens = unpricedTokens.saturatedAdding(usage.inputTokens)
          reasons.insert(.invalidTokenPartition)
          continue
        }

        amount += prices.cost(
          for: usage,
          longContext: longContext,
          priority: priority && !longContext
        )
        pricedTokens = pricedTokens.saturatedAdding(billableTokens)
      }
    }

    return Aggregation(
      amount: amount,
      pricedTokens: pricedTokens,
      unpricedTokens: unpricedTokens,
      reasons: reasons
    )
  }
}

private struct DiscoveredFile {
  let url: URL
  let state: FileState
}

private struct InodeIdentity: Hashable {
  let device: dev_t
  let inode: ino_t
}

private struct FileState: Equatable {
  let inode: InodeIdentity
  let size: off_t
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64

  var modifiedAt: Date {
    Date(
      timeIntervalSince1970: TimeInterval(modifiedSeconds)
        + TimeInterval(modifiedNanoseconds) / 1_000_000_000
    )
  }
}

private struct PrefixProbe: Equatable {
  let stableOffset: UInt64
  let headDigest: Data
  let tailDigest: Data
}

private struct CachedFile {
  let sourceState: FileState
  let parserPricingFingerprint: String
  let stableOffset: UInt64
  let prefixProbe: PrefixProbe?
  var stableState: FileParserState
  var finalState: FileParserState
}

private struct LoadedSummary {
  let summary: FileSummary
  let cache: CachedFile?
}

private struct ParsedScan {
  let stableOffset: UInt64
  let stableState: FileParserState
  let finalState: FileParserState
}

private struct FileParserState {
  var interval: DateInterval
  var currentModel: String?
  var currentTurnID: String?
  var highWatermark: TokenUsage?
  var earliestExcludedAfterEnd: Date?
  var latestIncluded: Date?
  var summary = FileSummary()

  func includes(_ timestamp: Date) -> Bool {
    timestamp >= interval.start && timestamp < interval.end
  }

  mutating func observe(_ timestamp: Date) {
    if includes(timestamp) {
      latestIncluded = max(latestIncluded ?? timestamp, timestamp)
    } else if timestamp >= interval.end {
      earliestExcludedAfterEnd = min(earliestExcludedAfterEnd ?? timestamp, timestamp)
    }
  }

  func adapted(to newInterval: DateInterval) -> FileParserState? {
    guard interval.start == newInterval.start else { return nil }
    if newInterval.end > interval.end,
      let earliestExcludedAfterEnd,
      earliestExcludedAfterEnd < newInterval.end
    {
      return nil
    }
    if newInterval.end < interval.end, let latestIncluded, latestIncluded >= newInterval.end {
      return nil
    }
    var adapted = self
    adapted.interval = newInterval
    return adapted
  }
}

private struct FileSummary {
  var rolloutID: String?
  var parentRolloutID: String?
  var firstObservation: FirstObservation?
  var highWatermark: TokenUsage?
  var contributions: [ContributionKey: TokenUsage] = [:]
  var tokenEventCount = 0
  var reasons: Set<LocalCodexCostExclusionReason> = []
}

private struct FirstObservation {
  let usage: TokenUsage
  let model: String?
  let turnID: String?
  let disposition: PricingDisposition
  let includedInInterval: Bool
}

private enum PricingDisposition: Hashable {
  case ordinary
  case longContext
  case ambiguousLongContext
}

private struct ContributionKey: Hashable {
  let model: String?
  let turnID: String?
  let disposition: PricingDisposition
}

private struct LineageResult {
  let highWatermark: TokenUsage?
  let contributions: [ContributionKey: TokenUsage]
  let lineageResolved: Bool

  static let unresolved = LineageResult(
    highWatermark: nil,
    contributions: [:],
    lineageResolved: false
  )
}

private struct Aggregation {
  let amount: Decimal
  let pricedTokens: Int64
  let unpricedTokens: Int64
  let reasons: Set<LocalCodexCostExclusionReason>
}

private struct Prices {
  let standard: Rates
  let priority: Rates

  init?(model: String) {
    switch Self.normalizedModel(model) {
    case "gpt-5.6-sol":
      standard = Rates(ordinaryInput: 5, cachedInput: 0.5, cacheWriteInput: 6.25, output: 30)
      priority = Rates(ordinaryInput: 10, cachedInput: 1, cacheWriteInput: 12.5, output: 60)
    case "gpt-5.6-terra":
      standard = Rates(ordinaryInput: 2.5, cachedInput: 0.25, cacheWriteInput: 3.125, output: 15)
      priority = Rates(ordinaryInput: 5, cachedInput: 0.5, cacheWriteInput: 6.25, output: 30)
    case "gpt-5.6-luna":
      standard = Rates(ordinaryInput: 1, cachedInput: 0.1, cacheWriteInput: 1.25, output: 6)
      priority = Rates(ordinaryInput: 2, cachedInput: 0.2, cacheWriteInput: 2.5, output: 12)
    default:
      return nil
    }
  }

  private static func normalizedModel(_ raw: String) -> String {
    var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
    if let canonical = canonicalModel(model) { return canonical }

    guard model.count > 11 else { return model }
    let suffix = String(model.suffix(11))
    guard validDateSuffix(suffix) else { return model }
    return canonicalModel(String(model.dropLast(11))) ?? model
  }

  private static func canonicalModel(_ model: String) -> String? {
    switch model {
    case "gpt-5.6": "gpt-5.6-sol"
    case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": model
    default: nil
    }
  }

  private static func validDateSuffix(_ suffix: String) -> Bool {
    let bytes = Array(suffix.utf8)
    guard
      bytes.count == 11,
      bytes[0] == 0x2D,
      bytes[5] == 0x2D,
      bytes[8] == 0x2D,
      bytes.enumerated().allSatisfy({ index, byte in
        [0, 5, 8].contains(index) || (0x30...0x39).contains(byte)
      }),
      let year = Int(String(suffix.dropFirst().prefix(4))),
      let month = Int(String(suffix.dropFirst(6).prefix(2))),
      let day = Int(String(suffix.suffix(2)))
    else { return false }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard
      let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
    else { return false }
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return components.year == year && components.month == month && components.day == day
  }

  func cost(for usage: TokenUsage, longContext: Bool, priority: Bool) -> Decimal {
    let rates = priority ? self.priority : standard
    return inputCost(for: usage, rates: rates, longContext: longContext)
      + outputCost(for: usage, rates: rates, longContext: longContext)
  }

  func outputCost(for usage: TokenUsage, longContext: Bool, priority: Bool) -> Decimal {
    outputCost(for: usage, rates: priority ? self.priority : standard, longContext: longContext)
  }

  private func outputCost(for usage: TokenUsage, rates: Rates, longContext: Bool) -> Decimal {
    unitCost(tokens: usage.outputTokens, rate: rates.output)
      * (longContext ? Decimal(string: "1.5")! : 1)
  }

  private func inputCost(for usage: TokenUsage, rates: Rates, longContext: Bool) -> Decimal {
    let ordinary = usage.inputTokens - usage.cachedInputTokens - usage.cacheWriteInputTokens
    let base =
      unitCost(tokens: ordinary, rate: rates.ordinaryInput)
      + unitCost(tokens: usage.cachedInputTokens, rate: rates.cachedInput)
      + unitCost(tokens: usage.cacheWriteInputTokens, rate: rates.cacheWriteInput)
    return base * (longContext ? 2 : 1)
  }

  private func unitCost(tokens: Int64, rate: Decimal) -> Decimal {
    Decimal(tokens) * rate / 1_000_000
  }
}

private struct Rates {
  let ordinaryInput: Decimal
  let cachedInput: Decimal
  let cacheWriteInput: Decimal
  let output: Decimal
}

private struct TokenUsage: Decodable, Equatable {
  let inputTokens: Int64
  let cachedInputTokens: Int64
  let cacheWriteInputTokens: Int64
  let outputTokens: Int64

  static let zero = TokenUsage(
    inputTokens: 0,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: 0
  )

  var billableTokens: Int64 { inputTokens.saturatedAdding(outputTokens) }
  var isZero: Bool {
    inputTokens == 0 && cachedInputTokens == 0 && cacheWriteInputTokens == 0 && outputTokens == 0
  }
  var hasValidInputPartition: Bool {
    cachedInputTokens.saturatedAdding(cacheWriteInputTokens) <= inputTokens
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
    cachedInputTokens =
      try container.decodeIfPresent(Int64.self, forKey: .cachedInputTokens) ?? 0
    cacheWriteInputTokens =
      try container.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
    guard
      inputTokens >= 0, cachedInputTokens >= 0, cacheWriteInputTokens >= 0, outputTokens >= 0
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Negative token count")
      )
    }
  }

  private init(
    inputTokens: Int64,
    cachedInputTokens: Int64,
    cacheWriteInputTokens: Int64,
    outputTokens: Int64
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.cacheWriteInputTokens = cacheWriteInputTokens
    self.outputTokens = outputTokens
  }

  mutating func formSaturatedAddition(_ other: TokenUsage) {
    self = TokenUsage(
      inputTokens: inputTokens.saturatedAdding(other.inputTokens),
      cachedInputTokens: cachedInputTokens.saturatedAdding(other.cachedInputTokens),
      cacheWriteInputTokens: cacheWriteInputTokens.saturatedAdding(other.cacheWriteInputTokens),
      outputTokens: outputTokens.saturatedAdding(other.outputTokens)
    )
  }

  func delta(from previous: TokenUsage) -> TokenUsage? {
    guard
      inputTokens >= previous.inputTokens,
      cachedInputTokens >= previous.cachedInputTokens,
      cacheWriteInputTokens >= previous.cacheWriteInputTokens,
      outputTokens >= previous.outputTokens
    else { return nil }
    return TokenUsage(
      inputTokens: inputTokens - previous.inputTokens,
      cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
      cacheWriteInputTokens: cacheWriteInputTokens - previous.cacheWriteInputTokens,
      outputTokens: outputTokens - previous.outputTokens
    )
  }

  func componentwiseMaximum(_ other: TokenUsage) -> TokenUsage {
    TokenUsage(
      inputTokens: max(inputTokens, other.inputTokens),
      cachedInputTokens: max(cachedInputTokens, other.cachedInputTokens),
      cacheWriteInputTokens: max(cacheWriteInputTokens, other.cacheWriteInputTokens),
      outputTokens: max(outputTokens, other.outputTokens)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case cacheWriteInputTokens = "cache_write_input_tokens"
    case outputTokens = "output_tokens"
  }
}

private struct LogRecord: Decodable {
  let type: String
  let timestamp: String?
  let payload: Payload?

  struct Payload: Decodable {
    let id: String?
    let forkedFromID: String?
    let parentThreadID: String?
    let model: String?
    let turnID: String?
    let type: String?
    let info: TokenInfo?

    private enum CodingKeys: String, CodingKey {
      case id
      case forkedFromID = "forked_from_id"
      case parentThreadID = "parent_thread_id"
      case model
      case turnID = "turn_id"
      case type
      case info
    }
  }

  struct TokenInfo: Decodable {
    let totalTokenUsage: TokenUsage?
    let lastTokenUsage: TokenUsage?

    private enum CodingKeys: String, CodingKey {
      case totalTokenUsage = "total_token_usage"
      case lastTokenUsage = "last_token_usage"
    }
  }
}

extension Int {
  fileprivate func saturatedAdding(_ other: Int) -> Int {
    let (result, overflow) = addingReportingOverflow(other)
    return overflow ? Int.max : result
  }
}

extension Int64 {
  fileprivate func saturatedAdding(_ other: Int64) -> Int64 {
    let (result, overflow) = addingReportingOverflow(other)
    return overflow ? Int64.max : result
  }

  fileprivate var clampedToInt: Int {
    self > Int64(Int.max) ? Int.max : Int(self)
  }
}
