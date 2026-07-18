# Troubleshooting

## The island does not appear

Use the menu-bar icon and choose Test State → Working. Enable “Show on displays without a notch” when using a desktop or external display. Diagnostics should report the socket as listening.

## Codex events do not arrive

In Settings → Integration, choose Install or Repair. Then open `/hooks` in Codex and review or trust the Cowlick command if prompted. Codex may need a restart after a new command hook is installed.

Cowlick counts sessions from verified lifecycle hooks. Tasks that were already working before Cowlick's hooks were installed cannot be backfilled safely; they appear after their next submitted prompt or permission request. Once observed, current working sessions survive a Cowlick restart until their matching Stop hook arrives or the 24-hour safety ceiling expires.

## Approval also appears in Codex

This is the safe fallback when Cowlick is unavailable, expired, malformed, mismatched, or disconnected. It never turns that condition into Allow.

## Caps Lock is unavailable

The island works independently. If Settings reports a permission error, grant Input Monitoring or Accessibility to Cowlick, reopen it, and run the safe test. Support varies by keyboard and macOS policy.

## Codex quota is unavailable

Cowlick reads quota from the Codex app installed on the Mac. Update or reinstall Codex if Settings → Quota reports that its executable or app-server is unavailable. Cowlick does not need or read `~/.codex/auth.json`.

## The unofficial reset forecast is unavailable

The forecast is a separate, optional request to willcodexquotareset.com. Open the menu again after 30 seconds or try Refresh Now in Settings → Quota; Cowlick also shows when the website payload was fetched. Disabling it removes the data immediately and stops Cowlick from contacting that site. Its score is third-party data, not a Cowlick estimate or guarantee.

## Sharing diagnostics

Export from Diagnostics and review before sharing. Reports omit full prompts, commands, tokens, and home-directory usernames.
