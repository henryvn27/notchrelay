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

@MainActor
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

  private static let maximumInputScalars = 4_096
  private static let maximumScannedInputScalars = maximumInputScalars * 4
  private static let maximumCredentialLabelWords = 6
  private static let maximumErrorScalars = 400

  private(set) var recentEvents: [SanitizedBridgeRecord] = []
  private(set) var recentErrors: [String] = []

  private let logger = Logger(subsystem: "com.henryvn27.Cowlick", category: "Bridge")
  private let maximumRecords = 10

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

  func error(_ message: String) {
    let sanitized = Self.sanitizeError(message)
    recentErrors.append(sanitized)
    recentErrors = Array(recentErrors.suffix(maximumRecords))
    logger.error("\(sanitized, privacy: .public)")
  }

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
    var insertionIndexes: Set<Int> = []
    var originalOffset = 0
    for index in scalars.indices {
      if input.removedBoundaryOffsets.contains(originalOffset),
        hasStandaloneBearerLabel(in: scalars, endingAt: index),
        isBearerValueScalar(scalars[index])
      {
        insertionIndexes.insert(index)
      }
      originalOffset += scalars[index].value > 0xFFFF ? 2 : 1
    }
    guard !insertionIndexes.isEmpty else { return input }

    var restored = ""
    var adjustedOffsets: Set<Int> = []
    originalOffset = 0
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

  private static func hasStandaloneBearerLabel(
    in scalars: [UnicodeScalar],
    endingAt end: Int
  ) -> Bool {
    var labelStart = end - 6
    var identifierEnd = end
    if end > 0, isCredentialLabelQuote(scalars[end - 1]) {
      identifierEnd -= 1
      labelStart = identifierEnd - 7
      guard labelStart >= 0, isCredentialLabelQuote(scalars[labelStart]) else { return false }
      labelStart += 1
    }
    guard labelStart >= 0, identifierEnd - labelStart == 6,
      normalizedIdentifier(scalars[labelStart..<identifierEnd]) == "bearer"
    else { return false }

    let tokenStart =
      labelStart > 0 && isCredentialLabelQuote(scalars[labelStart - 1])
      ? labelStart - 1 : labelStart
    return tokenStart == 0 || !isIdentifierScalar(scalars[tokenStart - 1])
  }

  private static func isBearerValueScalar(_ scalar: UnicodeScalar) -> Bool {
    !CharacterSet.whitespacesAndNewlines.contains(scalar)
      && !isCredentialDelimiter(scalar) && !isExplicitValueTerminator(scalar)
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
      if quote != nil, afterIdentifier < scalars.count,
        isCredentialLabelQuote(scalars[afterIdentifier])
      {
        afterIdentifier += 1
      }

      let identifier = scalars[identifierStart..<identifierEnd]
      let whitespaceEnd = skipWhitespace(in: scalars, from: afterIdentifier)
      let hasDelimitedValue =
        whitespaceEnd < scalars.count && isCredentialDelimiter(scalars[whitespaceEnd])
      if whitespaceEnd > afterIdentifier, !hasDelimitedValue, isBearerIdentifier(identifier),
        let valueEnd = protectedValueEnd(in: scalars, from: whitespaceEnd)
      {
        output.append(contentsOf: string(from: scalars[cursor..<index]))
        output.append("bearer=<redacted>")
        cursor = valueEnd
        index = valueEnd
        continue
      }

      if let field = sensitiveField(in: scalars, from: index) {
        let valueStart = skipWhitespace(in: scalars, from: field.delimiter + 1)
        let protectsContinuation =
          isAuthorizationIdentifier(field.normalizedLabel)
          || isBearerIdentifier(field.normalizedLabel)
        let valueEnd =
          protectsContinuation
          ? protectedValueEnd(in: scalars, from: valueStart)
          : credentialValueEnd(in: scalars, from: valueStart)
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

  private static func protectedValueEnd(in scalars: [UnicodeScalar], from start: Int) -> Int? {
    guard start < scalars.count else { return nil }
    var end = start
    var quote: UnicodeScalar?
    var quoteAllowsEscapes = false
    var isAtValueBoundary = true
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
      if isExplicitValueTerminator(scalar) { break }
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        let nextField = skipWhitespace(in: scalars, from: end)
        if nextField < scalars.count,
          isQuote(scalars[nextField])
            || isUnicodeQuoteMarker(scalars[nextField])
        {
          end = nextField
          isAtValueBoundary = true
          continue
        }
        if let field = isSensitiveField(in: scalars, from: nextField) {
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

  private static func isSensitiveField(
    in scalars: [UnicodeScalar],
    from start: Int
  ) -> SensitiveField? {
    sensitiveField(in: scalars, from: start)
  }

  private static func sensitiveField(
    in scalars: [UnicodeScalar],
    from start: Int
  ) -> SensitiveField? {
    guard start < scalars.count else { return nil }
    let quote = isCredentialLabelQuote(scalars[start]) ? scalars[start] : nil
    let identifierStart = quote == nil ? start : start + 1
    guard identifierStart < scalars.count, isIdentifierScalar(scalars[identifierStart]) else {
      return nil
    }
    var identifierEnd = identifierStart
    while identifierEnd < scalars.count, isIdentifierScalar(scalars[identifierEnd]) {
      identifierEnd += 1
    }

    var words = [identifierStart..<identifierEnd]
    var afterWord = identifierEnd
    while true {
      let next = skipWhitespace(in: scalars, from: afterWord)
      let delimiter =
        if next < scalars.count, isCredentialLabelQuote(scalars[next]) {
          skipWhitespace(in: scalars, from: next + 1)
        } else {
          next
        }
      if delimiter < scalars.count, isCredentialDelimiter(scalars[delimiter]) {
        var normalized = ""
        for word in words.reversed() {
          normalized = normalizedIdentifier(scalars[word]) + normalized
          guard isSensitiveIdentifier(normalized) else { continue }
          return SensitiveField(
            replacementStart: quote == nil ? word.lowerBound : start,
            labelStart: quote == nil ? word.lowerBound : identifierStart,
            labelEnd: words.last!.upperBound,
            delimiter: delimiter,
            normalizedLabel: normalized
          )
        }
        return nil
      }
      guard words.count < maximumCredentialLabelWords, next > afterWord,
        next < scalars.count, isIdentifierScalar(scalars[next])
      else { return nil }
      var wordEnd = next
      while wordEnd < scalars.count, isIdentifierScalar(scalars[wordEnd]) { wordEnd += 1 }
      words.append(next..<wordEnd)
      afterWord = wordEnd
    }
  }

  private static func isSensitiveIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    isSensitiveIdentifier(normalizedIdentifier(identifier))
  }

  private static func isSensitiveIdentifier(_ normalized: String) -> Bool {
    return [
      "accesskey", "accesstoken", "refreshtoken", "clientsecret", "authtoken", "apikey",
      "authorization", "bearer", "password", "passwd", "token", "secret",
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
