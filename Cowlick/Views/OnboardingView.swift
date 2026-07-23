import AppKit
import SwiftUI

private enum IntegrationInstallState {
  case notStarted
  case installing
  case installed
  case failed
}

private struct IntegrationInstallResult: Sendable {
  let status: String
  let succeeded: Bool
}

struct OnboardingView: View {
  let services: AppServices

  @Environment(\.scenePhase) private var scenePhase
  @State private var step = 0
  @State private var integrationStatus = "Not checked"
  @State private var integrationInstallState = IntegrationInstallState.notStarted
  @State private var integrationTrust = CodexHookTrustReport.notChecked
  @State private var integrationDeferred = false

  private let totalSteps = 3

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 26, height: 26)
          .accessibilityHidden(true)
        Text("Cowlick")
          .font(.headline)
        Spacer()
        Text("Step \(step + 1) of \(totalSteps)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)

      Divider()

      Group {
        switch step {
        case 0: placement
        case 1: integration
        default: finish
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 48)
      .padding(.vertical, 36)

      Divider()
      footer
        .padding(20)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: step) {
      guard step == 1, integrationInstallState != .installing else { return }
      await refreshIntegration()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, step == 1, integrationTrust.state != .trusted else { return }
      Task { await refreshIntegration() }
    }
  }

  private var placement: some View {
    @Bindable var settings = services.settings

    return VStack(alignment: .leading, spacing: 22) {
      onboardingPage(
        icon: nil,
        title: "Choose where Cowlick lives.",
        detail: notchAvailable
          ? "Automatic uses this Mac's notch and keeps the menu bar clear. You can choose one menu-bar item instead."
          : "This Mac does not have a notch, so Cowlick uses one compact menu-bar item."
      )

      if notchAvailable {
        Picker("Show Cowlick in", selection: $settings.presentationPreference) {
          Text("Automatic").tag(PresentationPreference.automatic)
          Text("Menu bar").tag(PresentationPreference.menuBar)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
      }

      Label(
        services.presentationCoordinator.resolvedDescription,
        systemImage: services.presentationCoordinator.showsMenuBar
          ? "menubar.rectangle" : "rectangle.topthird.inset.filled"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var integration: some View {
    VStack(alignment: .leading, spacing: 18) {
      onboardingPage(
        icon: integrationIcon,
        iconColor: integrationIconColor,
        title: integrationTitle,
        detail:
          "Cowlick installs six local lifecycle hooks without replacing unrelated Codex settings."
      )

      Label(integrationStatus, systemImage: integrationStatusIcon)
        .font(.callout)
        .foregroundStyle(.secondary)

      if !codexInstalled {
        Text(
          "Codex was not found. Install the official Codex app before reviewing Cowlick's hooks."
        )
        .font(.caption)
        .foregroundStyle(NotchTheme.warning)
      } else if integrationTrust.state == .needsReview {
        Text(Self.finishInstruction(trustState: integrationTrust.state))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else if integrationInstallState == .failed || integrationTrust.state == .incomplete {
        Text(integrationGuidance)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var finish: some View {
    VStack(alignment: .leading, spacing: 22) {
      onboardingPage(
        icon: integrationTrust.state == .trusted ? "checkmark.seal" : "checkmark.circle",
        iconColor: NotchTheme.success,
        title: Self.finishTitle(trustState: integrationTrust.state),
        detail: Self.finishDetail(
          trustState: integrationTrust.state, integrationDeferred: integrationDeferred)
      )

      VStack(alignment: .leading, spacing: 12) {
        Label(
          services.presentationCoordinator.resolvedDescription,
          systemImage: services.presentationCoordinator.showsMenuBar
            ? "menubar.rectangle" : "rectangle.topthird.inset.filled"
        )
        Label(usageSummary, systemImage: "gauge")
        Label(
          integrationTrust.state == .trusted
            ? "Approval actions are available in Cowlick."
            : "Approval actions stay in Codex until its hook review is complete.",
          systemImage: integrationTrust.state == .trusted ? "checkmark.shield" : "shield"
        )
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack {
      if step > 0 {
        Button("Back") { step -= 1 }
      }
      Spacer()

      switch step {
      case 0:
        Button("Continue") { step = 1 }
          .buttonStyle(.borderedProminent)
      case 1:
        if integrationInstallState != .installing && integrationTrust.state != .trusted {
          Button("Use limited mode") {
            integrationDeferred = true
            step = 2
          }
          .buttonStyle(.link)
        }

        switch integrationInstallState {
        case .installing:
          ProgressView("Connecting…")
            .controlSize(.small)
        case _ where integrationTrust.state == .trusted:
          Button("Continue") { step = 2 }
            .buttonStyle(.borderedProminent)
        case _ where integrationTrust.state == .needsReview:
          Button("Copy /hooks & Open Codex") { reviewHooksInCodex() }
            .buttonStyle(.borderedProminent)
        case .failed:
          Button("Retry connection") { Task { await installIntegration(openReview: true) } }
            .buttonStyle(.borderedProminent)
        case .notStarted, .installed:
          Button("Connect Codex") { Task { await installIntegration(openReview: true) } }
            .buttonStyle(.borderedProminent)
        }
      default:
        Button(Self.completionButtonTitle(trustState: integrationTrust.state)) {
          completeOnboarding()
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func onboardingPage(
    icon: String?,
    iconColor: Color = .primary,
    title: String,
    detail: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 28, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(iconColor)
          .frame(width: 34, height: 34, alignment: .leading)
          .accessibilityHidden(true)
      } else {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 72, height: 72)
          .accessibilityHidden(true)
      }
      Text(title)
        .font(.title2.weight(.semibold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 480, alignment: .leading)
      Text(detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: 470, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: 500, alignment: .leading)
  }

  private var notchAvailable: Bool {
    #if DEBUG
      if CommandLine.arguments.contains("--simulate-notch") { return true }
    #endif
    guard
      let screen = NotchGeometryResolver.preferredScreen(services.settings.preferredDisplay)
    else { return false }
    return NotchGeometryResolver.notchMetrics(screen: screen) != nil
  }

  private var codexInstalled: Bool {
    NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: CodexActivationService.codexBundleIdentifier) != nil
  }

  private var integrationIcon: String {
    switch integrationTrust.state {
    case .trusted: "checkmark.seal"
    case .needsReview: "shield.lefthalf.filled"
    case .notChecked, .incomplete, .unavailable: "point.3.connected.trianglepath.dotted"
    }
  }

  private var integrationIconColor: Color {
    switch integrationTrust.state {
    case .trusted: NotchTheme.success
    case .needsReview: NotchTheme.warning
    case .notChecked, .incomplete, .unavailable: .primary
    }
  }

  private var integrationTitle: String {
    switch integrationTrust.state {
    case .trusted: "Codex is connected."
    case .needsReview: "One review in Codex."
    case .notChecked, .incomplete, .unavailable: "Connect Codex."
    }
  }

  private var integrationStatusIcon: String {
    switch integrationInstallState {
    case .notStarted: "circle"
    case .installing: "hourglass"
    case .installed: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var integrationGuidance: String {
    if integrationInstallState == .failed {
      return "Cowlick could not complete installation. Retry, or continue in limited mode."
    }
    return CodexIntegrationPresentation.guidance(for: integrationTrust.state)
  }

  private var usageSummary: String {
    guard let percent = services.usageStore.primaryDisplayedPercent else {
      return "Codex usage appears here when it is available."
    }
    let meaning = services.settings.usageMetricPreference.label.lowercased()
    return "Codex usage: \(Int(percent.rounded()))% \(meaning)."
  }

  private func refreshIntegration() async {
    let status = await Task.detached { HookInstaller().status() }.value
    integrationStatus = status.summary
    integrationInstallState = status.isHealthy ? .installed : .notStarted
    integrationTrust = await services.hookTrustService.inspect()
    advanceWhenTrusted()
  }

  private func installIntegration(openReview: Bool = false) async {
    integrationStatus = "Installing all six hooks…"
    integrationInstallState = .installing
    let result = await Task.detached { () -> IntegrationInstallResult in
      let installer = HookInstaller()
      do {
        try installer.installOrRepair()
        return IntegrationInstallResult(status: installer.status().summary, succeeded: true)
      } catch {
        return IntegrationInstallResult(status: error.localizedDescription, succeeded: false)
      }
    }.value
    integrationStatus = result.status
    integrationInstallState = result.succeeded ? .installed : .failed
    if result.succeeded {
      services.settings.integrationIntentionallyRemoved = false
      do {
        let helperURL = try services.hookInstaller.installedHelperURLForExplicitSelfTest()
        try await IntegrationSelfTestService(helperURL: helperURL).ping()
        integrationStatus = "Installed. Local bridge connected."
      } catch {
        integrationStatus = "Installed. Codex review is still required."
      }
    }
    integrationTrust = await services.hookTrustService.inspect()
    advanceWhenTrusted()
    if openReview, integrationTrust.state == .needsReview {
      reviewHooksInCodex()
    }
  }

  private func advanceWhenTrusted() {
    guard integrationTrust.state == .trusted else { return }
    integrationDeferred = false
    step = 2
  }

  private func reviewHooksInCodex() {
    CodexIntegrationPresentation.copyReviewCommand()
    integrationStatus = "Waiting for Codex review. Cowlick checks again when you return."
    CodexActivationService.openCodex(fallbackDirectory: nil)
  }

  private func completeOnboarding() {
    services.settings.onboardingComplete = true
    services.sessionStore.reset()
    NSApp.keyWindow?.close()
  }

  static func canContinueFromIntegration(trustState: CodexHookTrustState) -> Bool {
    trustState == .trusted
  }

  static func finishTitle(trustState: CodexHookTrustState) -> String {
    trustState == .trusted ? "Cowlick is ready." : "Cowlick is ready in limited mode."
  }

  static func finishDetail(
    trustState: CodexHookTrustState,
    integrationDeferred: Bool
  ) -> String {
    if trustState == .trusted {
      return
        "Usage, current work, completions, and approval actions now appear in your selected surface."
    }
    return integrationDeferred
      ? "Usage and local activity are available now. Approval actions remain in Codex until you review Cowlick's hooks."
      : "Usage and local activity are available now. Complete the Codex review later to add approval actions."
  }

  static func finishInstruction(trustState: CodexHookTrustState) -> String {
    if trustState == .needsReview {
      return
        "Choose Copy /hooks & Open Codex. Paste the copied command, approve Cowlick once, then return; Cowlick checks automatically."
    }
    return CodexIntegrationPresentation.guidance(for: trustState)
  }

  static func completionButtonTitle(trustState: CodexHookTrustState) -> String {
    "Start Cowlick"
  }
}
