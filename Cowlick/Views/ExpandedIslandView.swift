import SwiftUI

struct ExpandedIslandView: View {
  let services: AppServices
  let isAttached: Bool
  @State private var hookTrust = CodexHookTrustReport.notChecked

  private var store: SessionStore { services.sessionStore }

  var body: some View {
    Group {
      if let approval = store.currentApproval {
        ApprovalView(
          request: approval,
          isAttached: isAttached,
          allow: { _ = store.decide(requestID: approval.id, decision: .allow) },
          deny: { _ = store.decide(requestID: approval.id, decision: .deny) },
          openCodex: {
            CodexActivationService.openCodex(fallbackDirectory: approval.workingDirectory)
          }
        )
      } else {
        informationView
      }
    }
    .task {
      services.usageStore.refreshForMenuPresentation()
      hookTrust = await services.hookTrustService.inspect()
      await services.providerAccountsController.load()
    }
  }

  private var informationView: some View {
    VStack(spacing: 0) {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          activityHeader

          if hookTrust.state.requiresIntegrationAttention {
            Divider()
            CodexIntegrationAttentionView(
              state: hookTrust.state,
              refresh: { Task { hookTrust = await services.hookTrustService.inspect() } }
            )
          }

          if showsUsageInformation {
            Divider()
            UsageSectionView(
              store: services.usageStore,
              showOfficialUsage: services.settings.showCodexUsage,
              showAPICostEstimate: services.settings.showAPICostEstimate,
              showForecast: services.settings.showResetForecast,
              metricPreference: services.settings.usageMetricPreference,
              refresh: { services.usageStore.refreshOfficial(force: true) }
            )
          }

          if !services.providerAccountsController.accounts.isEmpty {
            Divider()
            ProviderBillingSectionView(services: services)
          }

          if !store.sessionSummaries.isEmpty {
            Divider()
            SessionListView(
              sessions: store.sessionSummaries,
              showPromptPreviews: store.settings.showPromptPreviews,
              showResultPreviews: store.settings.showResultPreviews,
              isAttached: isAttached,
              scrollsInternally: false
            )
          }
        }
      }
      .accessibilityIdentifier("notch-scroll-content")
      .layoutPriority(1)

      NotchActionBar(services: services, isAttached: isAttached)
        .frame(height: NotchTheme.actionBarHeight)
    }
  }

  private var activityHeader: some View {
    HStack(spacing: 9) {
      Image(systemName: headerIcon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(headerColor)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(
          MenuBarContentView.headerTitle(
            status: store.displaySession?.presentationStatus,
            trustState: hookTrust.state
          )
        )
        .font(.system(size: 12.5, weight: .semibold))
        Text(
          MenuBarContentView.activitySummary(
            activeSessionCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            trustState: hookTrust.state
          )
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
      }
      Spacer()
      if services.updateService.canCheckForUpdates {
        Button {
          services.updateService.checkForUpdates()
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Check for Updates")
        .accessibilityLabel("Check for Updates")
      }
    }
    .padding(.horizontal, 14)
    .frame(height: NotchTheme.informationHeaderHeight)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notch-activity-header")
  }

  private var showsUsageInformation: Bool {
    services.settings.showCodexUsage || services.settings.showAPICostEstimate
      || services.settings.showResetForecast
  }

  private var headerNeedsIntegrationAttention: Bool {
    let status = store.displaySession?.presentationStatus
    return (status == nil || status == .idle) && hookTrust.state.requiresIntegrationAttention
  }

  private var headerIcon: String {
    if headerNeedsIntegrationAttention { return "exclamationmark.triangle.fill" }
    switch store.displaySession?.presentationStatus {
    case .working: return "waveform.path"
    case .awaitingApproval: return "exclamationmark.shield"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .idle, nil: return "circle"
    }
  }

  private var headerColor: Color {
    if headerNeedsIntegrationAttention { return NotchTheme.warning }
    switch store.displaySession?.presentationStatus {
    case .awaitingApproval: return .orange
    case .completed: return NotchTheme.success
    case .failed: return NotchTheme.failure
    default: return .secondary
    }
  }
}

private struct NotchActionBar: View {
  let services: AppServices
  let isAttached: Bool

  private var store: SessionStore { services.sessionStore }

  var body: some View {
    HStack(spacing: 2) {
      action("Open Codex", systemImage: "macwindow") {
        CodexActivationService.openCodex(fallbackDirectory: store.displaySession?.workingDirectory)
      }
      action("Settings", systemImage: "gearshape") {
        WindowCoordinator.shared.openSettingsForTesting()
      }
      action("Diagnostics", systemImage: "stethoscope") {
        WindowCoordinator.shared.openDiagnostics()
      }
      action("Quit", systemImage: "power") {
        NSApplication.shared.terminate(nil)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 8)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(isAttached ? NotchTheme.hairline : Color.secondary.opacity(0.18))
        .frame(height: 0.5)
    }
  }

  private func action(
    _ title: String,
    systemImage: String,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      HStack(spacing: 3) {
        Image(systemName: systemImage)
        Text(title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(isAttached ? Color.white.opacity(0.72) : Color.secondary)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
