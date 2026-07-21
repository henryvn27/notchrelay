import Foundation

protocol LocalCodexCostEstimating: Sendable {
  func estimate(interval: DateInterval) async throws -> LocalCodexCostEstimate
  func resetCache() async
}

enum LocalCodexCostExclusionReason: String, CaseIterable, Equatable, Sendable {
  case unknownModel
  case malformedRecord
  case oversizedRecord
  case incompleteFinalRecord
  case missingRolloutIdentifier
  case unresolvedLineage
  case counterDiscontinuity
  case inconsistentTokenCounters
  case ambiguousLongContextPricing
  case priorityMetadataUnavailable
  case missingTurnIdentifier
  case ambiguousPriorityPricing
  case invalidTokenPartition
  case fileChangedDuringScan
  case duplicateRollout
  case forkLineageUncertainty
}

struct LocalCodexCostScanMetrics: Equatable, Sendable {
  var bytesRead = 0
  var completeRecordCount = 0
  var decodedRecordCount = 0
  var decodedRecordBytes = 0
  var peakRetainedRecordBytes = 0
  var recordBufferAppendCount = 0
  var fullyReadFileCount = 0
  var incrementallyReadFileCount = 0
  var reusedFileCount = 0
  var skippedHistoricalFileCount = 0
  var invalidatedFileCount = 0
}

struct LocalCodexCostEstimate: Equatable, Sendable {
  let measurement: CostMeasurement
  let pricedTokenCount: Int
  let unpricedTokenCount: Int
  let excludedToolFees: Bool
  let exclusionReasons: [LocalCodexCostExclusionReason]
  let scannedFileCount: Int
  let refreshedAt: Date
}
