import AppKit
import SwiftUI

struct MenuBarLabelView: View {
  private static let menuBarIcon: NSImage = {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      guard let source = NSApplication.shared.applicationIconImage else {
        return false
      }
      NSGraphicsContext.current?.imageInterpolation = .high
      source.draw(
        in: rect,
        from: NSRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1
      )
      return true
    }
    image.isTemplate = false
    return image
  }()

  let store: SessionStore
  let usageStore: UsageStore
  let settings: SettingsStore

  var body: some View {
    let content = MenuBarLabelContent.resolve(
      presentation: settings.menuBarPresentation,
      status: store.displaySession?.status,
      activeSessionCount: store.activeSessionCount,
      percentageText: percentageText
    )
    HStack(spacing: 4) {
      icon(content.icon)
      if let text = content.text {
        Text(text)
          .monospacedDigit()
      }
    }
    .fixedSize()
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func icon(_ icon: MenuBarLabelContent.Icon) -> some View {
    switch icon {
    case .app:
      Image(nsImage: Self.menuBarIcon)
        .renderingMode(.original)
    case .status(let systemName):
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .symbolRenderingMode(.monochrome)
    case .none:
      EmptyView()
    }
  }

  private var percentageText: String? {
    guard settings.showCodexUsage, let percent = usageStore.primaryDisplayedPercent else {
      return nil
    }
    return "\(Int(percent.rounded()))%"
  }

  private var accessibilityText: String {
    let status = store.displaySession?.status.shortLabel ?? "Idle"
    var parts = ["Cowlick", status]
    if store.activeSessionCount > 1 {
      parts.append("\(store.activeSessionCount) active sessions")
    }
    if let usage = usageStore.primaryMetricAccessibilityLabel, settings.showCodexUsage {
      parts.append(usage)
    }
    return parts.joined(separator: ", ")
  }
}

struct MenuBarContentView: View {
  let services: AppServices
  @State private var hookTrust = CodexHookTrustReport.notChecked

  var body: some View {
    let store = services.sessionStore
    VStack(alignment: .leading, spacing: 0) {
      header(store: store)

      if services.settings.showCodexUsage || services.settings.showResetForecast {
        Divider()
        UsageSectionView(
          store: services.usageStore,
          showOfficialUsage: services.settings.showCodexUsage,
          showForecast: services.settings.showResetForecast,
          metricPreference: services.settings.usageMetricPreference,
          refresh: { services.usageStore.refreshIfNeeded(force: true) }
        )
      }

      if !services.providerAccountsController.accounts.isEmpty {
        Divider()
        billingAccountSection
      }

      if !store.sessionSummaries.isEmpty {
        Divider()
        sessionSection(store: store)
      }

      Divider()
      actionSection(store: store)
    }
    .frame(width: 328)
    .onAppear {
      services.usageStore.refreshForMenuPresentation()
      Task { hookTrust = await services.hookTrustService.inspect() }
      Task { await services.providerAccountsController.load() }
    }
  }

