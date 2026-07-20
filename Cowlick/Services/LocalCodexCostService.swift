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
    "codex-jsonl-v2-openai-standard-2026-07-20"
  private static let readChunkSize = 64 * 1_024
  private static let probeSize = 4 * 1_024

  private let roots: [URL]
  private let now: @Sendable () -> Date
  private let parserPricingFingerprint: @Sendable () -> String
  private var cache: [InodeIdentity: CachedFile] = [:]
  private var metrics = LocalCodexCostScanMetrics()

  init(
    roots: [URL]? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
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
    self.parserPricingFingerprint = parserPricingFingerprint
  }

  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate {
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
      let result = try loadSummary(
        at: discovered.url,
        state: fileState,
        interval: interval,
        activeFingerprint: activeFingerprint,
        cached: cached,
        metrics: &scanMetrics
      )
      summaries.append(result.summary)
      if let updatedCache = result.cache {
        cache[fileState.inode] = updatedCache
        retainedCacheInodes.insert(fileState.inode)
      } else {
        cache.removeValue(forKey: fileState.inode)
      }
    }
    cache = cache.filter { retainedCacheInodes.contains($0.key) }

    let aggregation = try aggregate(summaries)
    return LocalCodexCostEstimate(
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
  }

  func resetCache() async {
    cache.removeAll(keepingCapacity: false)
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

      for (index, byte) in chunk.enumerated() {
        if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
        absoluteOffset += 1
        if byte == 0x0A {
          if discardingOversizedLine {
            state.summary.reasons.insert(.oversizedRecord)
            discardingOversizedLine = false
          } else if !buffer.isEmpty {
            parseLine(buffer, into: &state)
          }
          buffer.removeAll(keepingCapacity: true)
          stableOffset = absoluteOffset
        } else if !discardingOversizedLine {
          if buffer.count < Self.maximumLineSize {
            buffer.append(byte)
          } else {
            buffer.removeAll(keepingCapacity: true)
            discardingOversizedLine = true
          }
        }
      }
    }

    let stableState = state
    var finalState = stableState
    if discardingOversizedLine {
      finalState.summary.reasons.insert(.oversizedRecord)
    } else if !buffer.isEmpty {
      parseLine(buffer, into: &finalState, failureReason: .incompleteFinalRecord)
    }
    return ParsedScan(
      stableOffset: stableOffset,
      stableState: stableState,
      finalState: finalState
    )
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
    failureReason: LocalCodexCostExclusionReason = .malformedRecord
  ) {
    let record: LogRecord
    do {
      record = try JSONDecoder().decode(LogRecord.self, from: data)
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
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private func aggregate(_ summaries: [FileSummary]) throws -> Aggregation {
    var reasons = summaries.reduce(into: Set<LocalCodexCostExclusionReason>()) {
      $0.formUnion($1.reasons)
    }
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
          let key = ContributionKey(model: first.model, disposition: first.disposition)
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
        guard usage.hasValidInputPartition else {
          amount += prices.outputCost(for: usage, longContext: longContext)
          pricedTokens = pricedTokens.saturatedAdding(usage.outputTokens)
          unpricedTokens = unpricedTokens.saturatedAdding(usage.inputTokens)
          reasons.insert(.invalidTokenPartition)
          continue
        }

        amount += prices.cost(for: usage, longContext: longContext)
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
  let ordinaryInput: Decimal
  let cachedInput: Decimal
  let cacheWriteInput: Decimal
  let output: Decimal

  init?(model: String) {
    switch model {
    case "gpt-5.6-sol", "gpt-5.6":
      (ordinaryInput, cachedInput, cacheWriteInput, output) = (5, 0.5, 6.25, 30)
    case "gpt-5.6-terra":
      (ordinaryInput, cachedInput, cacheWriteInput, output) = (2.5, 0.25, 3.125, 15)
    case "gpt-5.6-luna":
      (ordinaryInput, cachedInput, cacheWriteInput, output) = (1, 0.1, 1.25, 6)
    default:
      return nil
    }
  }

  func cost(for usage: TokenUsage, longContext: Bool) -> Decimal {
    inputCost(for: usage, longContext: longContext)
      + outputCost(for: usage, longContext: longContext)
  }

  func outputCost(for usage: TokenUsage, longContext: Bool) -> Decimal {
    unitCost(tokens: usage.outputTokens, rate: output)
      * (longContext ? Decimal(string: "1.5")! : 1)
  }

  private func inputCost(for usage: TokenUsage, longContext: Bool) -> Decimal {
    let ordinary = usage.inputTokens - usage.cachedInputTokens - usage.cacheWriteInputTokens
    let base =
      unitCost(tokens: ordinary, rate: ordinaryInput)
      + unitCost(tokens: usage.cachedInputTokens, rate: cachedInput)
      + unitCost(tokens: usage.cacheWriteInputTokens, rate: cacheWriteInput)
    return base * (longContext ? 2 : 1)
  }

  private func unitCost(tokens: Int64, rate: Decimal) -> Decimal {
    Decimal(tokens) * rate / 1_000_000
  }
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
    let type: String?
    let info: TokenInfo?

    private enum CodingKeys: String, CodingKey {
      case id
      case forkedFromID = "forked_from_id"
      case parentThreadID = "parent_thread_id"
      case model
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
