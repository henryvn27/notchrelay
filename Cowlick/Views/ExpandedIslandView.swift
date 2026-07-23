import SwiftUI

struct ExpandedIslandView: View {
  let services: AppServices
  let isAttached: Bool
  let allowsEmergencyScrolling: Bool
  let contentHeightDidChange: (CGFloat) -> Void
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
      await services.providerAccountsController.load()
      if !services.providerAccountsController.accounts.isEmpty {
        await services.providerAccountsController.refreshAll()
      }
    }
    .task(id: services.settings.showNotchIntegrationAlerts) {
      if services.settings.showNotchIntegrationAlerts {
        hookTrust = await services.hookTrustService.inspect()
      } else {
        hookTrust = .notChecked
      }
    }
  }

  private var informationView: some View {
    informationViewport
      .layoutPriority(1)
      .onPreferenceChange(ExpandedInformationHeightKey.self) { informationHeight in
        contentHeightDidChange(informationHeight)
      }
  }

  @ViewBuilder
  private var informationViewport: some View {
    if allowsEmergencyScrolling {
      ScrollView(.vertical, showsIndicators: false) {
        informationContent
      }
      .accessibilityIdentifier("notch-scroll-content")
    } else {
      informationContent
    }
  }

  private var informationContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if services.settings.showNotchCurrentWork {
        activityHeader
      }

      if services.settings.showNotchCurrentWork, !store.sessionSummaries.isEmpty {
        Divider()
        SessionListView(
          sessions: store.sessionSummaries,
          showPromptPreviews: store.settings.showPromptPreviews,
          showResultPreviews: store.settings.showResultPreviews,
          isAttached: isAttached
        )
      }

      if services.settings.showNotchIntegrationAlerts,
        hookTrust.state.requiresIntegrationAttention
      {
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
          showOfficialUsage: showsOfficialUsage,
          showAPICostEstimate: showsAPICostEstimate,
          showForecast: showsForecast,
          metricPreference: services.settings.usageMetricPreference,
          density: .compact
        )
      }

      if services.settings.showNotchProviderBilling,
        !services.providerAccountsController.accounts.isEmpty
      {
        Divider()
        ProviderBillingSectionView(services: services, density: .compact)
      }

      Divider()
      NotchEndActions(isAttached: isAttached)
        .frame(height: NotchTheme.actionBarHeight)
    }
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: ExpandedInformationHeightKey.self,
          value: proxy.size.height
        )
      }
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
            trustState: displayedHookTrustState
          )
        )
        .font(.system(size: 12.5, weight: .semibold))
        Text(
          MenuBarContentView.activitySummary(
            activeSessionCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            trustState: displayedHookTrustState
          )
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 14)
    .frame(height: NotchTheme.informationHeaderHeight)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notch-activity-header")
  }

  private var showsUsageInformation: Bool {
    showsOfficialUsage || showsAPICostEstimate || showsForecast
  }

  private var showsOfficialUsage: Bool {
    services.settings.showCodexUsage && services.settings.showNotchCodexUsage
  }

  private var showsAPICostEstimate: Bool {
    services.settings.showAPICostEstimate && services.settings.showNotchAPICostEstimate
  }

  private var showsForecast: Bool {
    services.settings.showResetForecast && services.settings.showNotchResetForecast
  }

  private var displayedHookTrustState: CodexHookTrustState {
    services.settings.showNotchIntegrationAlerts ? hookTrust.state : .trusted
  }

  private var headerNeedsIntegrationAttention: Bool {
    let status = store.displaySession?.presentationStatus
    return (status == nil || status == .idle)
      && displayedHookTrustState.requiresIntegrationAttention
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

private struct ExpandedInformationHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct NotchEndActions: View {
  let isAttached: Bool

  var body: some View {
    HStack(spacing: 4) {
      Spacer(minLength: 0)
      action("Settings", systemImage: "gearshape") {
        WindowCoordinator.shared.openSettingsForTesting()
      }
      action("Quit", systemImage: "power") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(.horizontal, 10)
    .accessibilityIdentifier("notch-end-actions")
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
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
