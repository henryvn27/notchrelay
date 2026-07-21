import Foundation
import OSLog
import Observation

struct SanitizedBridgeRecord: Identifiable, Equatable, Sendable {
  let id: UUID
  let timestamp: Date
  let event: String
  let project: String
  let outcome: String
}

@Observable
final class EventLogger {
  private struct CanonicalInput {
    let value: String
    let removedBoundaryOffsets: Set<Int>
  }

  private struct SensitiveField {
    let replacementStart: Int
    let labelStart: Int
    let labelEnd: Int
    let delimiter: Int
    let normalizedLabel: String
  }

  private struct CredentialLabelWord {
    let start: Int
    let end: Int
    let normalized: String
  }

  private struct CredentialLabelScan {
    let field: SensitiveField?
    let end: Int
  }

  private struct CredentialLabelCandidate {
    let replacementStart: Int
    let labelStart: Int
    var labelEnd: Int
    var normalizedLabel: String
  }

  private enum ProtectedValueKind {
    case authorization
    case bearer
  }

  private static let maximumInputScalars = 4_096
  private static let maximumScannedInputScalars = maximumInputScalars * 4
  private static let maximumSensitiveIdentifierScalars = 13
  private static let maximumCredentialLabelWords = maximumSensitiveIdentifierScalars
  private static let maximumErrorScalars = 400

  @MainActor private(set) var recentEvents: [SanitizedBridgeRecord] = []
  @MainActor private(set) var recentErrors: [String] = []

  #if DEBUG
    nonisolated(unsafe) static private(set) var credentialLabelScanCountForTesting = 0

    static func resetCredentialLabelScanCountForTesting() {
      credentialLabelScanCountForTesting = 0
    }
  #endif

  private let logger = Logger(subsystem: "com.henryvn27.Cowlick", category: "Bridge")
  private let maximumRecords = 10

  @MainActor
  init() {}

  @MainActor
  func record(event: BridgeEventName, project: String, outcome: String = "accepted") {
    let record = SanitizedBridgeRecord(
      id: UUID(),
      timestamp: Date(),
      event: event.rawValue,
      project: Self.sanitizeProject(project),
      outcome: outcome
    )
    recentEvents.append(record)
    recentEvents = Array(recentEvents.suffix(maximumRecords))
    logger.info(
      "Bridge event \(event.rawValue, privacy: .public) for \(record.project, privacy: .public): \(outcome, privacy: .public)"
    )
  }

  @MainActor
  func error(_ message: String) {
    let sanitized = Self.sanitizeError(message)
    recentErrors.append(sanitized)
    recentErrors = Array(recentErrors.suffix(maximumRecords))
    logger.error("\(sanitized, privacy: .public)")
  }

  @MainActor
  func reset() {
    recentEvents.removeAll()
    recentErrors.removeAll()
  }

  static func sanitizeProject(_ value: String) -> String {
    let name = URL(fileURLWithPath: value).lastPathComponent
    let candidate = name.isEmpty ? value : name
    return String(sanitizeError(candidate).unicodeScalars.prefix(80))
  }

