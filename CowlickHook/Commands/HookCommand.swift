import Darwin
import Foundation

enum HookCommand {
  static let version = ProductVersion.marketing
  static let defaultDemoSessionID = "cowlick-demo"

  enum InputReadResult {
    case data(Data)
    case tooLarge
    case failed
  }

  static func run(arguments: [String]) -> Int32 {
    guard let command = arguments.dropFirst().first else {
      writeError("usage: cowlick-hook <hook|ping|diagnostics|demo|version>")
      return 2
    }
    let client = HookBridgeClient()

    switch command {
    case "hook":
      return runHook(client: client)
    case "ping":
      return runPing(client: client)
    case "diagnostics":
      writeJSON(client.diagnostics())
      return 0
    case "demo":
      guard let name = arguments.dropFirst(2).first else {
        writeError("usage: cowlick-hook demo <working|approval|completed|failed>")
        return 2
      }
      return runDemo(name: name, client: client)
    case "version", "--version", "-v":
      FileHandle.standardOutput.write(Data("Cowlick hook \(version)\n".utf8))
      return 0
    default:
      writeError("unknown command: \(command)")
      return 2
    }
  }

  private static func runHook(client: HookBridgeClient) -> Int32 {
    let inputData: Data
    switch readBoundedInput(from: .standardInput) {
    case .data(let data): inputData = data
    case .tooLarge:
      writeError("hook input exceeds 1 MB; deferring safely")
      return 0
    case .failed:
      writeError("hook input could not be read; deferring safely")
      return 0
    }

    let decoder = JSONDecoder()
    let input: HookInput
    do {
      input = try decoder.decode(HookInput.self, from: inputData)
    } catch {
      writeError("invalid or unsupported Codex hook input: \(error.localizedDescription)")
      return 1
    }

    let bridgeEvent = event(from: input)
    updateLifecycleLedger(input: input, event: bridgeEvent)
    switch input.hookEventName {
    case .permissionRequest:
      do {
        let response = try client.send(bridgeEvent, waitForResponse: true)
        guard let response,
          let output = try HookOutput.permission(response.decision)
        else { return 0 }
        FileHandle.standardOutput.write(output)
      } catch {
        writeError("approval deferred to Codex: \(error.localizedDescription)")
      }
    case .stop:
      do { _ = try client.send(bridgeEvent, waitForResponse: false) } catch {
        writeError("completion delivery failed: \(error.localizedDescription)")
      }
      FileHandle.standardOutput.write(HookOutput.neutralStop)
    case .sessionStart, .userPromptSubmit:
      do { _ = try client.send(bridgeEvent, waitForResponse: false) } catch {
        writeError("status delivery skipped: \(error.localizedDescription)")
      }
    }
    return 0
  }

  static func readBoundedInput(from handle: FileHandle) -> InputReadResult {
    var input = Data()
    do {
      while input.count <= HookBridgeClient.maximumMessageSize {
        let remaining = HookBridgeClient.maximumMessageSize + 1 - input.count
        guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty
        else { return .data(input) }
        input.append(chunk)
      }
      return .tooLarge
    } catch {
      return .failed
    }
  }

  private static func runPing(client: HookBridgeClient) -> Int32 {
    let result = client.diagnostics()
    writeJSON(result)
    return result["ok"] as? Bool == true ? 0 : 1
  }

  private static func runDemo(name: String, client: HookBridgeClient) -> Int32 {
    let cwd = FileManager.default.currentDirectoryPath
    let eventName: HookBridgeEventName
    switch name {
    case "working": eventName = .working
    case "approval": eventName = .approvalRequested
    case "completed": eventName = .completed
    case "failed": eventName = .failed
    default:
      writeError("unknown demo event: \(name)")
      return 2
    }

    let event = HookBridgeEvent(
      event: eventName,
      sessionId: ProcessInfo.processInfo.environment["COWLICK_DEMO_SESSION_ID"]
        ?? defaultDemoSessionID,
      turnId: "demo-turn",
      cwd: cwd,
      prompt: name == "working" ? "Prepare the release verification" : nil,
      lastAssistantMessage: name == "completed" ? "Release verification passed" : nil,
      errorMessage: name == "failed" ? "Build verification failed" : nil,
      toolName: name == "approval" ? "Bash" : nil,
      toolInput: name == "approval"
        ? .object([
          "command": .string("git push origin main"),
          "description": .string("Publish the verified branch"),
        ]) : nil,
      humanDescription: name == "approval" ? "Publish the verified branch" : nil
    )
    do {
      let response = try client.send(event, waitForResponse: name == "approval")
      if let response {
        writeJSON(["decision": response.decision.rawValue])
      } else {
        writeJSON(["sent": true])
      }
      return 0
    } catch {
      writeError(error.localizedDescription)
      return 1
    }
  }

  static func event(from input: HookInput) -> HookBridgeEvent {
    let eventName: HookBridgeEventName
    switch input.hookEventName {
    case .sessionStart: eventName = .sessionStart
    case .userPromptSubmit: eventName = .working
    case .permissionRequest: eventName = .approvalRequested
    case .stop: eventName = .completed
    }
    return HookBridgeEvent(
      event: eventName,
      sessionId: input.sessionId,
      turnId: input.turnId,
      cwd: input.cwd,
      model: input.model,
      prompt: input.prompt.map { String($0.prefix(65_536)) },
      lastAssistantMessage: input.lastAssistantMessage.map { String($0.prefix(65_536)) },
      toolName: input.toolName,
      toolInput: input.toolInput,
      humanDescription: input.humanDescription
    )
  }

  private static func updateLifecycleLedger(input: HookInput, event: HookBridgeEvent) {
    do {
      switch input.hookEventName {
      case .userPromptSubmit, .permissionRequest:
        try LifecycleLedger.markWorking(
          sessionID: event.sessionId,
          turnID: event.turnId,
          workingDirectory: event.cwd,
          model: event.model,
          updatedAt: event.timestamp
        )
      case .sessionStart, .stop:
        try LifecycleLedger.remove(sessionID: event.sessionId, now: event.timestamp)
      }
    } catch {
      writeError("lifecycle recovery state was not updated: \(error.localizedDescription)")
    }
  }

  private static func writeJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data + Data([0x0A]))
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data("cowlick-hook: \(message)\n".utf8))
  }
}
