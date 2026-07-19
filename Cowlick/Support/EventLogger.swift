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

  private static let maximumInputScalars = 4_096
  private static let maximumScannedInputScalars = maximumInputScalars * 4
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
    let canonical = removingUnsafeCharacters(from: value)
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
          && nextScalar(in: value, atUTF16Offset: matchEnd).map({ !isHomeBoundary($0) }) == true
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
      || nextScalar(in: value, atUTF16Offset: offset).map(isHomeBoundary) ?? true
  }

  private static func nextScalar(in value: String, atUTF16Offset offset: Int) -> UnicodeScalar? {
    let index = String.Index(utf16Offset: offset, in: value)
    return index < value.endIndex ? value[index...].unicodeScalars.first : nil
  }

  private static func isHomeBoundary(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x2F
      || CharacterSet.whitespacesAndNewlines.contains(scalar)
      || CharacterSet.punctuationCharacters.contains(scalar)
  }

  private static func redactCredentials(in value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var output = ""
    var cursor = 0
    var index = 0

    while index < scalars.count {
      let quote = isQuote(scalars[index]) ? scalars[index] : nil
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
      if let quote, afterIdentifier < scalars.count, scalars[afterIdentifier] == quote {
        afterIdentifier += 1
      }

      let whitespaceEnd = skipWhitespace(in: scalars, from: afterIdentifier)
      let identifier = scalars[identifierStart..<identifierEnd]
      if whitespaceEnd < scalars.count, isCredentialDelimiter(scalars[whitespaceEnd]),
        isSensitiveIdentifier(identifier)
      {
        let valueStart = skipWhitespace(in: scalars, from: whitespaceEnd + 1)
        let protectsContinuation =
          isAuthorizationIdentifier(identifier) || isBearerIdentifier(identifier)
        let valueEnd =
          protectsContinuation
          ? protectedValueEnd(in: scalars, from: valueStart)
          : credentialValueEnd(in: scalars, from: valueStart)
        if let valueEnd {
          output.append(contentsOf: string(from: scalars[cursor..<index]))
          output.append(
            contentsOf: isAuthorizationIdentifier(identifier)
              ? "authorization" : string(from: identifier))
          output.append("=<redacted>")
          cursor = valueEnd
          index = valueEnd
          continue
        }
      } else if whitespaceEnd > afterIdentifier, isBearerIdentifier(identifier),
        let valueEnd = protectedValueEnd(in: scalars, from: whitespaceEnd)
      {
        output.append(contentsOf: string(from: scalars[cursor..<index]))
        output.append("bearer=<redacted>")
        cursor = valueEnd
        index = valueEnd
        continue
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
        if scalars[end] == quote { return end + 1 }
        end += scalars[end].value == 0x5C && end + 1 < scalars.count ? 2 : 1
      }
      return scalars.count
    }

    var end = start
    while end < scalars.count, !isValueTerminator(scalars[end]) { end += 1 }
    return end > start ? end : nil
  }

  private static func protectedValueEnd(in scalars: [UnicodeScalar], from start: Int) -> Int? {
    guard start < scalars.count else { return nil }
    var end = start
    var quote: UnicodeScalar?
    while end < scalars.count {
      let scalar = scalars[end]
      if let activeQuote = quote {
        if scalar.value == 0x5C, end + 1 < scalars.count {
          end += 2
          continue
        }
        if scalar == activeQuote { quote = nil }
        end += 1
        continue
      }
      if isQuote(scalar) {
        quote = scalar
        end += 1
        continue
      }
      if isExplicitValueTerminator(scalar) { break }
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        let nextField = skipWhitespace(in: scalars, from: end)
        if isSensitiveField(in: scalars, from: nextField) { break }
        end = nextField
        continue
      }
      end += 1
    }
    return end > start ? end : nil
  }

  private static func isSensitiveField(in scalars: [UnicodeScalar], from start: Int) -> Bool {
    guard start < scalars.count else { return false }
    let quote = isQuote(scalars[start]) ? scalars[start] : nil
    let identifierStart = quote == nil ? start : start + 1
    guard identifierStart < scalars.count, isIdentifierScalar(scalars[identifierStart]) else {
      return false
    }
    var identifierEnd = identifierStart
    while identifierEnd < scalars.count, isIdentifierScalar(scalars[identifierEnd]) {
      identifierEnd += 1
    }
    var afterIdentifier = identifierEnd
    if let quote, afterIdentifier < scalars.count, scalars[afterIdentifier] == quote {
      afterIdentifier += 1
    }
    let delimiter = skipWhitespace(in: scalars, from: afterIdentifier)
    return delimiter < scalars.count && isCredentialDelimiter(scalars[delimiter])
      && isSensitiveIdentifier(scalars[identifierStart..<identifierEnd])
  }

  private static func isSensitiveIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    let normalized = normalizedIdentifier(identifier)
    return [
      "accesstoken", "refreshtoken", "clientsecret", "authtoken", "apikey",
      "authorization", "bearer", "password", "passwd", "token", "secret",
    ].contains { normalized.contains($0) }
  }

  private static func isAuthorizationIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    normalizedIdentifier(identifier).contains("authorization")
  }

  private static func isBearerIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> Bool {
    normalizedIdentifier(identifier).contains("bearer")
  }

  private static func normalizedIdentifier(_ identifier: ArraySlice<UnicodeScalar>) -> String {
    var normalized = ""
    for scalar in identifier where scalar.value != 0x2D && scalar.value != 0x5F {
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
      || value == 0x2D || value == 0x5F
  }

  private static func isQuote(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x22 || scalar.value == 0x27
  }

  private static func isCredentialDelimiter(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x3A || scalar.value == 0x3D
  }

  private static func isValueTerminator(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.whitespacesAndNewlines.contains(scalar)
      || scalar.value == 0x2C || scalar.value == 0x3B
  }

  private static func isExplicitValueTerminator(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x2C || scalar.value == 0x3B
  }
}