  private var billingAccountSection: some View {
    let controller = services.providerAccountsController
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("API billing")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await controller.refreshSelected() }
        } label: {
          if let selectedID = controller.selectedAccountID,
            services.providerBillingStore.refreshingAccountIDs.contains(selectedID)
          {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.plain)
        .disabled(
          controller.selectedAccount == nil
            || controller.selectedAccountID.map(
              services.providerBillingStore.refreshingAccountIDs.contains) == true
        )
        .help("Refresh selected billing account")
        .accessibilityLabel("Refresh selected billing account")
      }

      if let selected = controller.selectedAccount {
        let presentation = billingPresentation(for: selected.id)
        Menu {
          ForEach(controller.accounts) { account in
            Button {
              _ = controller.selectAccount(id: account.id)
            } label: {
              if account.id == controller.selectedAccountID {
                Label(account.alias, systemImage: "checkmark")
              } else {
                Text(account.alias)
              }
            }
          }
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(selected.alias)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Text(selected.provider.billingAccountName ?? "Billing account")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(presentation.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(billingAmount(for: selected.id, presentation: presentation))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(billingAccessibilityLabel(for: selected))

        if let error = services.providerBillingStore.errors[selected.id] {
          Label(error, systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func billingPresentation(for accountID: UUID) -> ProviderBillingPresentation {
    ProviderBillingPresentation.resolve(
      snapshot: services.providerBillingStore.snapshots[accountID],
      errorMessage: services.providerBillingStore.errors[accountID]
    )
  }

  private func billingAmount(
    for accountID: UUID,
    presentation: ProviderBillingPresentation
  ) -> String {
    guard presentation.showsAmount,
      let snapshot = services.providerBillingStore.snapshots[accountID]
    else {
      return "Not refreshed"
    }
    return snapshot.amount.formatted(.currency(code: snapshot.currency.uppercased()))
  }

  private func billingAccessibilityLabel(for account: ProviderAccount) -> String {
    let presentation = billingPresentation(for: account.id)
    return [
      "API billing account",
      account.alias,
      account.provider.billingAccountName ?? "",
      billingAmount(for: account.id, presentation: presentation),
      presentation.detail,
    ].joined(separator: ", ")
  }

  private func header(store: SessionStore) -> some View {
    HStack(spacing: 10) {
      Image(systemName: stateIcon(store.displaySession?.status))
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(stateColor(store.displaySession?.status))
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          Self.headerTitle(
            status: store.displaySession?.status,
            trustState: hookTrust.state
          )
        )
        .font(.headline)
        Text(
          Self.activitySummary(
            activeSessionCount: store.activeSessionCount,
            trustState: hookTrust.state
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        WindowCoordinator.shared.openIsland()
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(.plain)
      .disabled(store.sessionSummaries.isEmpty)
      .help("Open Island")
      .accessibilityLabel("Open Island")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  private func sessionSection(store: SessionStore) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Sessions")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(store.sessionSummaries.prefix(5)) { session in
        Button {
          WindowCoordinator.shared.openIsland()
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: session.isRecovered
                ? "clock.arrow.circlepath" : stateIcon(session.status)
            )
            .foregroundStyle(stateColor(session.status))
            .frame(width: 14)
            Text(session.projectName)
              .lineLimit(1)
            Spacer()
            Text(session.statusLabel)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func actionSection(store: SessionStore) -> some View {
    VStack(spacing: 0) {
      actionButton("Open Codex", systemImage: "terminal") {
        CodexActivationService.openCodex(fallbackDirectory: store.displaySession?.workingDirectory)
      }
      Menu {
        Button("Working") { store.testState(.working) }
        Button("Approval") { store.testState(.approvalRequested) }
        Button("Completed") { store.testState(.completed) }
        Button("Multiple Sessions") { store.testMultipleSessions() }
        Divider()
        Button("Failed Preview") { store.testState(.failed) }
      } label: {
        Label("Test State", systemImage: "play.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
      }
      .menuStyle(.borderlessButton)
      .accessibilityIdentifier("test-state-menu")
      .disabled(!store.canPreviewTestStates)
      actionButton("Settings", systemImage: "gearshape") {
        WindowCoordinator.shared.openSettingsForTesting()
      }
      actionButton("Diagnostics", systemImage: "stethoscope") {
        WindowCoordinator.shared.openDiagnostics()
      }
      if services.updateService.canCheckForUpdates {
        actionButton("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
          services.updateService.checkForUpdates()
        }
      }
      actionButton("Quit Cowlick", systemImage: "power") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .padding(.vertical, 5)
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
  }

  static func activitySummary(
    activeSessionCount: Int,
    trustState: CodexHookTrustState
  ) -> String {
    if activeSessionCount > 0 {
      return
        "\(activeSessionCount) active \(activeSessionCount == 1 ? "session" : "sessions")"
    }
    switch trustState {
    case .needsReview:
      return "Trust Cowlick in Codex /hooks"
    case .incomplete:
      return "Open Settings to repair integration"
    case .notChecked, .trusted, .unavailable:
      break
    }
    return "No recent Codex activity"
  }

  static func headerTitle(
    status: AgentStatus?,
    trustState: CodexHookTrustState
  ) -> String {
    if let status, status != .idle { return status.shortLabel }
    switch trustState {
    case .needsReview: return "Codex review required"
    case .incomplete: return "Integration needs repair"
    case .notChecked, .trusted, .unavailable: break
    }
    return "Idle"
  }

  private func stateIcon(_ status: AgentStatus?) -> String {
    switch status {
    case .working: "waveform.path"
    case .awaitingApproval: "exclamationmark.shield"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .idle, nil: "circle"
    }
  }

  private func stateColor(_ status: AgentStatus?) -> Color {
    switch status {
    case .awaitingApproval: .orange
    case .completed: .green
    case .failed: .red
    default: .secondary
    }
  }
}
