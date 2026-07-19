import Darwin
import XCTest

@testable import Cowlick

final class CodexHookTrustServiceTests: XCTestCase {
  private let cwd = "/Users/test/Developer/Cowlick"
  private let command = "'/Users/test/.local/bin/cowlick-hook' hook"

  func testReportsTrustedWhenAllCowlickHooksAreTrusted() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "managed", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .trusted)
    XCTAssertEqual(report.eventStatuses.count, 4)
  }

  func testReportsReviewRequiredForUntrustedHook() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "untrusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .needsReview)
  }

  func testReportsIncompleteWhenHookIsMissing() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: command
    )

    XCTAssertEqual(report.state, .incomplete)
  }

  func testIgnoresForeignHookCommands() throws {
    let report = try CodexHookTrustService.parseResponse(
      response(statuses: ["trusted", "trusted", "trusted", "trusted"]),
      workingDirectory: cwd,
      expectedCommand: "'/usr/local/bin/other-hook' hook"
    )

    XCTAssertEqual(report.state, .incomplete)
    XCTAssertTrue(report.eventStatuses.isEmpty)
  }

  func testRejectsMalformedResponse() {
    XCTAssertThrowsError(
      try CodexHookTrustService.parseResponse(
        Data(#"{"id":7,"result":{}}"#.utf8),
        workingDirectory: cwd,
        expectedCommand: command
      ))
  }

  func testProbeCompletesNormalHandshakeWithBoundedRunner() async throws {
    let hooks = ["sessionStart", "userPromptSubmit", "permissionRequest", "stop"]
      .map {
        "{\"eventName\":\"\($0)\",\"command\":\"\(command)\",\"enabled\":true,\"trustStatus\":\"trusted\"}"
      }
      .joined(separator: ",")
    let fixture = try ExecutableFixture(
      script: """
        #!/bin/sh
        IFS= read -r initialize || exit 3
        case "$initialize" in *'"id":0'*) ;; *) exit 3 ;; esac
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 3 ;; esac
        printf '%s\n' '{"id":0,"result":{}}'
        IFS= read -r initialized || exit 3
        case "$initialized" in
          *'"method":"initialized"'*) ;;
          *) exit 3 ;;
        esac
        IFS= read -r request || exit 3
        case "$request" in *'"id":2'*) ;; *) exit 3 ;; esac
        case "$request" in
          *'"method":"hooks/list"'*|*'"method":"hooks\\/list"'*) ;;
          *) exit 3 ;;
        esac
        cat <<'COWLICK_RESPONSES'
        {"id":2,"result":{"data":[{"cwd":"\(cwd)","hooks":[\(hooks)]}]}}
        COWLICK_RESPONSES
        while IFS= read -r _; do :; done
        """)
    defer { fixture.remove() }
    let service = CodexHookTrustService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      homeDirectory: URL(fileURLWithPath: "/Users/test")
    )

    let report = await service.inspect(workingDirectory: cwd)

    XCTAssertEqual(report.state, .trusted)
  }

  func testProbeSanitizesOversizedStreamingOutput() async throws {
    let fixture = try ExecutableFixture(script: "#!/bin/sh\nexec /usr/bin/yes malicious\n")
    defer { fixture.remove() }
    let service = CodexHookTrustService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      homeDirectory: URL(fileURLWithPath: "/Users/test")
    )

    let report = await service.inspect(workingDirectory: cwd)

    XCTAssertEqual(
      report.state,
      .unavailable(CodexHookTrustServiceError.responseTooLarge.localizedDescription)
    )
  }

  func testProbeMapsEarlyAndNonzeroExitToProcessFailed() async throws {
    for status in [0, 7] {
      let fixture = try ExecutableFixture(script: "#!/bin/sh\nexit \(status)\n")
      defer { fixture.remove() }
      let service = CodexHookTrustService(
        locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
        homeDirectory: URL(fileURLWithPath: "/Users/test")
      )

      let report = await service.inspect(workingDirectory: cwd)

      XCTAssertEqual(
        report.state,
        .unavailable(CodexHookTrustServiceError.processFailed.localizedDescription)
      )
    }
  }

  func testProbeTimeoutMapsToProcessFailedWithinBound() async throws {
    let fixture = try ExecutableFixture(
      script: "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n")
    defer { fixture.remove() }
    let service = CodexHookTrustService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      timeout: 0.05
    )
    let startedAt = Date()

    let report = await service.inspect(workingDirectory: cwd)

    XCTAssertEqual(
      report.state,
      .unavailable(CodexHookTrustServiceError.processFailed.localizedDescription)
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  func testCancellationKillsHookProbeProcessGroup() async throws {
    let parentPIDURL = temporaryURL("hook-parent")
    let descendantPIDURL = temporaryURL("hook-descendant")
    let fixture = try ExecutableFixture(
      script: stubbornProcessTreeScript(
        parentPID: parentPIDURL, descendantPID: descendantPIDURL))
    defer {
      fixture.remove()
      try? FileManager.default.removeItem(at: parentPIDURL)
      try? FileManager.default.removeItem(at: descendantPIDURL)
    }
    let service = CodexHookTrustService(
      locator: CodexExecutableLocator(candidates: [fixture.url], validator: { _ in true }),
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      timeout: 5
    )
    let workingDirectory = cwd
    let task = Task { await service.inspect(workingDirectory: workingDirectory) }
    guard let parentPID = await waitForProcessID(at: parentPIDURL),
      let descendantPID = await waitForProcessID(at: descendantPIDURL)
    else {
      task.cancel()
      return XCTFail("Expected hook probe process tree to start")
    }
    defer {
      Darwin.kill(parentPID, SIGKILL)
      Darwin.kill(descendantPID, SIGKILL)
    }
    let startedAt = Date()

    task.cancel()
    let report = await task.value

    if case .unavailable = report.state {
    } else {
      XCTFail("Expected cancellation to report unavailable")
    }
    let processTreeExited = await waitForProcessesToExit([parentPID, descendantPID])
    XCTAssertTrue(processTreeExited)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  private func response(statuses: [String]) -> Data {
    let events = ["sessionStart", "userPromptSubmit", "permissionRequest", "stop"]
    let hooks = zip(events, statuses).map { event, status in
      """
      {"eventName":"\(event)","command":"\(command)","enabled":true,"trustStatus":"\(status)"}
      """
    }.joined(separator: ",")
    return Data(
      """
      {"id":2,"result":{"data":[{"cwd":"\(cwd)","hooks":[\(hooks)]}]}}
      """.utf8)
  }

  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-\(name)-\(UUID().uuidString)")
  }
}
