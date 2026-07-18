import Foundation

enum UsageProvider: String, CaseIterable, Codable, Sendable {
  case codex
  case openAIAPI = "openai-api"
  case claude
  case anthropicAPI = "anthropic-api"
  case cursor
  case githubCopilot = "github-copilot"
  case gemini
}

struct CredentialReference: Hashable, Codable, Sendable {
  let id: UUID
}

struct ProviderAccount: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  let provider: UsageProvider
  var alias: String
  let credentialReference: CredentialReference
}