  static func sanitizeError(
    _ value: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> String {
    let canonical = restoringBearerValueBoundaries(
      in: removingUnsafeCharacters(from: value)
    )
    var sanitized = redactHome(
      in: canonical.value,
      removedBoundaryOffsets: canonical.removedBoundaryOffsets,
      homeDirectory: homeDirectory
    )
    sanitized = redactCredentials(in: sanitized)
    sanitized = sanitized.replacingOccurrences(
      of: #"\s+"#, with: " ", options: .regularExpression)
    return String(sanitized.unicodeScalars.prefix(maximumErrorScalars))
  }

  private static func removingUnsafeCharacters(from value: String) -> CanonicalInput {
    let unsafeCharacters = CharacterSet.controlCharacters.union(.newlines)
    var canonical = ""
    var removedBoundaryOffsets: Set<Int> = []
    var canonicalUTF16Count = 0
    var iterator = value.unicodeScalars.makeIterator()
    var retainedCount = 0
    var scannedCount = 0
    while retainedCount < maximumInputScalars, scannedCount < maximumScannedInputScalars,
      let scalar = iterator.next()
    {
      scannedCount += 1
      let category = scalar.properties.generalCategory
      let isNonASCIISeparator =
        scalar.value > 0x7F
        && (category == .spaceSeparator || category == .lineSeparator
          || category == .paragraphSeparator)
      let isRemovedScalar =
        unsafeCharacters.contains(scalar) || scalar.properties.isDefaultIgnorableCodePoint
        || category == .format || category == .privateUse || isNonASCIISeparator
      if isRemovedScalar {
        removedBoundaryOffsets.insert(canonicalUTF16Count)
        continue
      }
      canonical.unicodeScalars.append(scalar)
      canonicalUTF16Count += scalar.value > 0xFFFF ? 2 : 1
      retainedCount += 1
    }
    if iterator.next() != nil {
      return CanonicalInput(value: "<redacted>", removedBoundaryOffsets: [])
    }
    return CanonicalInput(
      value: canonical,
      removedBoundaryOffsets: removedBoundaryOffsets
    )
  }

  private static func restoringBearerValueBoundaries(in input: CanonicalInput) -> CanonicalInput {
    guard !input.removedBoundaryOffsets.isEmpty else { return input }
    let scalars = Array(input.value.unicodeScalars)
    let utf16Offsets = scalarUTF16Offsets(in: scalars)
    let pathContexts = bearerPathContexts(in: scalars)
    var insertionIndexes: Set<Int> = []

    var runStart = 0
    while runStart < scalars.count {
      guard isIdentifierScalar(scalars[runStart]) else {
        runStart += 1
        continue
      }
      var runEnd = runStart + 1
      while runEnd < scalars.count, isIdentifierScalar(scalars[runEnd]) { runEnd += 1 }

      var normalizedIndexes: [Int] = []
      normalizedIndexes.reserveCapacity(runEnd - runStart)
      for index in runStart..<runEnd where !isIdentifierJoiner(scalars[index]) {
        normalizedIndexes.append(index)
      }
      if normalizedIndexes.count >= 6 {
        for normalizedStart in 0...(normalizedIndexes.count - 6) {
          let labelIndexes = normalizedIndexes[normalizedStart..<(normalizedStart + 6)]
          guard isBearerSequence(in: scalars, at: labelIndexes) else { continue }

          let identifierStart = labelIndexes.first!
          let tokenStart = credentialLabelOpeningStart(in: scalars, before: identifierStart)
          let hasRemovedStart =
            input.removedBoundaryOffsets.contains(utf16Offsets[tokenStart])
            || input.removedBoundaryOffsets.contains(utf16Offsets[identifierStart])
          guard normalizedStart == 0 || hasRemovedStart else { continue }
          guard
            isStandaloneBearerStart(
              in: scalars,
              at: tokenStart,
              hasRemovedStart: hasRemovedStart,
              pathContexts: pathContexts
            )
          else { continue }

          let identifierEnd = labelIndexes.last! + 1
          for boundary in bearerValueBoundaryIndexes(
            in: scalars,
            afterIdentifierAt: identifierEnd,
            utf16Offsets: utf16Offsets,
            removedBoundaryOffsets: input.removedBoundaryOffsets
          ) {
            insertionIndexes.insert(boundary)
            if hasRemovedStart, tokenStart > 0,
              !CharacterSet.whitespacesAndNewlines.contains(scalars[tokenStart - 1])
            {
              insertionIndexes.insert(tokenStart)
            }
          }
        }
      }
      runStart = runEnd
    }
    guard !insertionIndexes.isEmpty else { return input }

    var restored = ""
    var adjustedOffsets: Set<Int> = []
    var originalOffset = 0
    var insertedCount = 0
    for index in 0...scalars.count {
      let restoresBoundary = insertionIndexes.contains(index)
      if restoresBoundary {
        restored.append(" ")
        insertedCount += 1
      }
      if input.removedBoundaryOffsets.contains(originalOffset), !restoresBoundary {
        adjustedOffsets.insert(originalOffset + insertedCount)
      }
      guard index < scalars.count else { continue }
      restored.unicodeScalars.append(scalars[index])
      originalOffset += scalars[index].value > 0xFFFF ? 2 : 1
    }
    return CanonicalInput(value: restored, removedBoundaryOffsets: adjustedOffsets)
  }

  private static func scalarUTF16Offsets(in scalars: [UnicodeScalar]) -> [Int] {
    var offsets = [Int]()
    offsets.reserveCapacity(scalars.count + 1)
    var offset = 0
    for scalar in scalars {
      offsets.append(offset)
      offset += scalar.value > 0xFFFF ? 2 : 1
    }
    offsets.append(offset)
    return offsets
  }

  private static func bearerPathContexts(in scalars: [UnicodeScalar]) -> [Bool] {
    var contexts = Array(repeating: false, count: scalars.count + 1)
    var isInsidePathComponent = false
    for index in scalars.indices {
      contexts[index] = isInsidePathComponent
      let scalar = scalars[index]
      if scalar.value == 0x2F || scalar.value == 0x5C {
        isInsidePathComponent = true
      } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || [0x2C, 0x3A, 0x3B, 0x3D].contains(scalar.value)
      {
        isInsidePathComponent = false
      }
    }
    contexts[scalars.count] = isInsidePathComponent
    return contexts
  }

  private static func isBearerSequence(
    in scalars: [UnicodeScalar],
    at indexes: ArraySlice<Int>
  ) -> Bool {
    let expected: [UInt32] = [0x62, 0x65, 0x61, 0x72, 0x65, 0x72]
    guard indexes.count == expected.count else { return false }
    for (index, expectedValue) in zip(indexes, expected) {
      let value = scalars[index].value
      let lowercase = value >= 0x41 && value <= 0x5A ? value + 0x20 : value
      guard lowercase == expectedValue else { return false }
    }
    return true
  }

  private static func credentialLabelOpeningStart(
    in scalars: [UnicodeScalar],
    before identifierStart: Int
  ) -> Int {
    var start = identifierStart
    while start > 0 {
      if start > 1, scalars[start - 2].value == 0x5C,
        isCredentialLabelQuote(scalars[start - 1])
      {
        start -= 2
      } else if isCredentialLabelQuote(scalars[start - 1]) {
        start -= 1
      } else {
        break
      }
    }
    return start
  }

  private static func isStandaloneBearerStart(
    in scalars: [UnicodeScalar],
    at tokenStart: Int,
    hasRemovedStart: Bool,
    pathContexts: [Bool]
  ) -> Bool {
    guard !pathContexts[tokenStart] else { return false }
    guard tokenStart > 0 else { return true }
    let precedingScalar = scalars[tokenStart - 1]
    if scalars[tokenStart].value == 0x5C, precedingScalar.value == 0x3A {
      return false
    }
    if hasRemovedStart { return true }
    return !isIdentifierContextScalar(precedingScalar)
      && precedingScalar.value != 0x2F && precedingScalar.value != 0x5C
  }

  private static func bearerValueBoundaryIndexes(
    in scalars: [UnicodeScalar],
    afterIdentifierAt identifierEnd: Int,
    utf16Offsets: [Int],
    removedBoundaryOffsets: Set<Int>
  ) -> [Int] {
    var boundaries: [Int] = []
    var cursor = identifierEnd
    while cursor < scalars.count, isIdentifierJoiner(scalars[cursor]) {
      if removedBoundaryOffsets.contains(utf16Offsets[cursor]),
        isBearerValueScalar(scalars[cursor])
      {
        boundaries.append(cursor)
      }
      cursor += 1
    }
    if cursor < scalars.count, removedBoundaryOffsets.contains(utf16Offsets[cursor]),
      isBearerValueScalar(scalars[cursor])
    {
      boundaries.append(cursor)
    }

    var terminatorCursor = identifierEnd
    var foundTerminator = false
    while let terminatorEnd = credentialLabelTerminatorEnd(
      in: scalars, from: terminatorCursor)
    {
      foundTerminator = true
      terminatorCursor = terminatorEnd
      if terminatorCursor < scalars.count,
        removedBoundaryOffsets.contains(utf16Offsets[terminatorCursor]),
        isBearerValueScalar(scalars[terminatorCursor])
      {
        boundaries.append(terminatorCursor)
        break
      }
      let next = skipWhitespace(in: scalars, from: terminatorCursor)
      if next < scalars.count, removedBoundaryOffsets.contains(utf16Offsets[next]),
        isBearerValueScalar(scalars[next])
      {
        boundaries.append(next)
        break
      }
      guard credentialLabelTerminatorEnd(in: scalars, from: next) != nil else { break }
      terminatorCursor = next
    }
    if foundTerminator, terminatorCursor < scalars.count,
      removedBoundaryOffsets.contains(utf16Offsets[terminatorCursor]),
      isBearerValueScalar(scalars[terminatorCursor])
    {
      boundaries.append(terminatorCursor)
    }
    return boundaries
  }

  private static func isBearerValueScalar(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (value >= 0x30 && value <= 0x39)
      || (value >= 0x41 && value <= 0x5A)
      || (value >= 0x61 && value <= 0x7A)
      || [0x2B, 0x2D, 0x2E, 0x2F, 0x5F, 0x7E].contains(value)
      || isQuote(scalar) || isUnicodeQuoteMarker(scalar)
  }

  private static func redactHome(
    in value: String,
    removedBoundaryOffsets: Set<Int>,
    homeDirectory: URL
  ) -> String {
    var redacted = value
    let homePath = homeDirectory.standardizedFileURL.path
    if !homePath.isEmpty, homePath != "/" {
      redacted = redactExactHome(
        in: redacted,
        homePath: homePath,
        removedBoundaryOffsets: removedBoundaryOffsets
      )
    }

    return redacted.replacingOccurrences(
      of: #"/Users/[^/\s]+"#,
      with: "~",
      options: [.regularExpression, .caseInsensitive]
    )
  }

  private static func redactExactHome(
    in value: String,
    homePath: String,
    removedBoundaryOffsets: Set<Int>
  ) -> String {
    guard
      let expression = try? NSRegularExpression(
        pattern: NSRegularExpression.escapedPattern(for: homePath),
        options: .caseInsensitive
      )
    else { return value }

    let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = expression.matches(in: value, range: fullRange).filter { match in
      hasHomeBoundary(
        in: value,
        atUTF16Offset: NSMaxRange(match.range),
        removedBoundaryOffsets: removedBoundaryOffsets
      )
    }
    var redacted = value
    for match in matches.reversed() {
      guard let range = Range(match.range, in: redacted) else { continue }
      let matchEnd = NSMaxRange(match.range)
      let replacement =
        removedBoundaryOffsets.contains(matchEnd)
          && !hasVisibleHomeBoundary(
            in: value,
            atUTF16Offset: matchEnd,
            removedBoundaryOffsets: removedBoundaryOffsets
          )
        ? "~ " : "~"
      redacted.replaceSubrange(range, with: replacement)
    }
    return redacted
  }

  private static func hasHomeBoundary(
    in value: String,
    atUTF16Offset offset: Int,
    removedBoundaryOffsets: Set<Int>
  ) -> Bool {
    removedBoundaryOffsets.contains(offset)
      || hasVisibleHomeBoundary(
        in: value,
        atUTF16Offset: offset,
        removedBoundaryOffsets: removedBoundaryOffsets
      )
  }

  private static func hasVisibleHomeBoundary(
    in value: String,
    atUTF16Offset offset: Int,
    removedBoundaryOffsets: Set<Int>
  ) -> Bool {
    guard let scalar = nextScalar(in: value, atUTF16Offset: offset) else { return true }
    if scalar.value == 0x2F || CharacterSet.whitespacesAndNewlines.contains(scalar) {
      return true
    }
    guard CharacterSet.punctuationCharacters.contains(scalar) else { return false }

    var cursor = offset
    while let punctuation = nextScalar(in: value, atUTF16Offset: cursor),
      CharacterSet.punctuationCharacters.contains(punctuation)
    {
      cursor += punctuation.value > 0xFFFF ? 2 : 1
      if isProseDelimiter(punctuation) || removedBoundaryOffsets.contains(cursor) { return true }
    }
    return nextScalar(in: value, atUTF16Offset: cursor).map({
      CharacterSet.whitespacesAndNewlines.contains($0)
    }) ?? true
  }

  private static func nextScalar(in value: String, atUTF16Offset offset: Int) -> UnicodeScalar? {
    let index = String.Index(utf16Offset: offset, in: value)
    return index < value.endIndex ? value[index...].unicodeScalars.first : nil
  }

  private static func isProseDelimiter(_ scalar: UnicodeScalar) -> Bool {
    scalar.value != 0x2D && scalar.value != 0x2E && scalar.value != 0x5F
  }

  private static func redactCredentials(in value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var output = ""
    var cursor = 0
    var index = 0
    var flexibleScanSkipUntil = 0

    while index < scalars.count {
      let quote = isCredentialLabelQuote(scalars[index]) ? scalars[index] : nil
      let identifierStart = quote == nil ? index : index + 1
      guard identifierStart < scalars.count, isIdentifierScalar(scalars[identifierStart]) else {
        index += 1
        continue
      }

      var identifierEnd = identifierStart
      while identifierEnd < scalars.count, isIdentifierScalar(scalars[identifierEnd]) {
        identifierEnd += 1
      }
      var afterIdentifier = identifierEnd
      while let terminatorEnd = credentialLabelTerminatorEnd(in: scalars, from: afterIdentifier) {
        afterIdentifier = terminatorEnd
        let nextMarker = skipWhitespace(in: scalars, from: afterIdentifier)
        guard
          let nextTerminatorEnd = credentialLabelTerminatorEnd(in: scalars, from: nextMarker),
          nextTerminatorEnd == scalars.count
            || CharacterSet.whitespacesAndNewlines.contains(scalars[nextTerminatorEnd])
            || isCredentialDelimiter(scalars[nextTerminatorEnd])
            || credentialLabelTerminatorEnd(in: scalars, from: nextTerminatorEnd) != nil
        else { break }
        afterIdentifier = nextMarker
      }

      let identifier = scalars[identifierStart..<identifierEnd]
      let whitespaceEnd = skipWhitespace(in: scalars, from: afterIdentifier)
      let hasDelimitedValue =
        credentialDelimiter(in: scalars, afterLabelAt: identifierEnd) != nil
      if whitespaceEnd > afterIdentifier, !hasDelimitedValue, isBearerIdentifier(identifier),
        let valueEnd = protectedValueEnd(in: scalars, from: whitespaceEnd, kind: .bearer)
      {
        output.append(contentsOf: string(from: scalars[cursor..<index]))
        output.append("bearer=<redacted>")
        cursor = valueEnd
        index = valueEnd
        continue
      }

      let labelScan =
        index < flexibleScanSkipUntil ? nil : credentialLabelScan(in: scalars, from: index)
      if let field = labelScan?.field {
        let valueStart = skipWhitespace(in: scalars, from: field.delimiter + 1)
        let valueEnd: Int?
        if isAuthorizationIdentifier(field.normalizedLabel) {
          valueEnd = protectedValueEnd(in: scalars, from: valueStart, kind: .authorization)
        } else if isBearerIdentifier(field.normalizedLabel) {
          valueEnd = protectedValueEnd(in: scalars, from: valueStart, kind: .bearer)
        } else {
          valueEnd = credentialValueEnd(in: scalars, from: valueStart)
        }
        if let valueEnd {
          output.append(contentsOf: string(from: scalars[cursor..<field.replacementStart]))
          output.append(
            contentsOf: isAuthorizationIdentifier(field.normalizedLabel)
              ? "authorization" : string(from: scalars[field.labelStart..<field.labelEnd]))
          output.append("=<redacted>")
          cursor = valueEnd
          index = valueEnd
          continue
        }
      }
      if let labelScan {
        flexibleScanSkipUntil = max(flexibleScanSkipUntil, labelScan.end)
      }

      index = max(index + 1, afterIdentifier)
    }

    output.append(contentsOf: string(from: scalars[cursor...]))
    return output
  }

  private static func string(from scalars: ArraySlice<UnicodeScalar>) -> String {
    var value = ""
    for scalar in scalars { value.unicodeScalars.append(scalar) }
    return value
  }

  private static func skipWhitespace(in scalars: [UnicodeScalar], from start: Int) -> Int {
    var end = start
    while end < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[end]) {
      end += 1
    }
    return end
  }

  private static func credentialDelimiter(
    in scalars: [UnicodeScalar],
    afterLabelAt start: Int
  ) -> Int? {
    var end = start
    while true {
      end = skipWhitespace(in: scalars, from: end)
      guard let terminatorEnd = credentialLabelTerminatorEnd(in: scalars, from: end) else { break }
      end = terminatorEnd
    }
    return end < scalars.count && isCredentialDelimiter(scalars[end]) ? end : nil
  }

  private static func credentialLabelTerminatorEnd(
    in scalars: [UnicodeScalar],
    from start: Int
  ) -> Int? {
    guard start < scalars.count else { return nil }
    if isCredentialLabelQuote(scalars[start]) { return start + 1 }
    if scalars[start].value == 0x5C, start + 1 < scalars.count,
      isCredentialLabelQuote(scalars[start + 1])
    {
      return start + 2
    }
    return nil
  }

  private static func credentialValueEnd(in scalars: [UnicodeScalar], from start: Int) -> Int? {
    guard start < scalars.count else { return nil }
    if isQuote(scalars[start]) {
      let quote = scalars[start]
      var end = start + 1
      while end < scalars.count {
        if scalars[end] == quote {
          let afterQuote = end + 1
          return afterQuote == scalars.count || isValueTerminator(scalars[afterQuote])
            ? afterQuote : scalars.count
        }
        end += scalars[end].value == 0x5C && end + 1 < scalars.count ? 2 : 1
      }
      return scalars.count
    }
    if let closingQuote = unicodeCredentialValueClosingQuote(for: scalars[start]) {
      var end = start + 1
      while end < scalars.count {
        if scalars[end] == closingQuote {
          let afterQuote = end + 1
          return afterQuote == scalars.count || isValueTerminator(scalars[afterQuote])
            ? afterQuote : scalars.count
        }
        end += 1
      }
      return scalars.count
    }
    if isUnicodeQuoteMarker(scalars[start]) { return scalars.count }

    var end = start
    while end < scalars.count, !isValueTerminator(scalars[end]) {
      if isQuote(scalars[end]) || isUnicodeQuoteMarker(scalars[end]) {
        return scalars.count
      }
      end += 1
    }
    return end > start ? end : nil
  }

  private static func protectedValueEnd(
    in scalars: [UnicodeScalar],
    from start: Int,
    kind: ProtectedValueKind
  ) -> Int? {
    guard start < scalars.count else { return nil }
    var end = start
    var quote: UnicodeScalar?
    var quoteAllowsEscapes = false
    var isAtValueBoundary = true
    var sensitiveFieldScanSkipUntil = start
    while end < scalars.count {
      let scalar = scalars[end]
      if let activeQuote = quote {
        if quoteAllowsEscapes, scalar.value == 0x5C, end + 1 < scalars.count {
          end += 2
          continue
        }
        if scalar == activeQuote {
          let afterQuote = end + 1
          if afterQuote < scalars.count, !isValueTerminator(scalars[afterQuote]) {
            return scalars.count
          }
          quote = nil
          quoteAllowsEscapes = false
        }
        end += 1
        continue
      }
      if isQuote(scalar) {
        guard isAtValueBoundary else { return scalars.count }
        quote = scalar
        quoteAllowsEscapes = true
        isAtValueBoundary = false
        end += 1
        continue
      }
      if let closingQuote = unicodeCredentialValueClosingQuote(for: scalar) {
        guard isAtValueBoundary else { return scalars.count }
        quote = closingQuote
        quoteAllowsEscapes = false
        isAtValueBoundary = false
        end += 1
        continue
      }
      if isUnicodeQuoteMarker(scalar) { return scalars.count }
      if kind == .bearer, isExplicitValueTerminator(scalar) { break }
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        let nextField = skipWhitespace(in: scalars, from: end)
        if kind == .authorization {
          end = nextField
          isAtValueBoundary = true
          continue
        }
        if nextField < scalars.count,
          isQuote(scalars[nextField])
            || isUnicodeQuoteMarker(scalars[nextField])
        {
          end = nextField
          isAtValueBoundary = true
          continue
        }
        let fieldScan =
          nextField < sensitiveFieldScanSkipUntil
          ? nil : credentialLabelScan(in: scalars, from: nextField)
        if let fieldScan {
          sensitiveFieldScanSkipUntil = max(sensitiveFieldScanSkipUntil, fieldScan.end)
        }
        if let field = fieldScan?.field {
          var boundary = field.replacementStart
          while boundary > start,
            CharacterSet.whitespacesAndNewlines.contains(scalars[boundary - 1])
          {
            boundary -= 1
          }
          return boundary
        }
        end = nextField
        isAtValueBoundary = true
        continue
      }
      isAtValueBoundary = false
      end += 1
    }
    return end > start ? end : nil
  }

