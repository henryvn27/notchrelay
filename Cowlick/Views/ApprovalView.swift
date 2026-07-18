import AppKit
import SwiftUI

struct ApprovalView: View {
  let request: ApprovalRequest
  let allow: () -> Void
  let deny: () -> Void
  let openCodex: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
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

      Text(request.operationPreview)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.76))
        .lineLimit(2)

      HStack(spacing: 8) {
        Button("Deny", role: .destructive, action: deny)
          .keyboardShortcut("d", modifiers: [.command])
          .accessibilityHint("Reject this exact approval request")
        Button("Open Codex", action: openCodex)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(request.fullOperation, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .help("Copy full operation")
        .accessibilityLabel("Copy full operation")
        Spacer()
        Button("Allow once", action: allow)
          .buttonStyle(.bordered)
          .accessibilityHint("Allow only this exact approval request")
      }
      .controlSize(.small)
    }
    .padding(16)
  }
}
