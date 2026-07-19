import Darwin
import XCTest

@testable import Cowlick

final class IntegrationSelfTestServiceTests: XCTestCase {
  func testPingAndDemoUseInstalledHelperProtocol() async throws {
    let fixture = try HelperFixture()
    defer { fixture.remove() }
    let service = IntegrationSelfTestService(helperURL: fixture.url)

    try await service.ping()
    try await service.sendDemo(.working, sessionID: "self-test-session")
    try await service.sendDemo(.completed, sessionID: "self-test-session")
  }

  func testMissingHelperFailsWithoutPretendingSuccess() async {
    let service = IntegrationSelfTestService(
      helperURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-cowlick-helper-\(UUID().uuidString)"))

    do {
      try await service.ping()
      XCTFail("Expected the unavailable helper to fail")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .helperUnavailable)
    }
  }

  func testMalformedHelperResponseFailsClosed() async throws {
    let fixture = try HelperFixture(response: "not-json")
    defer { fixture.remove() }
    let service = IntegrationSelfTestService(helperURL: fixture.url)

    do {
      try await service.ping()
      XCTFail("Expected malformed output to fail")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .malformedResponse)
    }
  }

  func testHelperExitingWithoutOutputPreservesMalformedResponse() async throws {
    let fixture = try HelperFixture(script: "#!/bin/sh\nexit 0\n")
    defer { fixture.remove() }

    do {
      try await IntegrationSelfTestService(helperURL: fixture.url).ping()
      XCTFail("Expected empty output to fail")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .malformedResponse)
    }
  }

  func testNonzeroHelperExitPreservesProcessStatus() async throws {
    let fixture = try HelperFixture(script: "#!/bin/sh\nexit 7\n")
    defer { fixture.remove() }

    do {
      try await IntegrationSelfTestService(helperURL: fixture.url).ping()
      XCTFail("Expected nonzero exit to fail")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .processFailed(7))
    }
  }

  func testOversizedResponseFailsAtBoundWhileHelperIsRunning() async throws {
    let fixture = try HelperFixture(
      script: "#!/bin/sh\ndd if=/dev/zero bs=1048577 count=1 2>/dev/null\n")
    defer { fixture.remove() }
    let service = IntegrationSelfTestService(helperURL: fixture.url, timeout: 2)

    do {
      try await service.ping()
      XCTFail("Expected oversized output to fail")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .responseTooLarge)
    }
  }

  func testRetainedOutputPipeCannotOutliveTimeout() async throws {
    let fixture = try HelperFixture(
      script: "#!/bin/sh\n(sleep 1) &\nprintf '%s' '{\"ok\":true}'\n")
    defer { fixture.remove() }
    let service = IntegrationSelfTestService(helperURL: fixture.url, timeout: 0.1)

    do {
      try await service.ping()
      XCTFail("Expected inherited output pipe to time out")
    } catch {
      XCTAssertEqual(error as? IntegrationSelfTestError, .timedOut)
    }
  }

  func testCancellationKillsHelperProcessGroupPromptly() async throws {
    let parentPIDURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-helper-parent-\(UUID().uuidString)")
    let descendantPIDURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-helper-descendant-\(UUID().uuidString)")
    let fixture = try HelperFixture(
      script: stubbornProcessTreeScript(
        parentPID: parentPIDURL, descendantPID: descendantPIDURL))
    defer {
      fixture.remove()
      try? FileManager.default.removeItem(at: parentPIDURL)
      try? FileManager.default.removeItem(at: descendantPIDURL)
    }
    let task = Task {
      try await IntegrationSelfTestService(helperURL: fixture.url, timeout: 5).ping()
    }
    guard let parentPID = await waitForProcessID(at: parentPIDURL),
      let descendantPID = await waitForProcessID(at: descendantPIDURL)
    else {
      task.cancel()
      return XCTFail("Expected helper process tree to start")
    }
    defer {
      Darwin.kill(parentPID, SIGKILL)
      Darwin.kill(descendantPID, SIGKILL)
    }
    let startedAt = Date()

    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let processTreeExited = await waitForProcessesToExit([parentPID, descendantPID])
    XCTAssertTrue(processTreeExited)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  private struct HelperFixture {
    let url: URL

    init(response: String? = nil, script customScript: String? = nil) throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cowlick-helper-fixture-\(UUID().uuidString)")
      let script: String
      if let customScript {
        script = customScript
      } else if let response {
        script = "#!/bin/sh\nprintf '%s' '\(response)'\n"
      } else {
        script = """
          #!/bin/sh
          if [ "$1" = "ping" ]; then
            printf '%s' '{"ok":true}'
          elif [ "$1" = "demo" ] && [ "$COWLICK_DEMO_SESSION_ID" = "self-test-session" ] && { [ "$2" = "working" ] || [ "$2" = "completed" ]; }; then
            printf '%s' '{"sent":true}'
          else
            exit 2
          fi
          """
      }
      try Data(script.utf8).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func remove() {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

final class BoundedProcessRunnerTests: XCTestCase {
  func testClosedParentStandardOutputCannotRouteChildErrorIntoProtocol() throws {
    let fixture = try ExecutableFixture(
      script: "#!/bin/sh\nprintf protocol\nprintf noise >&2\n")
    defer { fixture.remove() }
    let savedStandardOutput = Darwin.fcntl(
      STDOUT_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    XCTAssertGreaterThanOrEqual(savedStandardOutput, STDERR_FILENO + 1)
    guard savedStandardOutput >= 0 else { return }
    XCTAssertEqual(Darwin.close(STDOUT_FILENO), 0)
    let runner: BoundedProcessRunner
    do {
      runner = try BoundedProcessRunner(
        executableURL: fixture.url,
        arguments: [],
        timeout: 1,
        maximumOutputSize: 64
      )
    } catch {
      _ = Darwin.dup2(savedStandardOutput, STDOUT_FILENO)
      Darwin.close(savedStandardOutput)
      throw error
    }
    XCTAssertEqual(Darwin.dup2(savedStandardOutput, STDOUT_FILENO), STDOUT_FILENO)
    Darwin.close(savedStandardOutput)
    defer { runner.stop() }

    try runner.readToExit()

    XCTAssertEqual(String(data: runner.output, encoding: .utf8), "protocol")
  }

  func testSimultaneousSpawnsCannotRetainOtherRunnerOutputWriter() async throws {
    let fastFixture = try ExecutableFixture(script: "#!/bin/sh\nprintf fast\n")
    let slowFixture = try ExecutableFixture(script: "#!/bin/sh\nsleep 1\nprintf slow\n")
    defer {
      fastFixture.remove()
      slowFixture.remove()
    }
    let spawnBarrier = SpawnBarrier(participants: 2)

    async let fastResult: ConcurrentRunnerResult = runBoundedProcessOperation {
      do {
        let runner = try BoundedProcessRunner(
          executableURL: fastFixture.url,
          arguments: [],
          timeout: 0.5,
          maximumOutputSize: 64,
          beforeSpawn: spawnBarrier.arriveAndWait
        )
        defer { runner.stop() }
        try runner.readToExit()
        return .success(runner.output)
      } catch {
        return .failure(String(describing: error))
      }
    }
    async let slowResult: ConcurrentRunnerResult = runBoundedProcessOperation {
      do {
        let runner = try BoundedProcessRunner(
          executableURL: slowFixture.url,
          arguments: [],
          timeout: 2,
          maximumOutputSize: 64,
          beforeSpawn: spawnBarrier.arriveAndWait
        )
        defer { runner.stop() }
        try runner.readToExit()
        return .success(runner.output)
      } catch {
        return .failure(String(describing: error))
      }
    }

    let results = try await (fastResult, slowResult)
    guard case .success(let fastOutput) = results.0 else {
      return XCTFail("Fast runner failed: \(results.0)")
    }
    guard case .success(let slowOutput) = results.1 else {
      return XCTFail("Slow runner failed: \(results.1)")
    }
    XCTAssertEqual(String(data: fastOutput, encoding: .utf8), "fast")
    XCTAssertEqual(String(data: slowOutput, encoding: .utf8), "slow")
  }

  func testConcurrentRunnerCannotInheritOrInjectThroughOwnerDescriptors() throws {
    let ownerFixture = try ExecutableFixture(
      script: """
        #!/bin/sh
        printf 'owner-marker\n'
        IFS= read -r line || exit 3
        printf '%s\n' "$line"
        """)
    defer { ownerFixture.remove() }
    let descriptorsBeforeOwner = openDescriptors()
    let owner = try BoundedProcessRunner(
      executableURL: ownerFixture.url,
      arguments: [],
      acceptsInput: true,
      timeout: 1,
      maximumOutputSize: 128
    )
    defer { owner.stop() }
    let ownerDescriptors = openDescriptors().subtracting(descriptorsBeforeOwner)
    XCTAssertEqual(ownerDescriptors.count, 2)
    for descriptor in ownerDescriptors {
      XCTAssertNotEqual(Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
    }

    let descriptorProbes = ownerDescriptors.sorted().map { descriptor in
      """
      (IFS= read -r stolen <&\(descriptor)) 2>/dev/null || :
      (printf '%s\\n' injected >&\(descriptor)) 2>/dev/null || :
      """
    }.joined(separator: "\n")
    let probeFixture = try ExecutableFixture(
      script: "#!/bin/sh\n\(descriptorProbes)\nprintf probe\n")
    defer { probeFixture.remove() }
    let probe = try BoundedProcessRunner(
      executableURL: probeFixture.url,
      arguments: [],
      timeout: 1,
      maximumOutputSize: 64
    )
    defer { probe.stop() }

    try probe.readToExit()
    try owner.write(Data("owned\n".utf8))
    try owner.readToExit()

    XCTAssertEqual(String(data: probe.output, encoding: .utf8), "probe")
    XCTAssertEqual(String(data: owner.output, encoding: .utf8), "owner-marker\nowned\n")
  }

  func testWaitPIDRetriesEINTRAndPreservesNonzeroStatus() throws {
    let fixture = try ExecutableFixture(script: "#!/bin/sh\nexit 7\n")
    defer { fixture.remove() }
    let waitPID = ScriptedWaitPID(errors: [EINTR])
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      timeout: 1,
      maximumOutputSize: 64,
      waitPID: waitPID.call
    )
    defer { runner.stop() }

    XCTAssertThrowsError(try runner.readToExit()) {
      XCTAssertEqual($0 as? BoundedProcessRunnerError, .processFailed(7))
    }
    XCTAssertTrue(waitPID.didReapChild)
  }

  func testUnknownWaitPIDFailureNeverDefaultsToSuccessAndStopReaps() throws {
    let fixture = try ExecutableFixture(script: "#!/bin/sh\nexit 0\n")
    defer { fixture.remove() }
    let waitPID = ScriptedWaitPID(errors: [EIO])
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      timeout: 1,
      maximumOutputSize: 64,
      waitPID: waitPID.call
    )
    defer { runner.stop() }

    XCTAssertThrowsError(try runner.readToExit()) {
      XCTAssertEqual($0 as? BoundedProcessRunnerError, .processStatusFailed(EIO))
    }
    XCTAssertTrue(waitPID.didReapChild)
  }

  func testWritesToChildStandardInput() throws {
    let fixture = try ExecutableFixture(
      script: "#!/bin/sh\nIFS= read -r line || exit 3\nprintf '%s' \"$line\"\n")
    defer { fixture.remove() }
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      acceptsInput: true,
      timeout: 1,
      maximumOutputSize: 64
    )
    defer { runner.stop() }

    try runner.write(Data("hello\n".utf8))
    try runner.readToExit()

    XCTAssertEqual(String(data: runner.output, encoding: .utf8), "hello")
  }

  func testSupportsMultipleRequestResponseExchanges() throws {
    let fixture = try ExecutableFixture(
      script: """
        #!/bin/sh
        IFS= read -r first || exit 3
        printf '%s\n' '{"id":0,"result":{}}'
        IFS= read -r second || exit 3
        IFS= read -r third || exit 3
        printf '%s\n' '{"id":2,"result":{}}'
        while IFS= read -r _; do :; done
        """)
    defer { fixture.remove() }
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      acceptsInput: true,
      timeout: 1,
      maximumOutputSize: 256
    )
    defer { runner.stop() }

    try runner.write(Data("first\n".utf8))
    try runner.read { $0.contains(Data("\"id\":0".utf8)) }
    try runner.write(Data("second\n".utf8))
    try runner.write(Data("third\n".utf8))
    try runner.read { $0.contains(Data("\"id\":2".utf8)) }
  }

  func testNormalProcessReturnsCompleteOutput() throws {
    let fixture = try ExecutableFixture(script: "#!/bin/sh\nprintf 'ready'\n")
    defer { fixture.remove() }
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      timeout: 1,
      maximumOutputSize: 64
    )
    defer { runner.stop() }

    try runner.readToExit()

    XCTAssertEqual(String(data: runner.output, encoding: .utf8), "ready")
  }

  func testOversizedOutputStopsAtBound() throws {
    let runner = try BoundedProcessRunner(
      executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
      arguments: ["malicious"],
      timeout: 1,
      maximumOutputSize: 4_096
    )
    defer { runner.stop() }

    XCTAssertThrowsError(try runner.readToExit()) {
      XCTAssertEqual($0 as? BoundedProcessRunnerError, .responseTooLarge)
    }
    XCTAssertLessThanOrEqual(runner.output.count, 4_096)
  }

  func testProcessIgnoringSIGTERMIsHardKilledWithinBound() throws {
    let fixture = try ExecutableFixture(
      script: "#!/bin/sh\ntrap '' TERM\nprintf 'ready'\nwhile :; do :; done\n")
    defer { fixture.remove() }
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      timeout: 0.05,
      maximumOutputSize: 64
    )
    defer { runner.stop() }
    let startedAt = Date()

    XCTAssertThrowsError(try runner.readToExit()) {
      XCTAssertEqual($0 as? BoundedProcessRunnerError, .timedOut)
    }
    runner.stop()

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
  }

  func testDescendantRetainingStdoutIsKilledWithPrivateProcessGroup() async throws {
    let descendantPIDURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("cowlick-retained-stdout-\(UUID().uuidString)")
    let fixture = try ExecutableFixture(
      script: """
        #!/bin/sh
        (trap '' TERM; while :; do :; done) &
        printf '%s' "$!" > '\(descendantPIDURL.path)'
        printf 'ready'
        """)
    defer {
      fixture.remove()
      try? FileManager.default.removeItem(at: descendantPIDURL)
    }
    let runner = try BoundedProcessRunner(
      executableURL: fixture.url,
      arguments: [],
      timeout: 0.2,
      maximumOutputSize: 64
    )
    defer { runner.stop() }
    let startedAt = Date()

    XCTAssertThrowsError(try runner.readToExit()) {
      XCTAssertEqual($0 as? BoundedProcessRunnerError, .timedOut)
    }
    guard let descendantPID = await waitForProcessID(at: descendantPIDURL) else {
      return XCTFail("Expected retained-pipe descendant")
    }
    defer { Darwin.kill(descendantPID, SIGKILL) }

    let descendantExited = await waitForProcessesToExit([descendantPID])
    XCTAssertTrue(descendantExited)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
  }

  private func openDescriptors() -> Set<Int32> {
    Set(
      ((STDERR_FILENO + 1)..<Darwin.getdtablesize())
        .filter { Darwin.fcntl($0, F_GETFD) >= 0 }
    )
  }
}

