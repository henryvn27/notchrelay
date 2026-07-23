import Foundation
import SwiftUI

struct ProviderAccountsView: View {
  let controller: ProviderAccountsController
  let billingStore: ProviderBillingStore
  let usageStore: UsageStore

  @State private var editorPurpose: ProviderAccountEditorView.Purpose?
  @State private var pendingRemoval: ProviderAccount?
  @State private var removingAccountID: UUID?
  @State private var noticeMessage: String?

  var body: some View {
    Form {
      Section("Codex subscription") {
        HStack(spacing: 10) {
          Image(systemName: "bolt.horizontal.circle")
            .foregroundStyle(.secondary)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text("Active local Codex account")
              .fontWeight(.medium)
            Text(localSubscriptionDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if usageStore.isRefreshing {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Refreshing Codex quota")
          }
        }
        Text(
          "This is the account currently signed in to the Codex app on this Mac. Its subscription quota is separate from the API billing accounts below."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        if controller.accounts.isEmpty {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
              .foregroundStyle(.secondary)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text("No billing accounts")
                .fontWeight(.medium)
              Text("Add an organization account to see its month-to-date API charges.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(.vertical, 4)
        } else {
          ForEach(controller.accounts) { account in
            ProviderAccountRow(
              account: account,
              isSelected: controller.selectedAccountID == account.id,
              snapshot: billingStore.snapshots[account.id],
              errorMessage: billingStore.errors[account.id],
              isRefreshing: billingStore.refreshingAccountIDs.contains(account.id),
              isRemoving: removingAccountID == account.id,
              select: { _ = controller.selectAccount(id: account.id) },
              rename: { editorPurpose = .rename(account) },
              replaceCredential: { editorPurpose = .replaceCredential(account) },
              remove: { pendingRemoval = account }
            )
          }
        }

        Button {
          editorPurpose = .add
        } label: {
          Label("Add Account", systemImage: "plus")
        }

        if let errorMessage = controller.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if let noticeMessage {
          Label(noticeMessage, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Organization billing accounts")
      } footer: {
        Text(
          "OpenAI amounts are account-wide month-to-date API charges. Anthropic amounts are partial because its official cost report excludes Priority Tier usage. Cowlick keeps accounts separate and never combines them into a total. Admin keys stay in your macOS Keychain."
        )
      }
    }
    .formStyle(.grouped)
    .task {
      usageStore.refreshForMenuPresentation()
      await controller.load()
      guard !controller.accounts.isEmpty else { return }
      await controller.refreshAll()
    }
    .sheet(item: $editorPurpose) { purpose in
      ProviderAccountEditorView(purpose: purpose) { provider, alias, credential in
        try await saveEditor(
          purpose: purpose,
          provider: provider,
          alias: alias,
          credential: credential
        )
      }
    }
    .confirmationDialog(
      "Remove billing account?",
      isPresented: removalConfirmationPresented,
      presenting: pendingRemoval
    ) { account in
      Button("Remove \(account.alias)", role: .destructive) {
        remove(account)
      }
      Button("Cancel", role: .cancel) {}
    } message: { account in
      Text(
        "This removes \(account.alias) and its Keychain credential from Cowlick. It does not change the provider account."
      )
    }
  }

  private var localSubscriptionDetail: String {
    if let error = usageStore.officialError { return "Quota unavailable · \(error)" }
    if let planType = usageStore.snapshot?.planType, !planType.isEmpty {
      return "\(planType.capitalized) plan · quota available"
    }
    if usageStore.snapshot != nil { return "Quota available" }
    return usageStore.isRefreshing ? "Reading quota…" : "Quota not loaded"
  }

  private var removalConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { isPresented in
        if !isPresented { pendingRemoval = nil }
      }
    )
  }

  private func refresh(_ account: ProviderAccount) {
    noticeMessage = nil
    let interval = ProviderAccountsController.monthToDateInterval(
      endingAt: Date(),
      calendar: .autoupdatingCurrent
    )
    Task { await billingStore.refresh(account: account, interval: interval) }
  }

  private func remove(_ account: ProviderAccount) {
    pendingRemoval = nil
    removingAccountID = account.id
    noticeMessage = nil
    Task {
      defer { removingAccountID = nil }
      do {
        try await controller.removeAccount(id: account.id)
        noticeMessage = "Removed \(account.alias)."
      } catch {
        noticeMessage = nil
      }
    }
  }

  private func saveEditor(
    purpose: ProviderAccountEditorView.Purpose,
    provider: UsageProvider,
    alias: String,
    credential: Data?
  ) async throws {
    noticeMessage = nil
    switch purpose {
    case .add:
      guard let credential else { throw ProviderAccountEditorError.missingCredential }
      let account = try await controller.addAccount(
        provider: provider,
        alias: alias,
        credential: credential
      )
      noticeMessage = "Added \(account.alias)."
      refresh(account)
    case .rename(let account):
      try await controller.renameAccount(id: account.id, alias: alias)
      noticeMessage = "Renamed account to \(alias)."
    case .replaceCredential(let account):
      guard let credential else { throw ProviderAccountEditorError.missingCredential }
      try await controller.replaceCredential(for: account.id, credential: credential)
      noticeMessage = "Replaced the Keychain credential for \(account.alias)."
      refresh(account)
    }
  }
}

private struct ProviderAccountRow: View {
  let account: ProviderAccount
  let isSelected: Bool
  let snapshot: ActualBilledSnapshot?
  let errorMessage: String?
  let isRefreshing: Bool
  let isRemoving: Bool
  let select: () -> Void
  let rename: () -> Void
  let replaceCredential: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: select) {
        HStack(spacing: 10) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(account.alias)
              .fontWeight(.medium)
              .lineLimit(1)
            Text(account.provider.billingAccountName ?? "")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          billingStatus
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isRemoving)
      .accessibilityLabel(rowAccessibilityLabel)
      .accessibilityHint("Selects this billing account")

      Menu {
        Button("Rename…", systemImage: "pencil", action: rename)
          .disabled(isRemoving)
        Button("Replace Admin Key…", systemImage: "key", action: replaceCredential)
          .disabled(isRemoving)
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
          .disabled(isRemoving)
      } label: {
        if isRemoving {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "ellipsis.circle")
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Actions for \(account.alias)")
    }
    .padding(.vertical, 2)

    if let errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.leading, 28)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Billing refresh failed: \(errorMessage)")
    }
  }

  @ViewBuilder
  private var billingStatus: some View {
    let presentation = ProviderBillingPresentation.resolve(
      snapshot: snapshot,
      errorMessage: errorMessage
    )
    if isRefreshing {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Refreshing…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    } else if let snapshot, presentation.showsAmount {
      VStack(alignment: .trailing, spacing: 2) {
        Text(formattedAmount(snapshot))
          .font(.body.monospacedDigit())
        Text(presentation.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    } else {
      Text(presentation.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var rowAccessibilityLabel: String {
    let selection = isSelected ? "selected" : "not selected"
    let presentation = ProviderBillingPresentation.resolve(
      snapshot: snapshot,
      errorMessage: errorMessage
    )
    let billing: String
    if isRefreshing {
      billing = "refreshing month-to-date billing"
    } else if let snapshot, presentation.showsAmount {
      billing = "\(formattedAmount(snapshot)) \(presentation.detail)"
    } else {
      billing = presentation.detail
    }
    return [
      account.alias,
      account.provider.billingAccountName ?? "",
      selection,
      billing,
    ].joined(separator: ", ")
  }

  private func formattedAmount(_ snapshot: ActualBilledSnapshot) -> String {
    snapshot.amount.formatted(.currency(code: snapshot.currency.uppercased()))
  }
}

private enum ProviderAccountEditorError: LocalizedError {
  case missingCredential

  var errorDescription: String? {
    "Enter an admin API key."
  }
}