  private static func credentialLabelScan(
    in scalars: [UnicodeScalar],
    from start: Int
  ) -> CredentialLabelScan? {
    #if DEBUG
      credentialLabelScanCountForTesting += 1
    #endif
    guard start < scalars.count else { return nil }
    var cursor = start
    while let markerEnd = credentialLabelTerminatorEnd(in: scalars, from: cursor) {
      cursor = markerEnd
    }
    guard cursor < scalars.count, isIdentifierScalar(scalars[cursor]) else { return nil }
    let hasLeadingWrapper = cursor > start
    let labelStart = cursor
    var words: [CredentialLabelWord] = []
    var candidate: CredentialLabelCandidate?
    var semanticTail = ""
    var sawAuthorizationSemantic = false
    var sawBearerSemantic = false

    while candidate != nil || words.count < maximumCredentialLabelWords {
      let wordStart = cursor
      var normalized = ""
      var wordEnd = cursor
      while cursor < scalars.count {
        let scalar = scalars[cursor]
        if isIdentifierScalar(scalar) {
          if !isIdentifierJoiner(scalar) {
            let value = scalar.value
            let lowercase = UnicodeScalar(value >= 0x41 && value <= 0x5A ? value + 0x20 : value)!
            normalized.unicodeScalars.append(lowercase)
            semanticTail.unicodeScalars.append(lowercase)
            if semanticTail.unicodeScalars.count > maximumSensitiveIdentifierScalars {
              semanticTail.unicodeScalars.removeFirst()
            }
            sawAuthorizationSemantic =
              sawAuthorizationSemantic || isAuthorizationIdentifier(semanticTail)
            sawBearerSemantic = sawBearerSemantic || isBearerIdentifier(semanticTail)
          }
          cursor += 1
          wordEnd = cursor
          continue
        }
        guard
          let markerEnd = credentialLabelTerminatorEnd(in: scalars, from: cursor),
          markerEnd < scalars.count, isIdentifierScalar(scalars[markerEnd])
        else { break }
        cursor = markerEnd
      }
      guard wordEnd > wordStart else { break }
      if candidate == nil {
        words.append(
          CredentialLabelWord(start: wordStart, end: wordEnd, normalized: normalized)
        )
        candidate = credentialLabelCandidate(
          in: words,
          start: start,
          labelStart: labelStart,
          hasLeadingWrapper: hasLeadingWrapper
        )
      } else {
        candidate?.labelEnd = wordEnd
        if sawAuthorizationSemantic {
          candidate?.normalizedLabel = "authorization"
        } else if candidate.map({ !isAuthorizationIdentifier($0.normalizedLabel) }) == true,
          sawBearerSemantic
        {
          candidate?.normalizedLabel = "bearer"
        }
      }

      if let delimiter = credentialDelimiter(in: scalars, afterLabelAt: cursor) {
        if let candidate {
          let field = SensitiveField(
            replacementStart: candidate.replacementStart,
            labelStart: candidate.labelStart,
            labelEnd: candidate.labelEnd,
            delimiter: delimiter,
            normalizedLabel: candidate.normalizedLabel
          )
          return CredentialLabelScan(field: field, end: delimiter + 1)
        }
        return CredentialLabelScan(field: nil, end: delimiter + 1)
      }

      var nextWord = cursor
      while true {
        nextWord = skipWhitespace(in: scalars, from: nextWord)
        guard let markerEnd = credentialLabelTerminatorEnd(in: scalars, from: nextWord) else {
          break
        }
        nextWord = markerEnd
      }
      guard candidate != nil || words.count < maximumCredentialLabelWords,
        nextWord > cursor,
        nextWord < scalars.count, isIdentifierScalar(scalars[nextWord])
      else {
        return CredentialLabelScan(
          field: nil,
          end: candidate == nil ? words.first?.end ?? max(cursor, nextWord) : max(cursor, nextWord)
        )
      }
      cursor = nextWord
    }
    return CredentialLabelScan(
      field: nil,
      end: candidate == nil ? words.first?.end ?? cursor : cursor
    )
  }

