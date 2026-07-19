# Troubleshooting

## The island does not appear

Use the menu-bar icon and choose Test State → Working. Enable “Show on displays without a notch” when using a desktop or external display. Diagnostics should report the socket as listening.

## Codex events do not arrive

Read the Integration status before treating the socket as the problem. Cowlick installs its hook entries automatically during onboarding. If the status says review is required, start the Codex CLI, open `/hooks`, and trust the four Cowlick commands once. This is a Codex security review, not manual hook configuration, and Codex does not run newly installed commands before it. If the integration is incomplete, choose Settings → Integration → Install or Repair, then review it in the Codex CLI `/hooks`. Codex may need a restart after a new command hook is installed.

Cowlick counts sessions from verified lifecycle hooks. Tasks that were already working before Cowlick's hooks were installed cannot be backfilled safely; they appear after their next submitted prompt or permission request. After a Cowlick restart, ledger entries are shown as “Unconfirmed after restart,” but do not count as active or reopen the passive island until a new hook confirms them. Their matching Stop hook removes them, and the 24-hour safety ceiling removes abandoned entries.

## Approval also appears in Codex

This is the safe fallback when Cowlick is unavailable, expired, malformed, mismatched, or disconnected. It never turns that condition into Allow.

## Caps Lock is unavailable

The island works independently. If Settings reports a permission error, grant Input Monitoring or Accessibility to Cowlick, reopen it, and run the safe test. Support varies by keyboard and macOS policy.

## Codex quota is unavailable

Cowlick reads quota from one local Codex identity: the identity active in the Codex executable Cowlick selects. It checks `COWLICK_CODEX_PATH` first when set, then the running Codex app, installed Codex or ChatGPT apps, and known CLI paths. A candidate must answer `codex --version` before use. Update or reinstall Codex if Settings → Quota reports that its executable or app-server is unavailable. Cowlick does not need or read `~/.codex/auth.json` and does not switch subscription accounts.

## The quota estimate is unavailable

The time-to-empty estimate needs a valid reset window, at least 3% of that window elapsed, and at least 1% observed use. Before that, Cowlick shows the current used or remaining value without pretending it knows when the quota will run out. The marker still represents an even pace through the reset window.

## Organization billing is unavailable

Settings → Accounts supports separately labeled OpenAI API and Anthropic API organization-billing accounts. Choose Add Account and enter an alias plus an Admin API key with access to the provider's official organization cost endpoint; ordinary project API keys may not have that access. Opening Accounts or choosing Refresh requests month-to-date data separately per account. OpenAI organization costs are account-wide. Anthropic's official cost report excludes Priority Tier usage, so its coverage is partial. Cowlick does not combine providers, and this data is not the Codex subscription quota or an API-equivalent estimate.

If a refresh fails, verify that the selected alias is the intended organization and replace its credential. Removing an account removes its Keychain credential and only that account's metadata.

## The unofficial reset forecast is unavailable

The forecast is a separate, optional request to willcodexquotareset.com. Open the menu again after 30 seconds or try Refresh Now in Settings → Quota; Cowlick also shows when the website payload was fetched. Disabling it removes the data immediately and stops Cowlick from contacting that site. Its score is third-party data, not a Cowlick estimate or guarantee.

## Sharing diagnostics

Export from Diagnostics and review before sharing. Reports omit full prompts, commands, tokens, and home-directory usernames.
