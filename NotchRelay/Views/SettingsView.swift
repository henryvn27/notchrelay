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
          Toggle("Reduce NotchRelay animation", isOn: $settings.reducedAnimation)
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
          LabeledContent("Status", value: hookStatus.summary)
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
          Text(
            "Codex may ask you to review and trust the new hook. Open /hooks in Codex after installation."
          )
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
            "Native HID control may require Input Monitoring or Accessibility permission. NotchRelay never leaves Caps Lock changed after a pattern."
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
    .confirmationDialog("Reset NotchRelay state?", isPresented: $confirmReset) {
      Button("Reset", role: .destructive) {
        services.sessionStore.reset()
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
      integrationMessage =
        result.errorMessage ?? "Installed. Review and trust NotchRelay in Codex /hooks."
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
      integrationMessage = result.errorMessage ?? "NotchRelay hook entries removed."
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
