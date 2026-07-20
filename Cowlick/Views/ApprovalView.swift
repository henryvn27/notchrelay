import AppKit
import SwiftUI

struct ApprovalView: View {
  let request: ApprovalRequest
  let allow: () -> Void
  let deny: () -> Void
  let openCodex: () -> Void
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(NotchTheme.warning)
        Text(request.projectName)
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Text(request.toolName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.white.opacity(0.52))
      }

      Text(request.reasonPreview)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.white.opacity(0.76))
        .lineLimit(2)
        .accessibilityLabel("Reason: \(request.reasonPreview)")

      if request.showsDistinctOperation {
        Text(request.operationPreview)
          .font(.system(size: 11.5, weight: .regular, design: .monospaced))
          .foregroundStyle(.white.opacity(0.58))
          .lineLimit(2)
          .textSelection(.enabled)
          .accessibilityLabel("Operation: \(request.operationPreview)")
      }

      HStack(spacing: 8) {
        Button("Deny", role: .destructive, action: deny)
          .keyboardShortcut("d", modifiers: [.command])
          .accessibilityHint("Reject this exact approval request")
        Button("Open Codex", action: openCodex)
        Button {
          copyOperation()
        } label: {
          if copied {
            Label("Copied", systemImage: "checkmark")
          } else {
            Image(systemName: "doc.on.doc")
          }
        }
        .help(copied ? "Full operation copied" : "Copy full operation")
        .accessibilityLabel(copied ? "Full operation copied" : "Copy full operation")
        Spacer()
        Button("Allow once", action: allow)
          .buttonStyle(.bordered)
          .accessibilityHint("Allow only this exact approval request")
      }
      .controlSize(.small)
    }
    .padding(14)
    .onDisappear { copyResetTask?.cancel() }
  }

  private func copyOperation() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(request.fullOperation, forType: .string)
    copied = true
    AccessibilityNotification.Announcement("Full operation copied").post()
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      copied = false
    }
  }
}