private final class ScriptedWaitPID {
  private let lock = NSLock()
  private var errors: [Int32]
  private var reapedChild = false

  init(errors: [Int32]) {
    self.errors = errors
  }

  var didReapChild: Bool {
    lock.withLock { reapedChild }
  }

  func call(
    processIdentifier: pid_t,
    status: UnsafeMutablePointer<Int32>,
    options: Int32
  ) -> pid_t {
    lock.lock()
    if !errors.isEmpty {
      let error = errors.removeFirst()
      lock.unlock()
      errno = error
      return -1
    }
    lock.unlock()

    let result = Darwin.waitpid(processIdentifier, status, options)
    if result == processIdentifier {
      lock.withLock { reapedChild = true }
    }
    return result
  }
}

private final class SpawnBarrier: @unchecked Sendable {
  private let condition = NSCondition()
  private var remainingParticipants: Int

  init(participants: Int) {
    remainingParticipants = participants
  }

  func arriveAndWait() {
    condition.lock()
    remainingParticipants -= 1
    if remainingParticipants == 0 {
      condition.broadcast()
    } else {
      while remainingParticipants > 0 {
        condition.wait()
      }
    }
    condition.unlock()
  }
}

private enum ConcurrentRunnerResult: Sendable {
  case success(Data)
  case failure(String)
}
