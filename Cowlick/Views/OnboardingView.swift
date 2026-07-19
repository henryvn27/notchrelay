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

  @Environment(\.dismiss) private var dismiss
  @State private var step = 0
  @State private var integrationStatus = "Not checked"
  @State private var integrationInstallState = IntegrationInstallState.notStarted
  @State private var integrationTrust = CodexHookTrustReport.notChecked
  @State private var capsStatus = "Optional"
  @State private var integrationTestStatus = "Not tested"
  @State private var integrationTestInProgress = false
  @State private var testConfirmed = false

  private let totalSteps = 7

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
        case 0: welcome
        case 1: privacy
        case 2: codexDetection
        case 3: integration
        case 4: capsLock
        case 5: visualTest
        default: finish
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 48)
      .padding(.vertical, 36)

      Divider()
      HStack {
        if step > 0 { Button("Back") { step -= 1 } }
        Spacer()
        if step == totalSteps - 1 {
          Button("Done") { completeOnboarding() }
            .buttonStyle(.borderedProminent)
        } else {
          if step == 4 {
            Button("Skip") { step += 1 }
          }
          Button("Continue") { step += 1 }
            .buttonStyle(.borderedProminent)
            .disabled(
              (step == 3
                && (integrationInstallState == .notStarted
                  || integrationInstallState == .installing))
                || (step == 5 && !testConfirmed))
        }
      }
      .padding(20)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: step) {
      guard step == 3, integrationInstallState == .notStarted else { return }
      await installIntegration()
    }
  }

  private var welcome: some View {
    onboardingPage(
      icon: nil,
      title: "Codex status, at the notch.",
      detail:
        "Cowlick shows work, approvals, and completion around the MacBook notch. Other displays use a compact island."
    )
  }

  private var privacy: some View {
    onboardingPage(
      icon: "lock.shield",
      title: "Local by default.",
      detail:
        "No account, analytics, or cloud backend. Cowlick keeps no history. An optional, off-by-default reset forecast contacts willcodexquotareset.com with clear attribution."
    )
  }

  private var codexDetection: some View {
    VStack(alignment: .leading, spacing: 18) {
      onboardingPage(
        icon: codexInstalled ? "checkmark.circle" : "exclamationmark.triangle",
        iconColor: codexInstalled ? NotchTheme.success : NotchTheme.warning,
        title: codexInstalled ? "Codex is installed." : "Codex was not found.",
        detail: codexInstalled
          ? "Cowlick found the official Codex application on this Mac."
          : "Install Codex, then return here or repair integration later from Settings."
      )
      Button("Check Again") { step = 2 }
    }
  }

  private var integration: some View {
    VStack(alignment: .leading, spacing: 18) {
      onboardingPage(
        icon: "point.3.connected.trianglepath.dotted",
        title: "Connect Cowlick to Codex.",
        detail:
          "Cowlick safely merges four lifecycle hooks into your existing Codex configuration and preserves unrelated entries."
      )
      Text(integrationStatus).font(.caption).foregroundStyle(.secondary)
      if integrationInstallState == .failed || integrationTrust.state == .incomplete {
        Button("Retry Integration") { Task { await installIntegration() } }
          .buttonStyle(.borderedProminent)
      }
      Text(integrationGuidance)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var capsLock: some View {
    VStack(alignment: .leading, spacing: 18) {
      onboardingPage(
        icon: "capslock",
        title: "Use the Caps Lock light.",
        detail:
          "This optional signal can pulse for approvals, completions, and failures. Cowlick always restores the original state."
      )
      Text(capsStatus).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Check Support") { checkCapsSupport() }
        Button("Enable and Test") { enableAndTestCaps() }
      }
    }
  }

  private var visualTest: some View {
    VStack(alignment: .leading, spacing: 18) {
      onboardingPage(
        icon: "rectangle.topthird.inset.filled",
        title: "Try the island.",
        detail:
          "Cowlick will run its installed helper through the authenticated local bridge, then show working and completion without using private data."
      )
      HStack {
        Button(integrationTestInProgress ? "Testing…" : "Test Integration") {
          Task { await runIntegrationTest() }
        }
        .disabled(
          integrationTestInProgress || services.sessionStore.integrationSelfTestInProgress
            || !services.sessionStore.canPreviewTestStates)
        Button("Preview Approval") { services.sessionStore.testState(.approvalRequested) }
          .disabled(!services.sessionStore.canPreviewTestStates)
      }
      Text(integrationTestStatus)
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("I can see the island", isOn: $testConfirmed)
        .toggleStyle(.checkbox)
    }
  }

  private var finish: some View {
    onboardingPage(
      icon: "checkmark.seal",
      iconColor: NotchTheme.success,
      title: "You're ready.",
      detail:
        "Cowlick stays hidden when idle. Use the menu-bar icon for settings, diagnostics, tests, and updates."
    )
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

  private var codexInstalled: Bool {
    NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: CodexActivationService.codexBundleIdentifier) != nil
  }

  private func installIntegration() async {
    integrationStatus = "Installing…"
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
    }
    integrationTrust = await services.hookTrustService.inspect()
  }

  private var integrationGuidance: String {
    if integrationInstallState == .failed {
      return "Cowlick could not complete installation. Retry or repair it later in Settings."
    }
    return switch integrationTrust.state {
    case .trusted:
      "Codex has trusted all four Cowlick lifecycle hooks."
    case .needsReview:
      "Cowlick installed the hooks. Codex requires one security review in the Codex CLI: run codex, then /hooks."
    case .incomplete:
      "Some Cowlick hooks are missing. Run Install or Repair again."
    case .notChecked, .unavailable:
      "Codex may require one security review in the Codex CLI /hooks after installation."
    }
  }

  private func checkCapsSupport() {
    Task { capsStatus = await services.capsLockService.supportStatus().summary }
  }

  private func enableAndTestCaps() {
    Task {
      let result = await services.capsLockService.testSignal()
      capsStatus = result == .available ? "Native HID signal test passed" : result.summary
      services.settings.capsLockEnabled = result == .available
    }
  }

  private func runIntegrationTest() async {
    guard !integrationTestInProgress else { return }
    guard let lease = services.sessionStore.beginIntegrationSelfTest(owner: .onboarding) else {
      integrationTestStatus =
        services.sessionStore.integrationSelfTestInProgress
        ? "Another integration self-test is already running."
        : "Resolve current work or approval before testing the integration."
      return
    }
    integrationTestInProgress = true
    defer {
      integrationTestInProgress = false
      services.sessionStore.finishIntegrationSelfTest(lease)
    }
    do {
      let helperURL = try services.hookInstaller.installedHelperURLForExplicitSelfTest()
      let selfTest = IntegrationSelfTestService(helperURL: helperURL)
      try await selfTest.ping()
      guard services.sessionStore.isIntegrationSelfTestActive(lease) else {
        integrationTestStatus = "Integration self-test was cancelled."
        return
      }
      guard services.sessionStore.canPreviewTestStates else {
        integrationTestStatus = "Live activity started, so the integration preview was cancelled."
        return
      }
      let sessionID = "cowlick-self-test-\(UUID().uuidString)"
      guard services.sessionStore.beginIntegrationDemoSession(sessionID, lease: lease) else {
        integrationTestStatus = "Live activity started, so the integration preview was cancelled."
        return
      }
      var keepPresentedState = false
      defer {
        services.sessionStore.finishIntegrationDemoSession(
          sessionID, discardPresentedState: !keepPresentedState)
      }
      try await selfTest.sendDemo(.working, sessionID: sessionID)
      guard await waitForIntegrationDemoEvent(.working, sessionID: sessionID) else {
        integrationTestStatus = integrationPreviewFailureStatus(sessionID: sessionID, lease: lease)
        return
      }
      integrationTestStatus = "Authenticated bridge connected. Working state delivered."
      try await Task.sleep(for: .seconds(1.5))
      guard services.sessionStore.isIntegrationSelfTestActive(lease) else {
        integrationTestStatus = "Integration self-test was cancelled."
        return
      }
      guard services.sessionStore.isIntegrationDemoSessionActive(sessionID) else {
        integrationTestStatus = "Live activity started, so the integration preview was cancelled."
        return
      }
      try await selfTest.sendDemo(.completed, sessionID: sessionID)
      guard await waitForIntegrationDemoEvent(.completed, sessionID: sessionID) else {
        integrationTestStatus = integrationPreviewFailureStatus(sessionID: sessionID, lease: lease)
        return
      }
      keepPresentedState = true
      integrationTestStatus = "Integration passed. Working and completion were delivered."
    } catch {
      integrationTestStatus = error.localizedDescription
    }
  }

  private func waitForIntegrationDemoEvent(
    _ event: IntegrationDemoEvent,
    sessionID: String
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if services.sessionStore.hasObservedIntegrationDemoEvent(event, sessionID: sessionID) {
        return true
      }
      guard services.sessionStore.isIntegrationDemoSessionActive(sessionID) else { return false }
      do {
        try await Task.sleep(for: .milliseconds(20))
      } catch {
        return false
      }
    }
    return services.sessionStore.hasObservedIntegrationDemoEvent(event, sessionID: sessionID)
  }

  private func integrationPreviewFailureStatus(
    sessionID: String,
    lease: IntegrationSelfTestLease
  ) -> String {
    guard services.sessionStore.isIntegrationSelfTestActive(lease) else {
      return "Integration self-test was cancelled."
    }
    return services.sessionStore.isIntegrationDemoSessionActive(sessionID)
      ? "Integration preview delivery timed out."
      : "Live activity started, so the integration preview was cancelled."
  }

  private func completeOnboarding() {
    services.settings.onboardingComplete = true
    services.sessionStore.reset()
    NSApp.keyWindow?.close()
  }
}
