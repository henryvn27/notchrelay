import AppKit
import SwiftUI

private struct HookTaskResult: Sendable {
  let status: HookInstallationStatus
  let errorMessage: String?
}

struct SettingsView: View {
  let services: AppServices

  @State private var hookStatus = HookInstallationStatus(
    installedEvents: [], helperInstalled: false, configurationExists: false, error: nil)
  @State private var hookTrust = CodexHookTrustReport.notChecked
  @State private var integrationMessage = ""
  @State private var capsStatus = "Checking…"
  @State private var launchAtLogin = false
  @State private var launchError = ""
  @State private var confirmReset = false
  @State private var integrationTaskInProgress = false

  var body: some View {
    @Bindable var settings = services.settings

    TabView {
      Form {
        Section("Presentation") {
          Picker("Show Cowlick in", selection: $settings.presentationPreference) {
            ForEach(PresentationPreference.allCases) { preference in
              Text(preference.label).tag(preference)
            }
          }
          Text(services.presentationCoordinator.resolvedDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("Notch wings") {
          Picker("Left wing", selection: $settings.notchLeftWingMetric) {
            ForEach(NotchWingMetric.allCases) { metric in
              Text(metric.label).tag(metric)
            }
          }
          Text(wingMetricGuidance(settings.notchLeftWingMetric))
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("Right wing", selection: $settings.notchSecondaryMetric) {
            ForEach(NotchWingMetric.allCases) { metric in
              Text(metric.label).tag(metric)
            }
          }
          Text(wingMetricGuidance(settings.notchSecondaryMetric))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("Expanded notch") {
          Toggle("Current work", isOn: $settings.showNotchCurrentWork)
            .accessibilityIdentifier("settings-notch-current-work")
          Toggle("Integration alerts", isOn: $settings.showNotchIntegrationAlerts)
            .accessibilityIdentifier("settings-notch-integration-alerts")
          Toggle("Codex quota", isOn: $settings.showNotchCodexUsage)
            .accessibilityIdentifier("settings-notch-codex-usage")
          Toggle("API-price estimate", isOn: $settings.showNotchAPICostEstimate)
            .accessibilityIdentifier("settings-notch-api-cost")
          Toggle("Reset forecast", isOn: $settings.showNotchResetForecast)
            .accessibilityIdentifier("settings-notch-reset-forecast")
          Toggle("Provider billing", isOn: $settings.showNotchProviderBilling)
            .accessibilityIdentifier("settings-notch-provider-billing")
          Text("Choose what appears when the notch expands.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("Menu bar") {
          Picker("Display", selection: $settings.menuBarPresentation) {
            ForEach(MenuBarPresentation.allCases) { presentation in
              Text(presentation.label).tag(presentation)
            }
          }
          Text(settings.menuBarPresentation.guidance)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            "Used automatically on Macs without a notch, or whenever Menu bar is selected above."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Appearance") {
          Toggle(
            "Show Codex chat names",
            isOn: Binding(
              get: { settings.showChatNames },
              set: { value in
                settings.showChatNames = value
                Task { await services.sessionStore.refreshChatNames() }
              }
            ))
          Text(
            "Uses the same short task names shown by Codex. Turn this off to show project names only."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Toggle(
            "Show prompt previews",
            isOn: Binding(
              get: { settings.showPromptPreviews },
              set: { value in
                settings.showPromptPreviews = value
                Task { await services.sessionStore.refreshChatNames() }
              }
            ))
          Toggle("Show result previews", isOn: $settings.showResultPreviews)
          Picker("Show completion for", selection: $settings.completionVisibility) {
            ForEach(CompletionVisibility.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Automatically expand approvals", isOn: $settings.autoExpandApprovals)
          Picker("Preferred display", selection: $settings.preferredDisplay) {
            ForEach(PreferredDisplay.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Reduce Cowlick animation", isOn: $settings.reducedAnimation)
        }
        Section("Startup") {
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { launchAtLogin },
              set: { value in updateLaunchAtLogin(value) }
            ))
          if !launchError.isEmpty { Text(launchError).foregroundStyle(.red).font(.caption) }
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("General", systemImage: "slider.horizontal.3") }

      Form {
        Section("Codex connection") {
          Label(integrationStatusTitle, systemImage: integrationStatusSymbol)
            .font(.headline)
            .foregroundStyle(integrationStatusColor)
          Text(integrationStatusMessage)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          Button("Check & Repair Connection") { checkAndRepairIntegration() }
            .disabled(integrationTaskInProgress)

          if hookTrust.state == .needsReview {
            Button("Copy /hooks & Open Codex") {
              CodexIntegrationPresentation.copyReviewCommand()
              CodexActivationService.openCodex(fallbackDirectory: nil)
            }
          }
          if case .unavailable = hookTrust.state {
            Button("Open Diagnostics") { WindowCoordinator.shared.openDiagnostics() }
          }
          if !integrationMessage.isEmpty {
            Text(integrationMessage).font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Advanced") {
          DisclosureGroup("Integration options") {
            Stepper(value: $settings.approvalTimeout, in: 5...60, step: 5) {
              LabeledContent(
                "Approval fallback", value: "\(Int(settings.approvalTimeout)) seconds")
            }
            LabeledContent("Hook configuration", value: hookStatus.summary)
            LabeledContent("Codex review", value: hookTrust.state.summary)
            Button("Reveal Hook Configuration") { revealHooks() }
            Button("Remove Cowlick Hooks", role: .destructive) { removeIntegration() }
          }
          .disabled(integrationTaskInProgress)
        }
        Section("Test integration") {
          HStack {
            Button("Working") { services.sessionStore.testState(.working) }
            Button("Approval") { services.sessionStore.testState(.approvalRequested) }
            Button("Completed") { services.sessionStore.testState(.completed) }
            Button("Failed Preview") { services.sessionStore.testState(.failed) }
          }
          .disabled(!services.sessionStore.canPreviewTestStates)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Integration", systemImage: "point.3.connected.trianglepath.dotted") }

      Form {
        Section("Codex quota") {
          Toggle(
            "Show official Codex quota",
            isOn: Binding(
              get: { settings.showCodexUsage },
              set: { value in
                settings.showCodexUsage = value
                services.usageStore.settingsDidChange()
              }
            ))
          Picker("Quota percentage", selection: $settings.usageMetricPreference) {
            ForEach(UsageMetricPreference.allCases, id: \.self) { preference in
              Text(preference.label).tag(preference)
            }
          }
          .pickerStyle(.segmented)
          .disabled(!settings.showCodexUsage)
          LabeledContent("Status", value: services.usageStore.officialStatus)
          Text(
            "Cowlick reads quota from the Codex app on this Mac. It does not read your Codex account file or save quota history."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Quota windows") {
          Group {
            Toggle("5-hour window", isOn: $settings.showFiveHourQuotaWindow)
              .accessibilityIdentifier("settings-quota-five-hour")
            Toggle("Weekly window", isOn: $settings.showWeeklyQuotaWindow)
              .accessibilityIdentifier("settings-quota-weekly")
            Toggle("GPT-5.3-Codex Spark window", isOn: $settings.showSparkQuotaWindow)
              .accessibilityIdentifier("settings-quota-spark")
          }
          .disabled(!settings.showCodexUsage)
          Text("Choose each official Codex window Cowlick shows.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("API-price equivalent") {
          Toggle(
            "Estimate local Codex usage at API rates",
            isOn: Binding(
              get: { settings.showAPICostEstimate },
              set: { value in
                settings.showAPICostEstimate = value
                services.usageStore.settingsDidChange()
              }
            ))
          Picker(
            "Estimate window",
            selection: Binding(
              get: { settings.apiCostWindow },
              set: { value in
                settings.apiCostWindow = value
                services.usageStore.settingsDidChange()
              }
            )
          ) {
            ForEach(APICostWindow.allCases) { window in
              Text(window.label).tag(window)
            }
          }
          .disabled(!settings.showAPICostEstimate)
          LabeledContent("Status", value: services.usageStore.apiCostStatus)
          Text(
            "Cowlick scans local Codex session files, but retains or logs only model names, turn IDs, and numeric token counters. It applies reviewed OpenAI Standard rates and confirmed Priority rates. The result covers this Mac only and is not your subscription charge or an actual bill."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Unofficial reset forecast") {
          Toggle(
            "Show data from Will Codex Reset?",
            isOn: Binding(
              get: { settings.showResetForecast },
              set: { value in
                settings.showResetForecast = value
                services.usageStore.settingsDidChange()
              }
            ))
          LabeledContent("Status", value: services.usageStore.forecastStatus)
          Link("Visit willcodexquotareset.com", destination: ResetForecast.sourceURL)
          Text(
            "When enabled, Cowlick contacts willcodexquotareset.com to display its forecast. \(ResetForecast.disclaimer)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Quota", systemImage: "gauge.with.dots.needle.33percent") }

      ProviderAccountsView(
        controller: services.providerAccountsController,
        billingStore: services.providerBillingStore,
        usageStore: services.usageStore
      )
      .tabItem {
        Label("Accounts", systemImage: "person.2")
          .accessibilityIdentifier("settings-accounts-tab")
      }

      Form {
        Section("Caps Lock signal") {
          Toggle(
            "Enable Caps Lock signaling",
            isOn: Binding(
              get: { settings.capsLockEnabled },
              set: { value in setCapsLockEnabled(value) }
            ))
          LabeledContent("Support", value: capsStatus)
          Button("Test Caps Lock Signal") {
            Task {
              let result = await services.capsLockService.testSignal()
              capsStatus = result == .available ? "Native HID signal test passed" : result.summary
              if result != .available { settings.capsLockEnabled = false }
            }
          }
          .disabled(!settings.capsLockEnabled)
          Text(
            "Native HID control may require Input Monitoring or Accessibility permission. Cowlick never leaves Caps Lock changed after a pattern."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Section("Updates") {
          Toggle(
            "Automatically check for updates",
            isOn: Binding(
              get: { settings.automaticUpdateChecks },
              set: { value in
                settings.automaticUpdateChecks = value
                configureUpdates()
              }
            ))
          Toggle(
            "Automatically download updates",
            isOn: Binding(
              get: { settings.automaticUpdateDownloads },
              set: { value in
                settings.automaticUpdateDownloads = value
                configureUpdates()
              }
            ))
          Button("Check for Updates") { services.updateService.checkForUpdates() }
        }
        Section("Local data") {
          Button("Run Diagnostics") { WindowCoordinator.shared.openDiagnostics() }
          Button("Reset App State", role: .destructive) { confirmReset = true }
        }
      }
      .formStyle(.grouped)
      .tabItem {
        Label("System", systemImage: "gearshape.2")
          .accessibilityIdentifier("settings-system-tab")
      }
    }
    .frame(width: 600, height: 460)
    .task { await refreshStatus() }
    .confirmationDialog("Reset Cowlick state?", isPresented: $confirmReset) {
      Button("Reset", role: .destructive) {
        Task {
          services.sessionStore.reset()
          await services.usageStore.reset()
          services.settings.reset()
          await services.providerAccountsController.resetTransientState()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This clears in-memory sessions, diagnostics, billing results, and preferences. Provider accounts and their Keychain credentials remain. It does not remove Codex hooks."
      )
    }
  }

  private func refreshStatus() async {
    hookStatus = services.hookInstaller.status()
    await refreshHookTrust()
    launchAtLogin = LaunchAtLoginService.isEnabled
    capsStatus = await services.capsLockService.supportStatus().summary
  }

  private func refreshHookTrust() async {
    hookTrust = await services.hookTrustService.inspect()
  }

  private func checkAndRepairIntegration() {
    guard !integrationTaskInProgress else { return }
    integrationTaskInProgress = true
    integrationMessage = "Checking Cowlick's Codex connection…"
    Task {
      defer { integrationTaskInProgress = false }
      let result = await Task.detached { () -> HookTaskResult in
        let installer = HookInstaller()
        do {
          try installer.installOrRepair()
          return HookTaskResult(status: installer.status(), errorMessage: nil)
        } catch {
          return HookTaskResult(
            status: installer.status(), errorMessage: error.localizedDescription)
        }
      }.value
      hookStatus = result.status
      if result.errorMessage == nil {
        services.settings.integrationIntentionallyRemoved = false
      }
      hookTrust = await services.hookTrustService.inspect()
      integrationMessage = result.errorMessage ?? successfulIntegrationMessage
    }
  }

  private func removeIntegration() {
    guard !integrationTaskInProgress else { return }
    integrationTaskInProgress = true
    integrationMessage = "Removing…"
    Task {
      defer { integrationTaskInProgress = false }
      let result = await Task.detached { () -> HookTaskResult in
        let installer = HookInstaller()
        do {
          try installer.removeIntegration()
          return HookTaskResult(status: installer.status(), errorMessage: nil)
        } catch {
          return HookTaskResult(
            status: installer.status(), errorMessage: error.localizedDescription)
        }
      }.value
      hookStatus = result.status
      if result.errorMessage == nil {
        services.settings.integrationIntentionallyRemoved = true
      }
      integrationMessage = result.errorMessage ?? "Cowlick hooks and installed helper removed."
    }
  }

  private func revealHooks() {
    let url = services.hookInstaller.hooksURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }

  private func wingMetricGuidance(_ metric: NotchWingMetric) -> String {
    if metric == .resetProbability && !services.settings.showResetForecast {
      return "\(metric.detail) Enable the unofficial forecast in Quota."
    }
    return metric.detail
  }

  private var integrationStatusTitle: String {
    guard hookStatus.isHealthy else { return "Connection needs repair" }
    return switch hookTrust.state {
    case .trusted: "Cowlick is connected"
    case .needsReview: "Review needed in Codex"
    case .incomplete: "Connection needs repair"
    case .unavailable: "Connection could not be checked"
    case .notChecked: "Connection not checked"
    }
  }

  private var integrationStatusMessage: String {
    guard hookStatus.isHealthy else {
      return
        "Cowlick can safely install or repair its local hooks without replacing unrelated Codex configuration."
    }
    return CodexIntegrationPresentation.guidance(for: hookTrust.state)
  }

  private var integrationStatusSymbol: String {
    if hookStatus.isHealthy, hookTrust.state == .trusted { return "checkmark.circle.fill" }
    if hookTrust.state == .notChecked { return "questionmark.circle" }
    return "exclamationmark.triangle.fill"
  }

  private var integrationStatusColor: Color {
    if hookStatus.isHealthy, hookTrust.state == .trusted { return .green }
    if hookTrust.state == .notChecked { return .secondary }
    return NotchTheme.warning
  }

  private var successfulIntegrationMessage: String {
    switch hookTrust.state {
    case .trusted: "Connection checked. Cowlick is ready."
    case .needsReview: "Hooks are installed. Open Codex, paste /hooks, and approve Cowlick once."
    case .incomplete: "Codex still reports incomplete hooks. Check again or open Diagnostics."
    case .unavailable: "Hooks are installed, but Codex trust could not be checked."
    case .notChecked: "Hooks are installed."
    }
  }

  private func updateLaunchAtLogin(_ enabled: Bool) {
    do {
      try LaunchAtLoginService.setEnabled(enabled)
      launchAtLogin = LaunchAtLoginService.isEnabled
      launchError = ""
    } catch {
      launchAtLogin = LaunchAtLoginService.isEnabled
      launchError = error.localizedDescription
    }
  }

  private func setCapsLockEnabled(_ enabled: Bool) {
    if !enabled {
      services.settings.capsLockEnabled = false
      Task { await services.capsLockService.cancelAndRestore() }
      return
    }
    Task {
      let result = await services.capsLockService.testSignal()
      capsStatus = result == .available ? "Native HID signal test passed" : result.summary
      services.settings.capsLockEnabled = result == .available
      if result == .available { services.sessionStore.refreshCapsLockAttention(force: true) }
    }
  }

  private func configureUpdates() {
    services.updateService.configure(
      automaticChecks: services.settings.automaticUpdateChecks,
      automaticDownloads: services.settings.automaticUpdateDownloads
    )
  }
}
