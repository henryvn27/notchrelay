import Foundation

protocol HTTPDataTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPDataTransport: HTTPDataTransport {
  static let maximumResponseSize = 524_288

  private let session: URLSession

  init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 20
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ProviderCostServiceError.invalidResponse
    }
    guard response.expectedContentLength <= Self.maximumResponseSize else {
      bytes.task.cancel()
      throw ProviderCostServiceError.responseTooLarge
    }

    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(Int(response.expectedContentLength))
    }
    for try await byte in bytes {
      guard data.count < Self.maximumResponseSize else {
        bytes.task.cancel()
        throw ProviderCostServiceError.responseTooLarge
      }
      data.append(byte)
    }
    return (data, response)
  }
}

protocol ProviderCostFetching: Sendable {
  func fetchActualCosts(
    accountID: UUID,
    credential: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot
}

enum ProviderCostServiceError: LocalizedError, Equatable {
  case invalidCredential
  case invalidInterval
  case authenticationFailed
  case responseTooLarge
  case invalidResponse
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidCredential: "The admin credential is unreadable."
    case .invalidInterval: "The billing interval is invalid."
    case .authenticationFailed: "The provider rejected the admin credential."
    case .responseTooLarge: "The provider returned more billing data than Cowlick accepts."
    case .invalidResponse: "The provider returned unreadable billing data."
    case .unavailable: "Provider billing data is unavailable."
    }
  }
}

struct OpenAIAdminCostService: ProviderCostFetching {
  static let maximumResponseSize = 524_288
  static let maximumPages = 100

  private let transport: any HTTPDataTransport
  private let endpoint: URL
  private let now: @Sendable () -> Date

  init(
    transport: any HTTPDataTransport = URLSessionHTTPDataTransport(),
    endpoint: URL = URL(string: "https://api.openai.com/v1/organization/costs")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.endpoint = endpoint
    self.now = now
  }

  func fetchActualCosts(
    accountID: UUID,
    credential: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot {
    let credential = try decodedCredential(credential)
    try validate(interval)

    var total = Decimal.zero
    var currency: String?
    var page: String?
    var seenPages = Set<String>()

    for _ in 0..<Self.maximumPages {
      let request = try makeRequest(credential: credential, interval: interval, page: page)
      let data = try await responseData(for: request)
      let response: OpenAICostResponse
      do {
        response = try JSONDecoder().decode(OpenAICostResponse.self, from: data)
      } catch {
        throw ProviderCostServiceError.invalidResponse
      }

      for bucket in response.data {
        for result in bucket.results {
          guard isFinite(result.amount.value) else {
            throw ProviderCostServiceError.invalidResponse
          }
          let normalizedCurrency = try validatedCurrency(result.amount.currency)
          if let currency, currency != normalizedCurrency {
            throw ProviderCostServiceError.invalidResponse
          }
          currency = normalizedCurrency
          total += result.amount.value
        }
      }

      guard response.hasMore else {
        guard response.nextPage == nil else {
          throw ProviderCostServiceError.invalidResponse
        }
        return ActualBilledSnapshot(
          accountID: accountID,
          provider: .openAIAPI,
          amount: total,
          currency: currency ?? "USD",
          interval: interval,
          fetchedAt: now()
        )
      }
      guard let nextPage = response.nextPage, !nextPage.isEmpty else {
        throw ProviderCostServiceError.invalidResponse
      }
      guard seenPages.insert(nextPage).inserted else {
        throw ProviderCostServiceError.invalidResponse
      }
      page = nextPage
    }
    throw ProviderCostServiceError.invalidResponse
  }

  private func makeRequest(
    credential: String,
    interval: DateInterval,
    page: String?
  ) throws -> URLRequest {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw ProviderCostServiceError.invalidResponse
    }
    var queryItems = [
      URLQueryItem(name: "start_time", value: String(Int(interval.start.timeIntervalSince1970))),
      URLQueryItem(name: "end_time", value: String(Int(interval.end.timeIntervalSince1970))),
      URLQueryItem(name: "bucket_width", value: "1d"),
      URLQueryItem(name: "limit", value: "31"),
    ]
    if let page { queryItems.append(URLQueryItem(name: "page", value: page)) }
    components.queryItems = queryItems
    guard let url = components.url else { throw ProviderCostServiceError.invalidResponse }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 10
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Cowlick/\(ProductVersion.marketing)", forHTTPHeaderField: "User-Agent")
    return request
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    do {
      let (data, response) = try await transport.data(for: request)
      guard data.count <= Self.maximumResponseSize else {
        throw ProviderCostServiceError.responseTooLarge
      }
      if response.statusCode == 401 || response.statusCode == 403 {
        throw ProviderCostServiceError.authenticationFailed
      }
      guard response.statusCode == 200 else { throw ProviderCostServiceError.unavailable }
      return data
    } catch let error as ProviderCostServiceError {
      throw error
    } catch {
      throw ProviderCostServiceError.unavailable
    }
  }
}

