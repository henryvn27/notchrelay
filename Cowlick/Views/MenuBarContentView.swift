import AppKit
import SwiftUI

enum CowlickMenuBarArtwork {
  static func templateImage(size: NSSize = NSSize(width: 18, height: 18)) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      let sourceBounds = CGRect(x: 32, y: 32, width: 960, height: 639)
      let scale = min(rect.width / sourceBounds.width, rect.height / sourceBounds.height)
      let renderedSize = CGSize(
        width: sourceBounds.width * scale,
        height: sourceBounds.height * scale
      )

      context.saveGState()
      context.translateBy(
        x: rect.midX - renderedSize.width / 2 - sourceBounds.minX * scale,
        y: rect.midY + renderedSize.height / 2 + sourceBounds.minY * scale
      )
      context.scaleBy(x: scale, y: -scale)

      let path = CGMutablePath()
      path.move(to: CGPoint(x: 32, y: 256))
      path.addCurve(
        to: CGPoint(x: 256, y: 32),
        control1: CGPoint(x: 32, y: 132),
        control2: CGPoint(x: 132, y: 32)
      )
      path.addLine(to: CGPoint(x: 768, y: 32))
      path.addCurve(
        to: CGPoint(x: 992, y: 256),
        control1: CGPoint(x: 892, y: 32),
        control2: CGPoint(x: 992, y: 132)
      )
      path.addLine(to: CGPoint(x: 992, y: 421))
      path.addCurve(
        to: CGPoint(x: 765, y: 410),
        control1: CGPoint(x: 905, y: 397),
        control2: CGPoint(x: 829, y: 394)
      )
      path.addCurve(
        to: CGPoint(x: 647, y: 512),
        control1: CGPoint(x: 696, y: 427),
        control2: CGPoint(x: 654, y: 463)
      )
      path.addCurve(
        to: CGPoint(x: 741, y: 650),
        control1: CGPoint(x: 639, y: 566),
        control2: CGPoint(x: 671, y: 612)
      )
      path.addCurve(
        to: CGPoint(x: 522, y: 604),
        control1: CGPoint(x: 657, y: 671),
        control2: CGPoint(x: 577, y: 654)
      )
      path.addCurve(
        to: CGPoint(x: 477, y: 407),
        control1: CGPoint(x: 462, y: 550),
        control2: CGPoint(x: 447, y: 481)
      )
      path.addCurve(
        to: CGPoint(x: 220, y: 449),
        control1: CGPoint(x: 399, y: 444),
        control2: CGPoint(x: 313, y: 458)
      )
      path.addCurve(
        to: CGPoint(x: 32, y: 405),
        control1: CGPoint(x: 153, y: 443),
        control2: CGPoint(x: 90, y: 428)
      )
      path.closeSubpath()
      context.addPath(path)
      context.setFillColor(NSColor.black.cgColor)
      context.fillPath()
      context.restoreGState()
      return true
    }
    image.isTemplate = true
    return image
  }
}

enum CowlickMenuBarLayout {
  static func maximumDetailHeight(visibleScreenHeight: CGFloat) -> CGFloat {
    max(0, min(480, visibleScreenHeight - 320))
  }
}

struct MenuBarLabelView: View {
  private static let menuBarIcon = CowlickMenuBarArtwork.templateImage()

  let store: SessionStore
  let usageStore: UsageStore
  let settings: SettingsStore

