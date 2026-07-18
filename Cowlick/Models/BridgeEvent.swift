import Foundation

enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
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
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
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

  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  func prettyPrinted() -> String {
    guard let data = try? JSONEncoder.pretty.encode(self),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }
}

extension JSONEncoder {
  static var bridge: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static var pretty: JSONEncoder {
    let encoder = bridge
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

extension JSONDecoder {
  static var bridge: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

enum BridgeEventName: String, Codable, Sendable, Equatable {
  case sessionStart
  case working
  case approvalRequested
  case completed
  case failed
  case ping
}

struct BridgeEvent: Codable, Equatable, Sendable {
  static let currentVersion = ProductVersion.bridgeProtocol

  let version: Int
  let requestId: UUID
  let event: BridgeEventName
  let timestamp: Date
  let sessionId: String
  let turnId: String?
  let cwd: String
  let model: String?
  let prompt: String?
  let lastAssistantMessage: String?
  let errorMessage: String?
  let toolName: String?
  let toolInput: JSONValue?
  let humanDescription: String?
  let authToken: String

  init(
    version: Int = currentVersion,
    requestId: UUID = UUID(),
    event: BridgeEventName,
    timestamp: Date = Date(),
    sessionId: String,
    turnId: String? = nil,
    cwd: String,
    model: String? = nil,
    prompt: String? = nil,
    lastAssistantMessage: String? = nil,
    errorMessage: String? = nil,
    toolName: String? = nil,
    toolInput: JSONValue? = nil,
    humanDescription: String? = nil,
    authToken: String
  ) {
    self.version = version
    self.requestId = requestId
    self.event = event
    self.timestamp = timestamp
    self.sessionId = sessionId
    self.turnId = turnId
    self.cwd = cwd
    self.model = model
    self.prompt = prompt
    self.lastAssistantMessage = lastAssistantMessage
    self.errorMessage = errorMessage
    self.toolName = toolName
    self.toolInput = toolInput
    self.humanDescription = humanDescription
    self.authToken = authToken
  }
}
