# Troubleshooting

## The island does not appear

Open Cowlick's menu-bar item and choose Test State → Working. Automatic mode uses the menu bar on a desktop or non-notched external display; choose Menu bar in Settings to use it on every display. Diagnostics should report the socket as listening.

## Codex events do not arrive

Read the Integration status before treating the socket as the problem. Cowlick installs its hook entries automatically during onboarding. If the status says review is required, start the Codex CLI, open `/hooks`, and trust the Cowlick commands once. This is a Codex security review, not manual hook configuration, and Codex does not run newly installed commands before it. If the integration is incomplete, choose Settings → Integration → Install or Repair, then review it in the Codex CLI `/hooks`. Codex may need a restart after a new command hook is installed.

Cowlick observes Working, Completed, Failed, and multiple-session state from bounded local Codex lifecycle records, so current activity can appear even before hook review. Trusted Codex hooks are the only input Cowlick accepts for exact permission requests; the local observer cannot approve, deny, or infer one. If activity remains absent, check “Local activity observation” in Diagnostics. Codex surfaces that do not write the current local session-record format still require trusted hooks. After a Cowlick restart, older ledger-only entries are shown as “Unconfirmed after restart” until local observation or a hook confirms them; the 24-hour safety ceiling removes abandoned entries.

## Approval also appears in Codex

This is the safe fallback when Cowlick is unavailable, expired, malformed, mismatched, or disconnected. It never turns that condition into Allow.

## Caps Lock is unavailable

The island works independently. If Settings reports a permission error, grant Input Monitoring or Accessibility to Cowlick, reopen it, and run the safe test. Support varies by keyboard and macOS policy.

## Codex quota is unavailable

Cowlick reads quota from one local Codex identity: the identity active in the Codex executable Cowlick selects. It checks `COWLICK_CODEX_PATH` first when set, then the running Codex app, installed Codex or ChatGPT apps, and known CLI paths. A candidate must answer `codex --version` before use. Update or reinstall Codex if Settings → Quota reports that its executable or app-server is unavailable. Cowlick does not need or read `~/.codex/auth.json` and does not switch subscription accounts.

## The quota estimate is unavailable

The time-to-empty estimate needs a valid reset window, at least 3% of that window elapsed, and at least 1% observed use. Before that, Cowlick shows the current used or remaining value without pretending it knows when the quota will run out. The marker still represents an even pace through the reset window.

## The API-price equivalent is partial or unavailable

Cowlick prices only local Codex token counters with a supported exact or reviewed alias model name. It uses bounded local `logs_2.sqlite` metadata only when an exact turn is marked `service_tier: priority`; missing or unreadable Priority metadata falls back to Standard rates and marks coverage partial. Unknown models, unresolved fork lineages, malformed or oversized records, and tool-call fees are excluded instead of guessed. “Partial” means the displayed amount is a conservative subtotal for this Mac, not that excluded work cost zero. Refresh from the menu or Settings → Quota after the current Codex turn records its next token-count event.

## Organization billing is unavailable

Settings → Accounts supports separately labeled OpenAI API and Anthropic API organization-billing accounts. Choose Add Account and enter an alias plus an Admin API key with access to the provider's official organization cost endpoint; ordinary project API keys may not have that access. Opening Accounts or choosing Refresh requests month-to-date data separately per account. OpenAI organization costs are account-wide. Anthropic's official cost report excludes Priority Tier usage, so its coverage is partial. Cowlick does not combine providers, and this actual billing data remains separate from Codex subscription quota and the local API-price equivalent.

If a refresh fails, verify that the selected alias is the intended organization and replace its credential. Removing an account removes its Keychain credential and only that account's metadata.

## The unofficial reset forecast is unavailable

The forecast is a separate, optional request to willcodexquotareset.com. Open the menu again after 30 seconds or try Refresh Now in Settings → Quota; Cowlick also shows when the website payload was fetched. Disabling it removes the data immediately and stops Cowlick from contacting that site. Its score is third-party data, not a Cowlick estimate or guarantee.

## Sharing diagnostics

Export from Diagnostics and review before sharing. Reports omit full prompts, commands, tokens, and home-directory usernames.