struct AnthropicAdminCostService: ProviderCostFetching {
  static let maximumResponseSize = 524_288
  static let maximumPages = 100

  private let transport: any HTTPDataTransport
  private let endpoint: URL
  private let now: @Sendable () -> Date

  init(
    transport: any HTTPDataTransport = URLSessionHTTPDataTransport(),
    endpoint: URL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.endpoint = endpoint
    self.now = now
  }

  func fetchActualCosts(
    accountID: UUID,
    credential: Data,
    interval: DateInterval
  ) async throws -> ActualBilledSnapshot {
    let credential = try decodedCredential(credential)
    try validate(interval)

    var totalInLowestUnits = Decimal.zero
    var currency: String?
    var page: String?
    var seenPages = Set<String>()

    for _ in 0..<Self.maximumPages {
      let request = try makeRequest(credential: credential, interval: interval, page: page)
      let data = try await responseData(for: request)
      let response: AnthropicCostResponse
      do {
        response = try JSONDecoder().decode(AnthropicCostResponse.self, from: data)
      } catch {
        throw ProviderCostServiceError.invalidResponse
      }

      for bucket in response.data {
        for result in bucket.results {
          guard
            let amount = Decimal(
              string: result.amount, locale: Locale(identifier: "en_US_POSIX")),
            isFinite(amount)
          else { throw ProviderCostServiceError.invalidResponse }
          let normalizedCurrency = try validatedCurrency(result.currency)
          if let currency, currency != normalizedCurrency {
            throw ProviderCostServiceError.invalidResponse
          }
          currency = normalizedCurrency
          totalInLowestUnits += amount
        }
      }

      guard response.hasMore else {
        return ActualBilledSnapshot(
          accountID: accountID,
          provider: .anthropicAPI,
          amount: totalInLowestUnits / 100,
          currency: currency ?? "USD",
          interval: interval,
          fetchedAt: now()
        )
      }
      guard let nextPage = response.nextPage, !nextPage.isEmpty,
        seenPages.insert(nextPage).inserted
      else { throw ProviderCostServiceError.invalidResponse }
      page = nextPage
    }
    throw ProviderCostServiceError.invalidResponse
  }

  private func makeRequest(
    credential: String,
    interval: DateInterval,
    page: String?
  ) throws -> URLRequest {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw ProviderCostServiceError.invalidResponse
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var queryItems = [
      URLQueryItem(name: "starting_at", value: formatter.string(from: interval.start)),
      URLQueryItem(name: "ending_at", value: formatter.string(from: interval.end)),
      URLQueryItem(name: "bucket_width", value: "1d"),
      URLQueryItem(name: "limit", value: "31"),
    ]
    if let page { queryItems.append(URLQueryItem(name: "page", value: page)) }
    components.queryItems = queryItems
    guard let url = components.url else { throw ProviderCostServiceError.invalidResponse }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 10
    request.setValue(credential, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Cowlick/\(ProductVersion.marketing)", forHTTPHeaderField: "User-Agent")
    return request
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    do {
      let (data, response) = try await transport.data(for: request)
      guard data.count <= Self.maximumResponseSize else {
        throw ProviderCostServiceError.responseTooLarge
      }
      if response.statusCode == 401 || response.statusCode == 403 {
        throw ProviderCostServiceError.authenticationFailed
      }
      guard response.statusCode == 200 else { throw ProviderCostServiceError.unavailable }
      return data
    } catch let error as ProviderCostServiceError {
      throw error
    } catch {
      throw ProviderCostServiceError.unavailable
    }
  }
}

private struct OpenAICostResponse: Decodable {
  let data: [Bucket]
  let hasMore: Bool
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }

  struct Bucket: Decodable {
    let results: [Result]
  }

  struct Result: Decodable {
    let amount: Amount
  }

  struct Amount: Decodable {
    let value: Decimal
    let currency: String
  }
}

private struct AnthropicCostResponse: Decodable {
  let data: [Bucket]
  let hasMore: Bool
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }

  struct Bucket: Decodable {
    let results: [Result]
  }

  struct Result: Decodable {
    let amount: String
    let currency: String
  }
}

private func decodedCredential(_ data: Data) throws -> String {
  guard
    let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines),
    !value.isEmpty
  else { throw ProviderCostServiceError.invalidCredential }
  return value
}

private func validate(_ interval: DateInterval) throws {
  guard interval.start.timeIntervalSince1970.isFinite,
    interval.end.timeIntervalSince1970.isFinite,
    interval.duration > 0
  else { throw ProviderCostServiceError.invalidInterval }
}

private func validatedCurrency(_ value: String) throws -> String {
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  guard (3...8).contains(normalized.count), normalized.allSatisfy(\.isLetter) else {
    throw ProviderCostServiceError.invalidResponse
  }
  return normalized
}

private func isFinite(_ value: Decimal) -> Bool {
  NSDecimalNumber(decimal: value).doubleValue.isFinite
}
