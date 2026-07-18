# Launch copy

## X / Twitter

NotchRelay puts local Codex status and approval actions at the MacBook notch.

Working, multi-session, completed, and failed states. Allow once or Deny matches the exact permission request, with safe fallback to Codex. Native Swift, local only, open source.

Source and demo: https://github.com/henryvn27/notchrelay

Signed downloads and Homebrew installation will be announced only after the Apple release gates pass.

## Hacker News

**Show HN: NotchRelay – a local macOS notch companion for Codex**

NotchRelay is a native SwiftUI/AppKit utility that shows local Codex lifecycle state around the MacBook notch, with a top-center fallback on other Macs. It can return Allow once or Deny for official synchronous permission hooks. Every decision matches a unique request; failures and timeouts return no decision so Codex keeps its prompt. No accounts, analytics, transcript parsing, or cloud backend. MIT licensed.

## Reddit

I built NotchRelay, an open-source native macOS companion for Codex. It shows working, approval, completion, failure, and multiple-session state near the notch. Supported permission hooks can be allowed once or denied there; unavailable or failed IPC always falls back to Codex. Prompt previews are off by default.

Source and demo: https://github.com/henryvn27/notchrelay

Signed downloads and Homebrew installation are not available yet.

## Product Hunt

NotchRelay is a native, local-first macOS status companion for OpenAI Codex. It keeps active projects, approvals, completion, and failures visible at the MacBook notch without becoming another client. Decisions are explicit, request-matched, and fail safely back to Codex. Open source, no account, no analytics, no backend.

## GitHub release notes draft

Do not publish these notes until the signed, notarized artifacts and Homebrew cask pass release verification.

NotchRelay 1.0.0 introduces a native notch and menu-bar companion for local Codex sessions: working and multi-session status, safe request-matched approvals, completion and failure feedback, non-notch support, optional Caps Lock signals, private authenticated IPC, reversible hook onboarding, signed updates, and sanitized diagnostics. Requires macOS 14+. Universal for Apple Silicon and Intel.
