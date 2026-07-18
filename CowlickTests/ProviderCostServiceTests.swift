import Foundation
import XCTest

@testable import Cowlick

final class ProviderCostServiceTests: XCTestCase {
  func testOpenAIDecodesAndPaginatesActualCostsWithAdminAuthorization() async throws {
    let transport = ScriptedHTTPTransport([
      .init(
        status: 200,
        data: Data(
          #"{"data":[{"results":[{"amount":{"value":1.25,"currency":"usd"}}]}],"has_more":true,"next_page":"next"}"#
            .utf8)),
      .init(
        status: 200,
        data: Data(
          #"{"data":[{"results":[{"amount":{"value":2.50,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
            .utf8)),
    ])
    let interval = testInterval
    let accountID = UUID()
    let service = OpenAIAdminCostService(
      transport: transport, now: { Date(timeIntervalSince1970: 1_800_000_000) })

    let snapshot = try await service.fetchActualCosts(
      accountID: accountID, credential: Data("openai-admin".utf8), interval: interval)
    let requests = await transport.requests

    XCTAssertEqual(snapshot.accountID, accountID)
    XCTAssertEqual(snapshot.provider, .openAIAPI)
    XCTAssertEqual(snapshot.amount, Decimal(string: "3.75"))
    XCTAssertEqual(snapshot.currency, "USD")
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(
      requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer openai-admin")
    XCTAssertEqual(query(requests.first, "bucket_width"), "1d")
    XCTAssertEqual(query(requests.last, "page"), "next")
  }

  func testAnthropicConvertsLowestCurrencyUnitsAndUsesDocumentedAdminHeaders() async throws {
    let transport = ScriptedHTTPTransport([
      .init(
        status: 200,
        data: Data(
          #"{"data":[{"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[{"amount":"123.45","currency":"USD"}]}],"has_more":false,"next_page":null}"#
            .utf8))
    ])
    let service = AnthropicAdminCostService(transport: transport)

    let snapshot = try await service.fetchActualCosts(
      accountID: UUID(), credential: Data("anthropic-admin".utf8), interval: testInterval)
    let request = await transport.requests.first

    XCTAssertEqual(snapshot.provider, .anthropicAPI)
    XCTAssertEqual(snapshot.amount, Decimal(string: "1.2345"))
    XCTAssertEqual(snapshot.currency, "USD")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "anthropic-admin")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    XCTAssertEqual(query(request, "bucket_width"), "1d")
    XCTAssertNotNil(query(request, "starting_at"))
    XCTAssertNotNil(query(request, "ending_at"))
  }

  func testRejectsMalformedAndOversizedResponses() async throws {
    let malformed = ScriptedHTTPTransport([.init(status: 200, data: Data("not-json".utf8))])
    let oversized = ScriptedHTTPTransport([
      .init(
        status: 200,
        data: Data(repeating: 0x20, count: OpenAIAdminCostService.maximumResponseSize + 1))
    ])

    await assertProviderError(.invalidResponse) {
      _ = try await OpenAIAdminCostService(transport: malformed).fetchActualCosts(
        accountID: UUID(), credential: Data("key".utf8), interval: self.testInterval)
    }
    await assertProviderError(.responseTooLarge) {
      _ = try await OpenAIAdminCostService(transport: oversized).fetchActualCosts(
        accountID: UUID(), credential: Data("key".utf8), interval: self.testInterval)
    }
  }

  func testOpenAIRejectsTruncatedAndInconsistentPaginationState() async {
    let responses = [
      #"{"data":[],"next_page":null}"#,
      #"{"data":[],"has_more":true,"next_page":null}"#,
      #"{"data":[],"has_more":true,"next_page":""}"#,
      #"{"data":[],"has_more":false,"next_page":"unexpected"}"#,
    ]

    for body in responses {
      let transport = ScriptedHTTPTransport([.init(status: 200, data: Data(body.utf8))])
      await assertProviderError(.invalidResponse) {
        _ = try await OpenAIAdminCostService(transport: transport).fetchActualCosts(
          accountID: UUID(), credential: Data("key".utf8), interval: self.testInterval)
      }
    }
  }

  func testURLSessionTransportStopsStreamingOversizedBody() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OversizedBodyURLProtocol.self]
    let transport = URLSessionHTTPDataTransport(configuration: configuration)

    await assertProviderError(.responseTooLarge) {
      _ = try await transport.data(for: URLRequest(url: URL(string: "https://cowlick.invalid")!))
    }
  }

  func testMapsAuthenticationAndTransportFailuresToSanitizedErrors() async {
    let unauthorized = ScriptedHTTPTransport([.init(status: 401, data: Data("private body".utf8))])
    let failed = ScriptedHTTPTransport([], failure: URLError(.cannotConnectToHost))

    await assertProviderError(.authenticationFailed) {
      _ = try await AnthropicAdminCostService(transport: unauthorized).fetchActualCosts(
        accountID: UUID(), credential: Data("key".utf8), interval: self.testInterval)
    }
    await assertProviderError(.unavailable) {
      _ = try await AnthropicAdminCostService(transport: failed).fetchActualCosts(
        accountID: UUID(), credential: Data("key".utf8), interval: self.testInterval)
    }
  }

  func testResponseLimitsAreBounded() {
    XCTAssertEqual(URLSessionHTTPDataTransport.maximumResponseSize, 524_288)
    XCTAssertEqual(OpenAIAdminCostService.maximumResponseSize, 524_288)
    XCTAssertEqual(AnthropicAdminCostService.maximumResponseSize, 524_288)
  }

  private var testInterval: DateInterval {
    DateInterval(
      start: Date(timeIntervalSince1970: 1_780_000_000),
      end: Date(timeIntervalSince1970: 1_780_086_400))
  }

  private func query(_ request: URLRequest?, _ name: String) -> String? {
    guard let url = request?.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    return components.queryItems?.first(where: { $0.name == name })?.value
  }

  private func assertProviderError(
    _ expected: ProviderCostServiceError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch let error as ProviderCostServiceError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private final class OversizedBodyURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: Data(repeating: 0x20, count: URLSessionHTTPDataTransport.maximumResponseSize + 1)
    )
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private actor ScriptedHTTPTransport: HTTPDataTransport {
  struct Response: Sendable {
    let status: Int
    let data: Data
  }

  private var responses: [Response]
  private let failure: URLError?
  private(set) var requests: [URLRequest] = []

  init(_ responses: [Response], failure: URLError? = nil) {
    self.responses = responses
    self.failure = failure
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if let failure { throw failure }
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    let next = responses.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: nil)!
    return (next.data, response)
  }
}