  var body: some View {
    let content = MenuBarLabelContent.resolve(
      presentation: settings.menuBarPresentation,
      status: store.displaySession?.presentationStatus,
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
        .renderingMode(.template)
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
    let status = store.displaySession?.presentationStatus.shortLabel ?? "Idle"
    var parts = ["Cowlick", status]
    if store.activeSessionCount > 1 {
      parts.append("\(store.activeSessionCount) active sessions")
    }
    if store.activeSubagentCount > 0 {
      parts.append(
        "\(store.activeSubagentCount) active \(store.activeSubagentCount == 1 ? "agent" : "agents")"
      )
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

      if hasScrollableDetails(store: store) {
        Divider()
        ScrollView {
          scrollableDetails(store: store)
        }
        .frame(
          maxHeight: CowlickMenuBarLayout.maximumDetailHeight(
            visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 720
          )
        )
        .accessibilityIdentifier("menu-scroll-content")
      }

      Divider()
      actionSection(store: store)
    }
    .frame(width: 328)
    .onAppear {
      services.usageStore.refreshForMenuPresentation()
      Task { await refreshHookTrust() }
      Task { await services.providerAccountsController.load() }
    }
  }

  @ViewBuilder
  private func scrollableDetails(store: SessionStore) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if hookTrust.state.requiresIntegrationAttention {
        integrationAttentionSection
      }

      if services.settings.showCodexUsage || services.settings.showAPICostEstimate
        || services.settings.showResetForecast
      {
        if hookTrust.state.requiresIntegrationAttention { Divider() }
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
        billingAccountSection
      }

      if !store.sessionSummaries.isEmpty {
        Divider()
        sessionSection(store: store)
      }
    }
  }

  private func hasScrollableDetails(store: SessionStore) -> Bool {
    hookTrust.state.requiresIntegrationAttention
      || services.settings.showCodexUsage
      || services.settings.showAPICostEstimate
      || services.settings.showResetForecast
      || !services.providerAccountsController.accounts.isEmpty
      || !store.sessionSummaries.isEmpty
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
      Image(
        systemName: headerIcon(
          status: store.displaySession?.presentationStatus,
          trustState: hookTrust.state
        )
      )
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(
        shouldShowIntegrationAttentionInHeader(
          status: store.displaySession?.presentationStatus,
          trustState: hookTrust.state
        )
          ? NotchTheme.warning : stateColor(store.displaySession?.presentationStatus)
      )
      .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          Self.headerTitle(
            status: store.displaySession?.presentationStatus,
            trustState: hookTrust.state
          )
        )
        .font(.headline)
        Text(
          Self.activitySummary(
            activeSessionCount: store.activeSessionCount,
            activeSubagentCount: store.activeSubagentCount,
            trustState: hookTrust.state
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        if store.currentApproval != nil {
          WindowCoordinator.shared.reviewCurrentApproval()
        } else {
          WindowCoordinator.shared.openIsland()
        }
      } label: {
        Image(
          systemName: store.currentApproval == nil
            ? "arrow.up.left.and.arrow.down.right" : "exclamationmark.shield"
        )
      }
      .buttonStyle(.plain)
      .disabled(store.sessionSummaries.isEmpty)
      .help(store.currentApproval == nil ? "Open Island" : "Review Approval")
      .accessibilityLabel(store.currentApproval == nil ? "Open Island" : "Review Approval")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var integrationAttentionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(integrationAttentionTitle, systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(NotchTheme.warning)
      Text(CodexIntegrationPresentation.guidance(for: hookTrust.state))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        if hookTrust.state == .incomplete {
          Button("Open Settings") { WindowCoordinator.shared.openSettingsForTesting() }
        } else if hookTrust.state == .needsReview {
          Button("Copy /hooks") { CodexIntegrationPresentation.copyReviewCommand() }
        } else {
          Button("Open Diagnostics") { WindowCoordinator.shared.openDiagnostics() }
        }
        Button("Check Again") { Task { await refreshHookTrust() } }
      }
      .buttonStyle(.link)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("codex-integration-attention")
  }

  private var integrationAttentionTitle: String {
    switch hookTrust.state {
    case .needsReview: "Codex review required"
    case .incomplete: "Integration needs repair"
    case .unavailable: "Integration not verified"
    case .notChecked, .trusted: ""
    }
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
                ? "clock.arrow.circlepath" : stateIcon(session.presentationStatus)
            )
            .foregroundStyle(stateColor(session.presentationStatus))
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
              Text(session.displayName)
                .lineLimit(1)
              if let project = session.projectContext {
                Text(project)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
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
      if store.currentApproval != nil {
        actionButton("Review Approval", systemImage: "exclamationmark.shield") {
          WindowCoordinator.shared.reviewCurrentApproval()
        }
      }
      actionButton("Open Codex", systemImage: "macwindow") {
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
    activeSubagentCount: Int = 0,
    trustState: CodexHookTrustState
  ) -> String {
    if activeSessionCount > 0 {
      let sessions =
        "\(activeSessionCount) active \(activeSessionCount == 1 ? "session" : "sessions")"
      guard activeSubagentCount > 0 else { return sessions }
      return
        "\(sessions) · \(activeSubagentCount) \(activeSubagentCount == 1 ? "agent" : "agents")"
    }
    switch trustState {
    case .needsReview:
      return "Review Cowlick in Codex CLI /hooks"
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

  private func refreshHookTrust() async {
    hookTrust = await services.hookTrustService.inspect()
  }

  private func headerIcon(status: AgentStatus?, trustState: CodexHookTrustState) -> String {
    if shouldShowIntegrationAttentionInHeader(status: status, trustState: trustState) {
      return "exclamationmark.triangle.fill"
    }
    return stateIcon(status)
  }

  private func shouldShowIntegrationAttentionInHeader(
    status: AgentStatus?,
    trustState: CodexHookTrustState
  ) -> Bool {
    (status == nil || status == .idle) && trustState.requiresIntegrationAttention
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

extension CodexHookTrustState {
  fileprivate var requiresIntegrationAttention: Bool {
    switch self {
    case .needsReview, .incomplete, .unavailable: true
    case .notChecked, .trusted: false
    }
  }
}
