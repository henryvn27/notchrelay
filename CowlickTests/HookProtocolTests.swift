import XCTest

@testable import Cowlick

final class HookProtocolTests: XCTestCase {
  func testDecodesCurrentPermissionRequestSchema() throws {
    let data = Data(
      #"{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/Scoutly","hook_event_name":"PermissionRequest","model":"gpt-5","turn_id":"t1","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"git push","description":"Publish branch"}}"#
        .utf8)
    let input = try JSONDecoder().decode(HookInput.self, from: data)

    XCTAssertEqual(input.sessionId, "s1")
    XCTAssertEqual(input.hookEventName, .permissionRequest)
    XCTAssertEqual(input.toolName, "Bash")
    XCTAssertEqual(input.humanDescription, "Publish branch")
    XCTAssertEqual(HookCommand.event(from: input).event, .approvalRequested)
  }

  func testRejectsUnknownHookEvent() {
    let data = Data(#"{"session_id":"s1","cwd":"/tmp","hook_event_name":"FutureEvent"}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(HookInput.self, from: data))
  }

  func testBridgeRejectsUnknownEventAndVersionMismatch() throws {
    let requestID = UUID()
    let unknown = Data(
      #"{"version":1,"requestId":"\#(requestID.uuidString)","event":"unknown","timestamp":"2026-07-18T00:00:00Z","sessionId":"s","cwd":"/tmp","authToken":"x"}"#
        .utf8)
    XCTAssertThrowsError(try JSONDecoder.bridge.decode(BridgeEvent.self, from: unknown))

    let versioned = makeBridgeEvent(event: .working)
    let encoded = try JSONEncoder.bridge.encode(versioned)
    let decoded = try JSONDecoder.bridge.decode(BridgeEvent.self, from: encoded)
    XCTAssertEqual(decoded.version, BridgeEvent.currentVersion)
    XCTAssertEqual(2, BridgeEvent.currentVersion)
    XCTAssertNotEqual(1, BridgeEvent.currentVersion)
  }

  func testDeliveryOrderingIsTransportOwnedAndNeverDecodedFromClientJSON() throws {
    let requestID = UUID()
    let data = Data(
      #"{"version":2,"requestId":"\#(requestID.uuidString)","event":"working","timestamp":"2026-07-18T00:00:00Z","sessionId":"s","cwd":"/tmp","authToken":"x","deliverySequence":999}"#
        .utf8)

    var event = try JSONDecoder.bridge.decode(BridgeEvent.self, from: data)
    XCTAssertNil(event.deliverySequence)
    event.deliverySequence = 7
    let encoded = try JSONEncoder.bridge.encode(event)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(root["deliverySequence"])
  }

  func testChatTitleMetadataNeverEntersBridgeProtocol() throws {
    let event = makeBridgeEvent(event: .working)
    let encoded = try JSONEncoder.bridge.encode(event)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    XCTAssertNil(root["chatTitle"])
    XCTAssertNil(root["displayTitle"])
    XCTAssertNil(root["threadTitle"])
  }

  func testDecodesCurrentSubagentLifecycleSchemas() throws {
    let startData = Data(
      #"{"agent_id":"agent-1","agent_type":"code-reviewer","cwd":"/tmp/Cowlick","hook_event_name":"SubagentStart","model":"gpt-5.6","permission_mode":"default","session_id":"parent-1","transcript_path":null,"turn_id":"turn-1"}"#
        .utf8)
    let stopData = Data(
      #"{"agent_id":"agent-1","agent_transcript_path":null,"agent_type":"code-reviewer","cwd":"/tmp/Cowlick","hook_event_name":"SubagentStop","last_assistant_message":null,"model":"gpt-5.6","permission_mode":"default","session_id":"parent-1","stop_hook_active":false,"transcript_path":null,"turn_id":"turn-1"}"#
        .utf8)

    let start = try JSONDecoder().decode(HookInput.self, from: startData)
    let stop = try JSONDecoder().decode(HookInput.self, from: stopData)
    let startEvent = HookCommand.event(from: start)
    let stopEvent = HookCommand.event(from: stop)

    XCTAssertTrue(start.hasValidSubagentIdentity)
    XCTAssertEqual(startEvent.event, .subagentStarted)
    XCTAssertEqual(stopEvent.event, .subagentStopped)
    XCTAssertEqual(startEvent.sessionId, "parent-1")
    XCTAssertEqual(stopEvent.sessionId, "parent-1")
    XCTAssertEqual(startEvent.agentId, "agent-1")
    XCTAssertEqual(startEvent.agentType, "code-reviewer")
    XCTAssertNil(stop.agentTranscriptPath)
  }

  func testRejectsMissingSubagentIdentityBeforeRouting() throws {
    let data = Data(
      #"{"session_id":"parent-1","cwd":"/tmp","hook_event_name":"SubagentStart","turn_id":"turn-1"}"#
        .utf8)
    let input = try JSONDecoder().decode(HookInput.self, from: data)
    XCTAssertFalse(input.hasValidSubagentIdentity)
  }

  func testOptionalSubagentContextKeepsApprovalOnParentSession() throws {
    let data = Data(
      #"{"session_id":"parent-1","cwd":"/tmp","hook_event_name":"PermissionRequest","turn_id":"turn-1","agent_id":"agent-1","agent_type":"worker","tool_name":"Bash","tool_input":{"command":"swift test"}}"#
        .utf8)
    let input = try JSONDecoder().decode(HookInput.self, from: data)
    let event = HookCommand.event(from: input)

    XCTAssertEqual(event.event, .approvalRequested)
    XCTAssertEqual(event.sessionId, "parent-1")
    XCTAssertEqual(event.agentId, "agent-1")
  }

  func testPermissionOutputMatchesOfficialAllowShape() throws {
    let data = try XCTUnwrap(HookOutput.permission(.allow))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])

    XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    XCTAssertEqual(Set(decision.keys), ["behavior"])
  }

  func testPermissionOutputMatchesOfficialDenyShape() throws {
    let data = try XCTUnwrap(HookOutput.permission(.deny, message: "Denied in Cowlick."))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])

    XCTAssertEqual(decision["behavior"] as? String, "deny")
    XCTAssertEqual(decision["message"] as? String, "Denied in Cowlick.")
  }

  func testDeferProducesNoPermissionDecision() throws {
    XCTAssertNil(try HookOutput.permission(.deferDecision))
  }

  func testStopOutputIsNeutralJSON() throws {
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: HookOutput.neutralStop) as? [String: Any])
    XCTAssertTrue(root.isEmpty)
  }

  func testMessageLimitsAreOneMegabyte() {
    XCTAssertEqual(HookBridgeClient.maximumMessageSize, 1_048_576)
    XCTAssertEqual(LocalSocketServer.maximumMessageSize, 1_048_576)
  }

  func testHookInputReaderStopsAtOneMegabyte() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Cowlick-HookInput-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 0x61, count: HookBridgeClient.maximumMessageSize + 8_192).write(to: url)
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard case .tooLarge = HookCommand.readBoundedInput(from: handle) else {
      return XCTFail("Expected an oversized input result")
    }
    XCTAssertLessThanOrEqual(
      try handle.offset(), UInt64(HookBridgeClient.maximumMessageSize + 1))
  }

  func testPromptAndResultAreBoundedBeforeBridge() throws {
    let oversized = String(repeating: "a", count: 70_000)
    let data = Data(
      "{\"session_id\":\"s\",\"cwd\":\"/tmp\",\"hook_event_name\":\"UserPromptSubmit\",\"turn_id\":\"t\",\"prompt\":\"\(oversized)\"}"
        .utf8)
    let input = try JSONDecoder().decode(HookInput.self, from: data)
    XCTAssertEqual(HookCommand.event(from: input).prompt?.count, 65_536)
  }

  func testDemoCommandsReuseOneDefaultSession() {
    XCTAssertEqual(HookCommand.defaultDemoSessionID, "cowlick-demo")
  }

  func testFailedDemoReportsBridgeSelfTestFailure() throws {
    let event = try XCTUnwrap(
      HookCommand.demoEvent(named: "failed", sessionID: "self-test", cwd: "/tmp"))

    XCTAssertEqual(event.event, .failed)
    XCTAssertEqual(event.errorMessage, "Bridge self-test failed")
  }
}
