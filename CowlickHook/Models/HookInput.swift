import Foundation

enum HookJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: HookJSONValue])
  case array([HookJSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: HookJSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([HookJSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var objectValue: [String: HookJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

enum CodexHookEventName: String, Codable, Equatable, Sendable {
  case sessionStart = "SessionStart"
  case userPromptSubmit = "UserPromptSubmit"
  case permissionRequest = "PermissionRequest"
  case stop = "Stop"
}

struct HookInput: Codable, Equatable, Sendable {
  let sessionId: String
  let transcriptPath: String?
  let cwd: String
  let hookEventName: CodexHookEventName
  let model: String?
  let turnId: String?
  let permissionMode: String?
  let prompt: String?
  let toolName: String?
  let toolInput: HookJSONValue?
  let stopHookActive: Bool?
  let lastAssistantMessage: String?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case transcriptPath = "transcript_path"
    case cwd
    case hookEventName = "hook_event_name"
    case model
    case turnId = "turn_id"
    case permissionMode = "permission_mode"
    case prompt
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case stopHookActive = "stop_hook_active"
    case lastAssistantMessage = "last_assistant_message"
  }

  var humanDescription: String? {
    toolInput?.objectValue?["description"]?.stringValue
  }
}
