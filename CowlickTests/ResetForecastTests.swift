import Foundation
import XCTest

@testable import Cowlick

final class ResetForecastTests: XCTestCase {
  func testParsesOnlyDisplayFields() throws {
    let data = Data(
      #"{"fetchedAt":"2026-07-18T12:00:00.123Z","nextRefreshAt":"2026-07-18T12:15:00Z","forecast":{"score":95,"resetAnnounced":false},"incidents":[{"private":"ignored"}],"history":[1,2,3]}"#
        .utf8)

    let forecast = try ResetForecastService.parseResponse(data)

    XCTAssertEqual(forecast.score, 95)
    XCTAssertFalse(forecast.resetAnnounced)
    XCTAssertNotNil(forecast.fetchedAt)
    XCTAssertNotNil(forecast.nextRefreshAt)
    XCTAssertEqual(forecast.scoreLabel, "95% in the next 48 hours")
  }

  func testClampsThirdPartyScore() throws {
    let data = Data(#"{"forecast":{"score":410,"resetAnnounced":true}}"#.utf8)
    let forecast = try ResetForecastService.parseResponse(data)
    XCTAssertEqual(forecast.score, 100)
    XCTAssertEqual(forecast.scoreLabel, "100% in the next 48 hours")
  }

  func testRejectsMalformedForecast() {
    XCTAssertThrowsError(
      try ResetForecastService.parseResponse(Data(#"{"forecast":{"score":"high"}}"#.utf8)))
  }

  func testResponseLimitIsHalfMegabyte() {
    XCTAssertEqual(ResetForecastService.maximumResponseSize, 524_288)
  }

  func testFetchForecastStreamsNormalResponse() async throws {
    ForecastStreamingURLProtocol.configure(
      .body(Data(#"{"forecast":{"score":72,"resetAnnounced":false}}"#.utf8)))
    defer { ForecastStreamingURLProtocol.reset() }
    let session = makeForecastSession()
    defer { session.invalidateAndCancel() }
    let service = ResetForecastService(
      session: session, endpoint: URL(string: "https://cowlick.invalid/forecast")!)

    let forecast = try await service.fetchForecast()

    XCTAssertEqual(forecast.score, 72)
  }

  func testHTTP503MapsToSourceAPIUnavailableWithoutResponseBody() async {
    ForecastStreamingURLProtocol.configure(
      .body(Data(#"secret upstream diagnostic"#.utf8)),
      statusCode: 503
    )
    defer { ForecastStreamingURLProtocol.reset() }
    let session = makeForecastSession()
    defer { session.invalidateAndCancel() }
    let service = ResetForecastService(
      session: session, endpoint: URL(string: "https://cowlick.invalid/forecast")!)

    do {
      _ = try await service.fetchForecast()
      XCTFail("Expected unavailable source API to fail")
    } catch {
      XCTAssertEqual(error as? ResetForecastServiceError, .unavailable)
      XCTAssertEqual(
        error.localizedDescription,
        "The Will Codex Reset? source API is unavailable."
      )
      XCTAssertFalse(error.localizedDescription.contains("secret upstream diagnostic"))
    }
  }

  func testFetchForecastCancelsKnownOversizedResponseFromHeader() async {
    let cancelled = expectation(description: "Known oversized forecast task cancelled")
    ForecastStreamingURLProtocol.configure(
      .endless(Data(repeating: 0x20, count: 65_536)),
      expectedContentLength: Int64(ResetForecastService.maximumResponseSize + 1),
      onStop: { cancelled.fulfill() }
    )
    defer { ForecastStreamingURLProtocol.reset() }
    let session = makeForecastSession()
    let service = ResetForecastService(
      session: session, endpoint: URL(string: "https://cowlick.invalid/forecast")!)

    do {
      _ = try await service.fetchForecast()
      XCTFail("Expected known oversized output to fail")
    } catch {
      XCTAssertEqual(error as? ResetForecastServiceError, .responseTooLarge)
    }
    await fulfillment(of: [cancelled], timeout: 1)
    session.invalidateAndCancel()
  }

  func testFetchForecastCancelsUnknownLengthOversizedStreamAtBound() async {
    let cancelled = expectation(description: "Oversized forecast task cancelled")
    ForecastStreamingURLProtocol.configure(
      .endless(Data(repeating: 0x20, count: 65_536)),
      onStop: { cancelled.fulfill() }
    )
    defer { ForecastStreamingURLProtocol.reset() }
    let session = makeForecastSession()
    let service = ResetForecastService(
      session: session, endpoint: URL(string: "https://cowlick.invalid/forecast")!)

    do {
      _ = try await service.fetchForecast()
      XCTFail("Expected oversized output to fail")
    } catch {
      XCTAssertEqual(error as? ResetForecastServiceError, .responseTooLarge)
    }
    await fulfillment(of: [cancelled], timeout: 1)
    session.invalidateAndCancel()
  }

  private func makeForecastSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForecastStreamingURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class ForecastStreamingURLProtocol: URLProtocol, @unchecked Sendable {
  enum Payload: Sendable {
    case body(Data)
    case endless(Data)
  }

  private static let configurationLock = NSLock()
  nonisolated(unsafe) private static var payload = Payload.body(Data())
  nonisolated(unsafe) private static var expectedContentLength: Int64?
  nonisolated(unsafe) private static var statusCode = 200
  nonisolated(unsafe) private static var stopHandler: (() -> Void)?

  private let stateLock = NSLock()
  private var stopped = false

  static func configure(
    _ payload: Payload,
    expectedContentLength: Int64? = nil,
    statusCode: Int = 200,
    onStop: (() -> Void)? = nil
  ) {
    configurationLock.lock()
    self.payload = payload
    self.expectedContentLength = expectedContentLength
    self.statusCode = statusCode
    stopHandler = onStop
    configurationLock.unlock()
  }

  static func reset() {
    configure(.body(Data()))
  }

  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.configurationLock.lock()
    let payload = Self.payload
    let expectedContentLength = Self.expectedContentLength
    let statusCode = Self.statusCode
    Self.configurationLock.unlock()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
      headerFields: expectedContentLength.map { ["Content-Length": String($0)] }
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    switch payload {
    case .body(let data):
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .endless(let chunk):
      DispatchQueue.global(qos: .utility).async { [self] in
        while !isStopped {
          client?.urlProtocol(self, didLoad: chunk)
          Thread.sleep(forTimeInterval: 0.001)
        }
      }
    }
  }

  override func stopLoading() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()

    Self.configurationLock.lock()
    let stopHandler = Self.stopHandler
    Self.configurationLock.unlock()
    stopHandler?()
  }

  private var isStopped: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return stopped
  }
}
