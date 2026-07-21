import AppKit
import SwiftUI

struct ApprovalView: View {
  let request: ApprovalRequest
  let isAttached: Bool
  let allow: () -> Void
  let deny: () -> Void
  let openCodex: () -> Void
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if isAttached {
        Text(request.toolName)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(secondaryTextColor)
      } else {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(NotchTheme.warning)
          VStack(alignment: .leading, spacing: 1) {
            Text(request.displayName)
              .font(.system(size: 13, weight: .semibold))
            if let project = request.projectContext {
              Text(project)
                .font(.system(size: 10.5))
                .foregroundStyle(secondaryTextColor)
            }
          }
          Spacer()
          Text(request.toolName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(secondaryTextColor)
        }
      }

      Text(request.reasonPreview)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(primaryTextColor.opacity(isAttached ? 0.82 : 0.92))
        .lineLimit(2)
        .accessibilityLabel("Reason: \(request.reasonPreview)")

      if request.showsDistinctOperation {
        Text(request.operationPreview)
          .font(.system(size: 11.5, weight: .regular, design: .monospaced))
          .foregroundStyle(secondaryTextColor)
          .lineLimit(2)
          .textSelection(.enabled)
          .accessibilityLabel("Operation: \(request.operationPreview)")
      }

      HStack(spacing: 8) {
        Button("Deny", action: deny)
          .buttonStyle(.bordered)
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
        .frame(minWidth: 28, minHeight: 24)
        Spacer()
        Button("Allow once", action: allow)
          .buttonStyle(.bordered)
          .accessibilityHint("Allow only this exact approval request")
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .onDisappear { copyResetTask?.cancel() }
  }

  private var primaryTextColor: Color { isAttached ? .white : .primary }

  private var secondaryTextColor: Color {
    isAttached ? .white.opacity(0.60) : .secondary
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
