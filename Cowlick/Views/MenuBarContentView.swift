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
    HStack(spacing: 4) {
      Image(nsImage: Self.menuBarIcon)
        .renderingMode(.original)
      if !labelText.isEmpty {
        Text(labelText)
      }
    }
    .fixedSize()
    .accessibilityLabel(accessibilityText)
  }

  private var labelText: String {
    let sessions = store.activeSessionCount > 0 ? "\(store.activeSessionCount)" : nil
    let usage =
      settings.showCodexUsage
      ? usageStore.primaryDisplayedPercent.map { "\(Int($0.rounded()))%" }
      : nil
    return [sessions, usage].compactMap { $0 }.joined(separator: " · ")
  }

  private var accessibilityText: String {
    let status = store.displaySession?.status.shortLabel ?? "Idle"
    guard let usage = usageStore.primaryMetricAccessibilityLabel, settings.showCodexUsage else {
      return "Cowlick, \(status)"
    }
    return "Cowlick, \(status), \(usage)"
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
    }
  }

  private func header(store: SessionStore) -> some View {
    HStack(spacing: 10) {
      Image(systemName: stateIcon(store.displaySession?.status))
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(stateColor(store.displaySession?.status))
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(headerTitle(store))
          .font(.headline)
        Text(activitySummary(store))
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
            Image(systemName: stateIcon(session.status))
              .foregroundStyle(stateColor(session.status))
              .frame(width: 14)
            Text(session.projectName)
              .lineLimit(1)
            Spacer()
            Text(session.status.shortLabel)
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

  private func activitySummary(_ store: SessionStore) -> String {
    if store.activeSessionCount > 0 {
      return
        "\(store.activeSessionCount) active \(store.activeSessionCount == 1 ? "session" : "sessions")"
    }
    switch hookTrust.state {
    case .needsReview:
      return "Trust Cowlick in Codex /hooks"
    case .incomplete:
      return "Open Settings to repair integration"
    case .notChecked, .trusted, .unavailable:
      break
    }
    return "No recent Codex activity"
  }

  private func headerTitle(_ store: SessionStore) -> String {
    if let status = store.displaySession?.status { return status.shortLabel }
    switch hookTrust.state {
    case .needsReview: return "Codex review required"
    case .incomplete: return "Integration needs repair"
    case .notChecked, .trusted, .unavailable: return "Idle"
    }
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
