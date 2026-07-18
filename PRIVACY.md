# Privacy

Cowlick is local-first and has no analytics. Prompt and result previews are disabled by default. Full approval operations are held only long enough to show or copy a pending request.

## Stored data

`~/Library/Application Support/Cowlick/` contains the owner-only bridge token, runtime metadata, installed helper, sanitized local logs when present, and `active-sessions.json`. That recovery ledger stores only the current working sessions' Codex session ID, turn ID, working directory, model when supplied, and last lifecycle timestamp. It is written atomically with owner-only permissions, prunes entries older than 24 hours, and never contains prompts, commands, results, approvals, tokens, or transcripts. It is current lifecycle state, not a session-history database.

`~/.codex/hooks.json` contains four merged command handlers, with a timestamped backup before changes. `~/.local/bin/cowlick-hook` is a symlink to the installed helper. Preferences use `com.henryvn27.Cowlick`.

On a one-time upgrade from the development name NotchRelay, Cowlick reads only known preference keys, replaces only exact or marked legacy hook handlers, and removes the legacy helper after the new integration is installed successfully. Unrelated Codex configuration is preserved.

The app makes Sparkle update checks to the GitHub release feed. Links open only when the user selects them. There is no cloud account, advertising, or crash-reporting SDK.

Official Codex quota is read from the Codex app-server process already installed on the Mac. Cowlick requests only rate-limit data, does not read Codex's account file, and does not save quota history.

The optional “Will Codex Reset?” forecast is disabled by default. When enabled, Cowlick makes an HTTPS request to `https://www.willcodexquotareset.com/api/forecast`. Opening the menu can refresh data older than 30 seconds; other automatic refresh triggers use a 15-minute freshness interval, and a manual refresh is immediate. There is no polling timer. The site receives the normal information inherent in a web request, such as the user's IP address and Cowlick user-agent. Cowlick decodes only the forecast score, reset-announced flag, and refresh timestamps; it does not persist the response or history. This is third-party data shown as provided. It is not Cowlick data or a Cowlick estimate, and Cowlick does not warrant it.

Core behavior needs no special privacy permission. Optional Caps Lock signaling may require Input Monitoring or Accessibility depending on macOS and hardware; the app asks only when that independent feature is enabled.

Reset Local State clears in-memory state and preferences. Hook removal affects only Cowlick and recognized legacy handlers. Homebrew users can completely remove stored data with `brew uninstall --cask --zap cowlick`.
