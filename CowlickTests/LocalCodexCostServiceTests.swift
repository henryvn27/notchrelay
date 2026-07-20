import Foundation
import XCTest

@testable import Cowlick

final class LocalCodexCostServiceTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var sessions: URL!
  private var archived: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-local-cost-tests-\(UUID().uuidString)", isDirectory: true)
    sessions = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
    archived = temporaryDirectory.appendingPathComponent("archived", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
  }

  func testPricesOnlyExactSupportedModelsAndDocumentedAlias() async throws {
    try writeRollout(id: "sol", model: "gpt-5.6-sol", input: 100_000)
    try writeRollout(id: "alias", model: "gpt-5.6", input: 100_000)
    try writeRollout(id: "terra", model: "gpt-5.6-terra", input: 100_000)
    try writeRollout(id: "luna", model: "gpt-5.6-luna", input: 100_000)
    try writeRollout(id: "unknown", model: "gpt-5.6-solitude", input: 100_000)

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "1.35"))
    XCTAssertEqual(estimate.pricedTokenCount, 400_000)
    XCTAssertEqual(estimate.unpricedTokenCount, 100_000)
    XCTAssertEqual(estimate.measurement.coverage, .partial)
    XCTAssertTrue(estimate.exclusionReasons.contains(.unknownModel))
    XCTAssertEqual(estimate.measurement.pricingAsOf, LocalCodexCostService.pricingAsOf)
    XCTAssertTrue(estimate.excludedToolFees)
  }

  func testPartitionsCachedAndCacheWriteInputWithoutDoubleCounting() async throws {
    try writeRollout(
      id: "partitioned",
      model: "gpt-5.6-sol",
      input: 100_000,
      cached: 20_000,
      cacheWrite: 10_000,
      output: 10_000
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "0.7225"))
    XCTAssertEqual(estimate.pricedTokenCount, 110_000)
    XCTAssertEqual(estimate.unpricedTokenCount, 0)
  }

  func testReasoningTokensAreAlreadyPartOfOutput() async throws {
    try write(
      lines: [
        metadata(id: "reasoning"),
        context(model: "gpt-5.6-sol"),
        token(
          total: usage(input: 0, output: 100, reasoning: 90),
          last: usage(input: 0, output: 100, reasoning: 90)
        ),
      ],
      to: sessions.appendingPathComponent("reasoning.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "0.003"))
    XCTAssertEqual(estimate.pricedTokenCount, 100)
  }

  func testLongContextMultiplierStartsAbove272000InputTokens() async throws {
    try writeRollout(id: "threshold", model: "gpt-5.6-sol", input: 272_000, output: 100_000)
    try writeRollout(id: "long", model: "gpt-5.6-sol", input: 272_001, output: 100_000)

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "11.58001"))
  }

  func testLongContextMultiplierIsNotGuessedFromDisagreeingCumulativeTotals() async throws {
    try write(
      lines: [
        metadata(id: "ambiguous-long-context"),
        context(model: "gpt-5.6-sol"),
        token(
          total: usage(input: 300_000, output: 100_000),
          last: usage(input: 100_000, output: 50_000)
        ),
      ],
      to: sessions.appendingPathComponent("ambiguous-long-context.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, 0)
    XCTAssertEqual(estimate.pricedTokenCount, 0)
    XCTAssertEqual(estimate.unpricedTokenCount, 400_000)
    XCTAssertTrue(estimate.exclusionReasons.contains(.inconsistentTokenCounters))
    XCTAssertTrue(estimate.exclusionReasons.contains(.ambiguousLongContextPricing))
  }

  func testLongContextWithoutLastUsageIsExcludedRatherThanOrdinaryPriced() async throws {
    try write(
      lines: [
        metadata(id: "missing-last-long-context"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 300_000, output: 10_000), last: nil),
      ],
      to: sessions.appendingPathComponent("missing-last-long-context.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, 0)
    XCTAssertEqual(estimate.pricedTokenCount, 0)
    XCTAssertEqual(estimate.unpricedTokenCount, 310_000)
    XCTAssertTrue(estimate.exclusionReasons.contains(.ambiguousLongContextPricing))
  }

  func testRepeatedCumulativeTotalsAreNotCountedTwice() async throws {
    let total = usage(input: 100, output: 10)
    try write(
      lines: [
        metadata(id: "repeated"),
        context(model: "gpt-5.6-sol"),
        token(total: total, last: total),
        token(total: total, last: total),
      ],
      to: sessions.appendingPathComponent("repeated.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 110)
    XCTAssertFalse(estimate.exclusionReasons.contains(.counterDiscontinuity))
  }

  func testLastAndTotalDisagreementUsesCumulativeDeltaOnceAndMarksPartial() async throws {
    try write(
      lines: [
        metadata(id: "disagreement"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
        token(total: usage(input: 150), last: usage(input: 20)),
      ],
      to: sessions.appendingPathComponent("disagreement.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 150)
    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "0.00075"))
    XCTAssertTrue(estimate.exclusionReasons.contains(.inconsistentTokenCounters))
    XCTAssertEqual(estimate.measurement.coverage, .partial)
  }

  func testCounterDropUsesHighWatermarkContainment() async throws {
    try write(
      lines: [
        metadata(id: "drop"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
        token(total: usage(input: 50), last: usage(input: 10)),
        token(total: usage(input: 120), last: usage(input: 70)),
      ],
      to: sessions.appendingPathComponent("drop.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 120)
    XCTAssertTrue(estimate.exclusionReasons.contains(.counterDiscontinuity))
  }

  func testForkCopiedPrefixUsesParentHighWatermark() async throws {
    try write(
      lines: [
        metadata(id: "parent", sessionID: "shared-session"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
      ],
      to: sessions.appendingPathComponent("parent.jsonl")
    )
    try write(
      lines: [
        metadata(
          id: "child",
          sessionID: "shared-session",
          parent: "ignored-parent-thread",
          forkedFrom: "parent"
        ),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
        token(total: usage(input: 150), last: usage(input: 50)),
      ],
      to: sessions.appendingPathComponent("child.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 150)
    XCTAssertFalse(estimate.exclusionReasons.contains(.unresolvedLineage))
    XCTAssertTrue(estimate.exclusionReasons.contains(.forkLineageUncertainty))
    XCTAssertEqual(estimate.measurement.coverage, .partial)
  }

  func testUnresolvedForkIsExcludedRatherThanInflated() async throws {
    try write(
      lines: [
        metadata(id: "orphan", parent: "missing-parent"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 500), last: usage(input: 50)),
        token(total: usage(input: 600), last: usage(input: 100)),
      ],
      to: sessions.appendingPathComponent("orphan.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 0)
    XCTAssertEqual(estimate.measurement.amount, 0)
    XCTAssertTrue(estimate.exclusionReasons.contains(.unresolvedLineage))
  }

  func testSharedSessionIDDoesNotMergeDistinctLeafRollouts() async throws {
    try writeRollout(id: "leaf-a", sessionID: "same", model: "gpt-5.6-sol", input: 100)
    try writeRollout(id: "leaf-b", sessionID: "same", model: "gpt-5.6-sol", input: 100)

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 200)
  }

  func testActiveAndArchivedHardLinksAreScannedOnce() async throws {
    let active = sessions.appendingPathComponent("linked.jsonl")
    try write(
      lines: [
        metadata(id: "linked"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
      ],
      to: active
    )
    try FileManager.default.linkItem(
      at: active, to: archived.appendingPathComponent("linked.jsonl"))

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.scannedFileCount, 1)
    XCTAssertEqual(estimate.pricedTokenCount, 100)
  }

  func testMalformedOversizedAndPartialFinalLinesAreBoundedAndReported() async throws {
    let url = sessions.appendingPathComponent("bounded.jsonl")
    var data = Data(
      ([
        metadata(id: "bounded"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
        "not-json",
      ].joined(separator: "\n") + "\n").utf8
    )
    data.append(Data(repeating: 0x78, count: LocalCodexCostService.maximumLineSize + 1))
    data.append(0x0A)
    data.append(Data(#"{"type":"event_msg""#.utf8))
    try data.write(to: url, options: .atomic)

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 100)
    XCTAssertTrue(estimate.exclusionReasons.contains(.malformedRecord))
    XCTAssertTrue(estimate.exclusionReasons.contains(.oversizedRecord))
    XCTAssertTrue(estimate.exclusionReasons.contains(.incompleteFinalRecord))
  }

  func testCompleteFinalJSONRecordDoesNotRequireTrailingNewline() async throws {
    let lines = [
      metadata(id: "no-newline"),
      context(model: "gpt-5.6-sol"),
      token(total: usage(input: 100), last: usage(input: 100)),
    ]
    try Data(lines.joined(separator: "\n").utf8).write(
      to: sessions.appendingPathComponent("no-newline.jsonl"), options: .atomic)

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.pricedTokenCount, 100)
    XCTAssertFalse(estimate.exclusionReasons.contains(.incompleteFinalRecord))
  }

  func testPartialFinalRecordIsReparsedExactlyOnceAfterAppendCompletesIt() async throws {
    let url = sessions.appendingPathComponent("partial-append.jsonl")
    let completeToken = token(total: usage(input: 100), last: usage(input: 100))
    let split = completeToken.index(completeToken.startIndex, offsetBy: completeToken.count / 2)
    let prefix =
      [metadata(id: "partial-append"), context(model: "gpt-5.6-sol")]
      .joined(separator: "\n") + "\n" + completeToken[..<split]
    try Data(prefix.utf8).write(to: url)
    let service = makeService()

    let incomplete = try await service.estimate(interval: interval)
    XCTAssertEqual(incomplete.pricedTokenCount, 0)
    XCTAssertTrue(incomplete.exclusionReasons.contains(.incompleteFinalRecord))

    try append(String(completeToken[split...]) + "\n", to: url)
    let completed = try await service.estimate(interval: interval)
    let scanMetrics = await service.lastScanMetrics()

    XCTAssertEqual(completed.pricedTokenCount, 100)
    XCTAssertFalse(completed.exclusionReasons.contains(.incompleteFinalRecord))
    XCTAssertEqual(scanMetrics.incrementallyReadFileCount, 1)
  }

  func testUnchangedAndAppendOnlyScansReadBoundedBytes() async throws {
    let url = sessions.appendingPathComponent("incremental.jsonl")
    var lines = [
      metadata(id: "incremental"),
      context(model: "gpt-5.6-sol"),
      token(total: usage(input: 100), last: usage(input: 100)),
    ]
    lines.append(contentsOf: (0..<4_000).map(paddingLine))
    try write(lines: lines, to: url)
    let service = makeService()

    let initial = try await service.estimate(interval: interval)
    let initialMetrics = await service.lastScanMetrics()
    XCTAssertEqual(initial.pricedTokenCount, 100)
    XCTAssertEqual(initialMetrics.fullyReadFileCount, 1)
    XCTAssertGreaterThan(initialMetrics.bytesRead, 100_000)

    let unchanged = try await service.estimate(interval: interval)
    let unchangedMetrics = await service.lastScanMetrics()
    XCTAssertEqual(unchanged, initial)
    XCTAssertEqual(unchangedMetrics.bytesRead, 0)
    XCTAssertEqual(unchangedMetrics.reusedFileCount, 1)

    try append(token(total: usage(input: 150), last: usage(input: 50)) + "\n", to: url)
    let appended = try await service.estimate(interval: interval)
    let appendMetrics = await service.lastScanMetrics()
    XCTAssertEqual(appended.pricedTokenCount, 150)
    XCTAssertEqual(appendMetrics.incrementallyReadFileCount, 1)
    XCTAssertLessThan(appendMetrics.bytesRead, initialMetrics.bytesRead / 4)
  }

  func testPreIntervalHistoricalFileIsRejectedWithoutReadingContents() async throws {
    let url = sessions.appendingPathComponent("historical.jsonl")
    try write(
      lines: [
        metadata(id: "historical"),
        context(model: "gpt-5.6-sol"),
        token(
          total: usage(input: 100),
          last: usage(input: 100),
          timestamp: "2026-07-19T23:00:00Z"
        ),
      ],
      to: url
    )
    try FileManager.default.setAttributes(
      [.modificationDate: interval.start.addingTimeInterval(-60)],
      ofItemAtPath: url.path
    )
    let service = makeService()

    let estimate = try await service.estimate(interval: interval)
    let scanMetrics = await service.lastScanMetrics()

    XCTAssertEqual(estimate.pricedTokenCount, 0)
    XCTAssertEqual(estimate.scannedFileCount, 0)
    XCTAssertEqual(scanMetrics.bytesRead, 0)
    XCTAssertEqual(scanMetrics.skippedHistoricalFileCount, 1)
  }

  func testTruncationAndReplacementInvalidateFileCache() async throws {
    let url = sessions.appendingPathComponent("changing.jsonl")
    let service = makeService()
    try writeRollout(id: "changing", model: "gpt-5.6-sol", input: 100, at: url)
    let initial = try await service.estimate(interval: interval)
    XCTAssertEqual(initial.pricedTokenCount, 100)

    try writeRollout(id: "changing", model: "gpt-5.6-sol", input: 30, at: url)
    let truncated = try await service.estimate(interval: interval)
    XCTAssertEqual(truncated.pricedTokenCount, 30)

    try FileManager.default.removeItem(at: url)
    try writeRollout(id: "changing", model: "gpt-5.6-sol", input: 60, at: url)
    let replaced = try await service.estimate(interval: interval)
    XCTAssertEqual(replaced.pricedTokenCount, 60)
  }

  func testSameInodeContentMutationInvalidatesSummary() async throws {
    let url = sessions.appendingPathComponent("same-inode-mutation.jsonl")
    try writeRollout(id: "same-inode", model: "gpt-5.6-sol", input: 100, at: url)
    let service = makeService()
    _ = try await service.estimate(interval: interval)
    let inodeBefore = try inode(of: url)

    usleep(10_000)
    let original = try String(contentsOf: url, encoding: .utf8)
    let changed = original.replacingOccurrences(
      of: #""input_tokens":100"#,
      with: #""input_tokens":200"#
    )
    XCTAssertEqual(changed.utf8.count, original.utf8.count)
    try Data(changed.utf8).write(to: url, options: [])
    XCTAssertEqual(try inode(of: url), inodeBefore)

    let estimate = try await service.estimate(interval: interval)
    let scanMetrics = await service.lastScanMetrics()
    XCTAssertEqual(estimate.pricedTokenCount, 200)
    XCTAssertEqual(scanMetrics.invalidatedFileCount, 1)
    XCTAssertEqual(scanMetrics.fullyReadFileCount, 1)
  }

  func testParserPricingFingerprintChangeInvalidatesSummary() async throws {
    try writeRollout(id: "fingerprint", model: "gpt-5.6-sol", input: 100)
    let fingerprint = MutableFingerprint("v1")
    let service = makeService(parserPricingFingerprint: { fingerprint.value })
    _ = try await service.estimate(interval: interval)
    fingerprint.value = "v2"

    let estimate = try await service.estimate(interval: interval)
    let scanMetrics = await service.lastScanMetrics()

    XCTAssertEqual(estimate.pricedTokenCount, 100)
    XCTAssertEqual(scanMetrics.invalidatedFileCount, 1)
    XCTAssertEqual(scanMetrics.fullyReadFileCount, 1)
    XCTAssertGreaterThan(scanMetrics.bytesRead, 0)
  }

  func testResetCacheClearsAggregatedSummaries() async throws {
    try writeRollout(id: "reset", model: "gpt-5.6-sol", input: 100)
    let service = makeService()
    _ = try await service.estimate(interval: interval)
    _ = try await service.estimate(interval: interval)
    let reusedMetrics = await service.lastScanMetrics()
    XCTAssertEqual(reusedMetrics.reusedFileCount, 1)

    await service.resetCache()
    let clearedMetrics = await service.lastScanMetrics()
    XCTAssertEqual(clearedMetrics, LocalCodexCostScanMetrics())
    let estimate = try await service.estimate(interval: interval)
    let scanMetrics = await service.lastScanMetrics()

    XCTAssertEqual(estimate.pricedTokenCount, 100)
    XCTAssertEqual(scanMetrics.fullyReadFileCount, 1)
    XCTAssertEqual(scanMetrics.reusedFileCount, 0)
    XCTAssertGreaterThan(scanMetrics.bytesRead, 0)
  }

  func testModelChangesPriceOnlyTheNewCumulativeDeltaAtTheCurrentModel() async throws {
    try write(
      lines: [
        metadata(id: "model-change"),
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100_000), last: usage(input: 100_000)),
        context(model: "gpt-5.6-terra"),
        token(total: usage(input: 200_000), last: usage(input: 100_000)),
      ],
      to: sessions.appendingPathComponent("model-change.jsonl")
    )

    let estimate = try await makeService().estimate(interval: interval)

    XCTAssertEqual(estimate.measurement.amount, Decimal(string: "0.75"))
    XCTAssertEqual(estimate.pricedTokenCount, 200_000)
  }

  func testPromptAndToolContentNeverAppearInEstimateOrServiceDescription() async throws {
    let secret = "PRIVATE-PROMPT-DO-NOT-RETAIN"
    try write(
      lines: [
        metadata(id: "privacy"),
        #"{"type":"response_item","timestamp":"2026-07-20T00:05:00Z","payload":{"type":"message","content":"\#(secret)"}}"#,
        #"{"type":"response_item","timestamp":"2026-07-20T00:05:01Z","payload":{"type":"tool_call","arguments":{"command":"\#(secret)"}}}"#,
        context(model: "gpt-5.6-sol"),
        token(total: usage(input: 100), last: usage(input: 100)),
      ],
      to: sessions.appendingPathComponent("privacy.jsonl")
    )
    let service = makeService()

    let estimate = try await service.estimate(interval: interval)

    XCTAssertFalse(String(reflecting: estimate).contains(secret))
    XCTAssertFalse(String(reflecting: service).contains(secret))
  }

  private var interval: DateInterval {
    DateInterval(
      start: Date(timeIntervalSince1970: 1_784_505_600),
      end: Date(timeIntervalSince1970: 1_784_509_200)
    )
  }

  private func makeService(
    parserPricingFingerprint: @escaping @Sendable () -> String = { "test-v1" }
  ) -> LocalCodexCostService {
    LocalCodexCostService(
      roots: [sessions, archived],
      now: { Date(timeIntervalSince1970: 1_784_509_000) },
      parserPricingFingerprint: parserPricingFingerprint
    )
  }

  private func writeRollout(
    id: String,
    sessionID: String? = nil,
    model: String,
    input: Int64,
    cached: Int64 = 0,
    cacheWrite: Int64 = 0,
    output: Int64 = 0,
    at explicitURL: URL? = nil
  ) throws {
    let total = usage(input: input, cached: cached, cacheWrite: cacheWrite, output: output)
    try write(
      lines: [
        metadata(id: id, sessionID: sessionID), context(model: model),
        token(total: total, last: total),
      ],
      to: explicitURL ?? sessions.appendingPathComponent("\(id).jsonl")
    )
  }

  private func write(lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
  }

  private func append(_ value: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(value.utf8))
  }

  private func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
  }

  private func paddingLine(_ marker: Int) -> String {
    #"{"type":"response_item","timestamp":"2026-07-20T00:05:00Z","payload":{"type":"message","content":"padding-\#(marker)-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"#
  }

  private func metadata(
    id: String,
    sessionID: String? = nil,
    parent: String? = nil,
    forkedFrom: String? = nil
  ) -> String {
    let session = sessionID.map { #", "session_id":"\#($0)""# } ?? ""
    let parent = parent.map { #", "parent_thread_id":"\#($0)""# } ?? ""
    let forked = forkedFrom.map { #", "forked_from_id":"\#($0)""# } ?? ""
    return
      #"{"type":"session_meta","timestamp":"2026-07-20T00:01:00Z","payload":{"id":"\#(id)"\#(session)\#(parent)\#(forked)}}"#
  }

  private func context(model: String) -> String {
    #"{"type":"turn_context","timestamp":"2026-07-20T00:02:00Z","payload":{"model":"\#(model)"}}"#
  }

  private func token(
    total: String,
    last: String?,
    timestamp: String = "2026-07-20T00:10:00Z"
  ) -> String {
    let last = last.map { #", "last_token_usage":\#($0)"# } ?? ""
    return
      #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":\#(total)\#(last)}}}"#
  }

  private func usage(
    input: Int64,
    cached: Int64 = 0,
    cacheWrite: Int64 = 0,
    output: Int64 = 0,
    reasoning: Int64 = 0
  ) -> String {
    #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning)}"#
  }
}

private final class MutableFingerprint: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String

  init(_ value: String) {
    storage = value
  }

  var value: String {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}
