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

  var body: some View {
    @Bindable var settings = services.settings

    TabView {
      Form {
        Section("Appearance") {
          Toggle("Show prompt previews", isOn: $settings.showPromptPreviews)
          Toggle("Show result previews", isOn: $settings.showResultPreviews)
          Picker("Show completion for", selection: $settings.completionVisibility) {
            ForEach(CompletionVisibility.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Automatically expand approvals", isOn: $settings.autoExpandApprovals)
          Toggle("Show on displays without a notch", isOn: $settings.showOnNonNotch)
          Picker("Preferred display", selection: $settings.preferredDisplay) {
            ForEach(PreferredDisplay.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Reduce Cowlick animation", isOn: $settings.reducedAnimation)
        }
        Section("System") {
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
        Section("Codex integration") {
          LabeledContent("Configuration", value: hookStatus.summary)
          LabeledContent("Codex trust", value: hookTrust.state.summary)
          Stepper(value: $settings.approvalTimeout, in: 5...60, step: 5) {
            LabeledContent("Approval fallback", value: "\(Int(settings.approvalTimeout)) seconds")
          }
          HStack {
            Button("Install or Repair") { installHooks() }
            Button("Remove Hooks") { removeHooks() }
            Button("Reveal Configuration") { revealHooks() }
          }
          if !integrationMessage.isEmpty {
            Text(integrationMessage).font(.caption).foregroundStyle(.secondary)
          }
          Text(hookTrustGuidance)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section("Test integration") {
          HStack {
            Button("Working") { services.sessionStore.testState(.working) }
            Button("Approval") { services.sessionStore.testState(.approvalRequested) }
            Button("Completed") { services.sessionStore.testState(.completed) }
            Button("Failed") { services.sessionStore.testState(.failed) }
          }
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
          Picker("Primary quota metric", selection: $settings.usageMetricPreference) {
            ForEach(UsageMetricPreference.allCases, id: \.self) { preference in
              Text(preference.label).tag(preference)
            }
          }
          .pickerStyle(.segmented)
          Text("Cowlick uses this percentage in the menu bar and quota views.")
            .font(.caption)
            .foregroundStyle(.secondary)
          LabeledContent("Status", value: services.usageStore.officialStatus)
          Text(
            "Cowlick reads this from the Codex app installed on your Mac. It does not read your Codex account file or save quota history."
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
        Section {
          Button("Refresh Now") { services.usageStore.refreshIfNeeded(force: true) }
            .disabled(services.usageStore.isRefreshing)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Quota", systemImage: "gauge.with.dots.needle.33percent") }

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
      .tabItem { Label("Signals", systemImage: "light.beacon.max") }
    }
    .frame(width: 600, height: 460)
    .task { await refreshStatus() }
    .confirmationDialog("Reset Cowlick state?", isPresented: $confirmReset) {
      Button("Reset", role: .destructive) {
        services.sessionStore.reset()
        services.usageStore.reset()
        services.settings.reset()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This clears in-memory sessions, diagnostics, and preferences. It does not remove Codex hooks."
      )
    }
  }

  private func refreshStatus() async {
    hookStatus = services.hookInstaller.status()
    hookTrust = await services.hookTrustService.inspect()
    launchAtLogin = LaunchAtLoginService.isEnabled
    capsStatus = await services.capsLockService.supportStatus().summary
  }

  private func installHooks() {
    integrationMessage = "Installing…"
    Task {
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
      hookTrust = await services.hookTrustService.inspect()
      integrationMessage = result.errorMessage ?? hookTrustGuidance
    }
  }

  private func removeHooks() {
    integrationMessage = "Removing…"
    Task {
      let result = await Task.detached { () -> HookTaskResult in
        let installer = HookInstaller()
        do {
          try installer.removeHooks()
          return HookTaskResult(status: installer.status(), errorMessage: nil)
        } catch {
          return HookTaskResult(
            status: installer.status(), errorMessage: error.localizedDescription)
        }
      }.value
      hookStatus = result.status
      integrationMessage = result.errorMessage ?? "Cowlick hook entries removed."
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

  private var hookTrustGuidance: String {
    switch hookTrust.state {
    case .trusted:
      "Cowlick is trusted. New Codex prompts will report working and completion states."
    case .needsReview:
      "Open /hooks in Codex and trust the four Cowlick commands once. Codex will not run them before review."
    case .incomplete:
      "Install or repair the integration, then review Cowlick in Codex /hooks."
    case .notChecked, .unavailable:
      "Codex may require a one-time review in /hooks after installation."
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
    }
  }

  private func configureUpdates() {
    services.updateService.configure(
      automaticChecks: services.settings.automaticUpdateChecks,
      automaticDownloads: services.settings.automaticUpdateDownloads
    )
  }
}
