import Foundation

protocol ResetForecastFetching: Sendable {
  func fetchForecast() async throws -> ResetForecast
}

enum ResetForecastServiceError: LocalizedError, Equatable {
  case invalidResponse
  case responseTooLarge
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The third-party forecast returned unreadable data."
    case .responseTooLarge: "The third-party forecast response exceeded Cowlick's limit."
    case .unavailable: "The Will Codex Reset? source API is unavailable."
    }
  }
}

struct ResetForecastService: ResetForecastFetching, @unchecked Sendable {
  static let maximumResponseSize = 524_288

  private let session: URLSession
  private let endpoint: URL

  init(
    session: URLSession = URLSession(configuration: .ephemeral),
    endpoint: URL = ResetForecast.endpointURL
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  func fetchForecast() async throws -> ResetForecast {
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Cowlick/\(ProductVersion.marketing)", forHTTPHeaderField: "User-Agent")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      bytes.task.cancel()
      throw ResetForecastServiceError.unavailable
    }
    let expectedContentLength = http.expectedContentLength
    guard expectedContentLength < 0 || expectedContentLength <= Int64(Self.maximumResponseSize)
    else {
      bytes.task.cancel()
      throw ResetForecastServiceError.responseTooLarge
    }

    var data = Data()
    if expectedContentLength > 0, let capacity = Int(exactly: expectedContentLength) {
      data.reserveCapacity(capacity)
    }
    for try await byte in bytes {
      guard data.count < Self.maximumResponseSize else {
        bytes.task.cancel()
        throw ResetForecastServiceError.responseTooLarge
      }
      data.append(byte)
    }
    return try Self.parseResponse(data)
  }

  static func parseResponse(_ data: Data) throws -> ResetForecast {
    guard let envelope = try? JSONDecoder().decode(ForecastEnvelope.self, from: data) else {
      throw ResetForecastServiceError.invalidResponse
    }
    return ResetForecast(
      score: min(max(envelope.forecast.score, 0), 100),
      resetAnnounced: envelope.forecast.resetAnnounced,
      fetchedAt: parseDate(envelope.fetchedAt),
      nextRefreshAt: parseDate(envelope.nextRefreshAt)
    )
  }

  private static func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

private struct ForecastEnvelope: Decodable {
  let fetchedAt: String?
  let nextRefreshAt: String?
  let forecast: ForecastPayload
}

private struct ForecastPayload: Decodable {
  let score: Double
  let resetAnnounced: Bool
}
