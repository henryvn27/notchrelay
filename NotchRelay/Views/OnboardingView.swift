import AppKit
import SwiftUI

struct OnboardingView: View {
  let services: AppServices

  @Environment(\.dismiss) private var dismiss
  @State private var step = 0
  @State private var integrationStatus = "Not checked"
  @State private var capsStatus = "Optional"
  @State private var testConfirmed = false

  private let totalSteps = 7

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("NOTCHRELAY")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .tracking(1.8)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(step + 1) of \(totalSteps)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(24)

      ProgressView(value: Double(step + 1), total: Double(totalSteps))
        .tint(NotchTheme.accent)
        .padding(.horizontal, 24)

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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)

      Divider()
      HStack {
        if step > 0 { Button("Back") { step -= 1 } }
        Spacer()
        if step == totalSteps - 1 {
          Button("Finish") { completeOnboarding() }
            .buttonStyle(.borderedProminent)
        } else {
          Button(step == 4 ? "Skip Optional Step" : "Continue") { step += 1 }
            .buttonStyle(.borderedProminent)
        }
      }
      .padding(20)
    }
    .background(.regularMaterial)
  }

  private var welcome: some View {
    onboardingPage(
      icon: "waveform.path",
      title: "Codex status, where your eyes already are.",
      detail:
        "NotchRelay shows working, approval, completion, and failure states around the MacBook notch—or in a compact top-center island."
    )
  }

  private var privacy: some View {
    onboardingPage(
      icon: "lock.shield",
      title: "Local by design.",
      detail:
        "No account. No analytics. No cloud backend. Prompts and approval operations are held only in memory, and previews are off by default."
    )
  }

  private var codexDetection: some View {
    VStack(spacing: 18) {
      onboardingPage(
        icon: codexInstalled ? "checkmark.circle" : "exclamationmark.triangle",
        title: codexInstalled ? "Codex is installed." : "Codex was not found.",
        detail: codexInstalled
          ? "NotchRelay found the official Codex application on this Mac."
          : "Install Codex, then return here or repair integration later from Settings."
      )
      Button("Check Again") { step = 2 }
    }
  }

  private var integration: some View {
    VStack(spacing: 18) {
      onboardingPage(
        icon: "point.3.connected.trianglepath.dotted",
        title: "Connect Codex hooks.",
        detail:
          "NotchRelay safely merges four lifecycle hooks into your existing Codex configuration and preserves unrelated entries."
      )
      Text(integrationStatus).font(.caption).foregroundStyle(.secondary)
      Button("Install or Repair Integration") { installIntegration() }
        .buttonStyle(.borderedProminent)
      Text("After installation, Codex may ask you to review and trust the hook in /hooks.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var capsLock: some View {
    VStack(spacing: 18) {
      onboardingPage(
        icon: "capslock",
        title: "Optional hardware attention signal.",
        detail:
          "NotchRelay can briefly pulse the Caps Lock LED for approvals, completions, and failures. It always restores the original state."
      )
      Text(capsStatus).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Check Support") { checkCapsSupport() }
        Button("Enable and Test") { enableAndTestCaps() }
      }
    }
  }

  private var visualTest: some View {
    VStack(spacing: 18) {
      onboardingPage(
        icon: "rectangle.topthird.inset.filled",
        title: "Make sure the island appears.",
        detail:
          "Run a local visual event now. This test contains no private data and does not contact Codex."
      )
      HStack {
        Button("Test Working") { services.sessionStore.testState(.working) }
        Button("Test Approval") { services.sessionStore.testState(.approvalRequested) }
        Button("Test Completed") { services.sessionStore.testState(.completed) }
      }
      Toggle("I can see the island", isOn: $testConfirmed)
        .toggleStyle(.checkbox)
    }
  }

  private var finish: some View {
    onboardingPage(
      icon: "checkmark.seal",
      title: "Ready for local Codex sessions.",
      detail:
        "NotchRelay stays hidden when idle. Use the menu-bar relay icon for settings, diagnostics, tests, and updates."
    )
  }

  private func onboardingPage(icon: String, title: String, detail: String) -> some View {
    VStack(spacing: 18) {
      Image(systemName: icon)
        .font(.system(size: 42, weight: .light))
        .foregroundStyle(NotchTheme.accent)
        .accessibilityHidden(true)
      Text(title)
        .font(.system(size: 25, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
  }

  private var codexInstalled: Bool {
    NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: CodexActivationService.codexBundleIdentifier) != nil
  }

  private func installIntegration() {
    integrationStatus = "Installing…"
    Task {
      let result = await Task.detached { () -> String in
        let installer = HookInstaller()
        do {
          try installer.installOrRepair()
          return installer.status().summary
        } catch { return error.localizedDescription }
      }.value
      integrationStatus = result
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

  private func completeOnboarding() {
    services.settings.onboardingComplete = true
    services.sessionStore.reset()
    NSApp.keyWindow?.close()
  }
}
