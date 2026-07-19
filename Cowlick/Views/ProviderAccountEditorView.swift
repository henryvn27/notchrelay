import SwiftUI

struct ProviderAccountEditorView: View {
  enum Purpose: Identifiable {
    case add
    case rename(ProviderAccount)
    case replaceCredential(ProviderAccount)

    var id: String {
      switch self {
      case .add: "add"
      case .rename(let account): "rename-\(account.id.uuidString)"
      case .replaceCredential(let account): "credential-\(account.id.uuidString)"
      }
    }

    var account: ProviderAccount? {
      switch self {
      case .add: nil
      case .rename(let account), .replaceCredential(let account): account
      }
    }
  }

  let purpose: Purpose
  let save: (UsageProvider, String, Data?) async throws -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var provider: UsageProvider
  @State private var alias: String
  @State private var credential = ""
  @State private var isSaving = false
  @State private var errorMessage: String?
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case alias
    case credential
  }

  init(
    purpose: Purpose,
    save: @escaping (UsageProvider, String, Data?) async throws -> Void
  ) {
    self.purpose = purpose
    self.save = save
    _provider = State(initialValue: purpose.account?.provider ?? .openAIAPI)
    _alias = State(initialValue: purpose.account?.alias ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        switch purpose {
        case .add:
          accountFields
          credentialFields
        case .rename(let account):
          Section("Account") {
            LabeledContent("Provider", value: account.provider.billingAccountName ?? "")
            TextField("Name", text: $alias)
              .focused($focusedField, equals: .alias)
              .accessibilityLabel("Account name")
          }
        case .replaceCredential(let account):
          Section("Account") {
            LabeledContent("Name", value: account.alias)
            LabeledContent("Provider", value: account.provider.billingAccountName ?? "")
          }
          credentialFields
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Spacer()
        Button(saveTitle) {
          Task { await commit() }
        }
        .disabled(!canSave || isSaving)
        .accessibilityHint(canSave ? "Saves the billing account" : validationHint)
      }
      .padding(16)
    }
    .frame(width: 440, height: editorHeight)
    .onAppear {
      focusedField = purpose.account == nil || isRenaming ? .alias : .credential
    }
  }

  private var accountFields: some View {
    Section("Billing account") {
      Picker("Provider", selection: $provider) {
        ForEach(UsageProvider.supportedBillingAccounts, id: \.self) { provider in
          Text(provider.billingAccountName ?? "").tag(provider)
        }
      }
      TextField("Name", text: $alias)
        .focused($focusedField, equals: .alias)
        .accessibilityLabel("Account name")
    }
  }

  private var credentialFields: some View {
    Section {
      SecureField("Admin API key", text: $credential)
        .focused($focusedField, equals: .credential)
        .accessibilityLabel("Admin API key")
      Text(
        "Cowlick stores this key in your macOS Keychain and uses it only to request account-wide organization billing. The saved key is never displayed."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text("Credential")
    }
  }

  private var trimmedAlias: String {
    alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedCredential: String {
    credential.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    switch purpose {
    case .add:
      !trimmedAlias.isEmpty && trimmedAlias.count <= 64 && !trimmedCredential.isEmpty
    case .rename:
      !trimmedAlias.isEmpty && trimmedAlias.count <= 64
    case .replaceCredential:
      !trimmedCredential.isEmpty
    }
  }

  private var validationHint: String {
    switch purpose {
    case .add:
      "Enter an account name and admin API key"
    case .rename:
      "Enter an account name between 1 and 64 characters"
    case .replaceCredential:
      "Enter a new admin API key"
    }
  }

  private var isRenaming: Bool {
    if case .rename = purpose { return true }
    return false
  }

  private var saveTitle: String {
    if isSaving { return "Saving…" }
    return switch purpose {
    case .add: "Add Account"
    case .rename: "Rename"
    case .replaceCredential: "Replace Key"
    }
  }

  private var editorHeight: CGFloat {
    switch purpose {
    case .add: 330
    case .rename: 220
    case .replaceCredential: 300
    }
  }

  private func commit() async {
    guard canSave else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    do {
      let data = trimmedCredential.isEmpty ? nil : Data(trimmedCredential.utf8)
      try await save(provider, trimmedAlias, data)
      credential = ""
      dismiss()
    } catch {
      errorMessage = EventLogger.sanitizeError(error.localizedDescription)
    }
  }
}