  private static func credentialLabelCandidate(
    in words: [CredentialLabelWord],
    start: Int,
    labelStart: Int,
    hasLeadingWrapper: Bool
  ) -> CredentialLabelCandidate? {
    var combined = ""
    var fallback: CredentialLabelCandidate?
    for word in words.reversed() {
      combined = word.normalized + combined
      guard isSensitiveIdentifier(combined) else { continue }
      let candidate = CredentialLabelCandidate(
        replacementStart: hasLeadingWrapper ? start : word.start,
        labelStart: hasLeadingWrapper ? labelStart : word.start,
        labelEnd: words.last!.end,
        normalizedLabel: combined
      )
      if isAuthorizationIdentifier(combined) || isBearerIdentifier(combined) {
        return candidate
      }
      if fallback == nil { fallback = candidate }
    }
    return fallback
  }

  private static func isSensitiveIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    isSensitiveIdentifier(normalizedIdentifier(identifier))
  }

  private static func isSensitiveIdentifier(_ normalized: String) -> Bool {
    return [
      "accesskey", "accesstoken", "refreshtoken", "clientsecret", "authtoken", "apikey",
      "authorization", "bearer", "credential", "signature", "password", "passwd", "token",
      "secret",
    ].contains { normalized.contains($0) }
  }

  private static func isAuthorizationIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    isAuthorizationIdentifier(normalizedIdentifier(identifier))
  }

  private static func isAuthorizationIdentifier(_ normalized: String) -> Bool {
    normalized.contains("authorization")
  }

  private static func isBearerIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    isBearerIdentifier(normalizedIdentifier(identifier))
  }

  private static func isBearerIdentifier(_ normalized: String) -> Bool {
    normalized.contains("bearer")
  }

  private static func normalizedIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> String {
    var normalized = ""
    for scalar in identifier
    where scalar.value != 0x2D && scalar.value != 0x2E && scalar.value != 0x5F {
      let value = scalar.value
      normalized.unicodeScalars.append(
        UnicodeScalar(value >= 0x41 && value <= 0x5A ? value + 0x20 : value)!)
    }
    return normalized
  }

  private static func isIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (value >= 0x30 && value <= 0x39)
      || (value >= 0x41 && value <= 0x5A)
      || (value >= 0x61 && value <= 0x7A)
      || value == 0x2D || value == 0x2E || value == 0x5F
  }

  private static func isIdentifierJoiner(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x2D || scalar.value == 0x2E || scalar.value == 0x5F
  }

  private static func isIdentifierContextScalar(_ scalar: UnicodeScalar) -> Bool {
    isIdentifierScalar(scalar) || CharacterSet.alphanumerics.contains(scalar)
      || scalar.properties.generalCategory == .nonspacingMark
      || scalar.properties.generalCategory == .spacingMark
      || scalar.properties.generalCategory == .enclosingMark
  }

  private static func isQuote(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x22 || scalar.value == 0x27
  }

  private static func isCredentialLabelQuote(_ scalar: UnicodeScalar) -> Bool {
    isQuote(scalar) || isUnicodeQuoteMarker(scalar)
  }

  private static func isUnicodeQuoteMarker(_ scalar: UnicodeScalar) -> Bool {
    scalar.properties.isQuotationMark
      || scalar.properties.generalCategory == .initialPunctuation
      || scalar.properties.generalCategory == .finalPunctuation
  }

  private static func unicodeCredentialValueClosingQuote(
    for openingQuote: UnicodeScalar
  ) -> UnicodeScalar? {
    switch openingQuote.value {
    case 0x201C: UnicodeScalar(0x201D)
    case 0x2018: UnicodeScalar(0x2019)
    case 0x00AB: UnicodeScalar(0x00BB)
    case 0x2039: UnicodeScalar(0x203A)
    default: nil
    }
  }

  private static func isCredentialDelimiter(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x3A, 0x3D, 0xFF1A, 0xFF1D: true
    default: false
    }
  }

  private static func isValueTerminator(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.whitespacesAndNewlines.contains(scalar)
      || scalar.value == 0x2C || scalar.value == 0x3B
  }

  private static func isExplicitValueTerminator(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x2C || scalar.value == 0x3B
  }
}
