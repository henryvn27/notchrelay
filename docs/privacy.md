# Privacy details

- Prompt and result previews default off.
- Full prompts and approval operations are not persisted.
- Restart recovery persists only current working-session IDs, turn IDs, working directories, optional model names, and timestamps in an owner-only ledger; entries expire after 24 hours.
- Completed sessions are removed after 15 minutes.
- Diagnostics retain only ten sanitized events and ten errors in memory.
- No analytics or crash SDK is linked.
- No localhost server or external backend exists.
- Official quota comes from the local Codex app-server and is not persisted.
- Cowlick watches current local Codex session JSONL with FSEvents while running. It retains only allowlisted lifecycle metadata in memory; raw line buffers are transient, and private prompt, message, tool, command, and result payloads are not extracted, logged, displayed, or persisted. This path makes no network request and has no approval authority.
- “Show Codex chat names” reads exact-session short names from the local-host catalog in `~/.codex/sqlite/codex-dev.db`, read-only. Names are sanitized, bounded, memory-only, never enter IPC or diagnostics, and are cleared immediately when disabled. If prompt previews are also enabled, Cowlick may use the exact session's prompt-derived `threads.title` in `~/.codex/state_5.sqlite` as a fallback. Neither source affects approval routing or decisions.
- The optional API-price equivalent scans local Codex session files and reads bounded `response.create` rows from `~/.codex/logs_2.sqlite` read-only. It retains only allowlisted rollout identity, model, turn ID, timestamp, numeric token counters, and exact Priority-turn matches. Sanitized file summaries and matched IDs stay in memory; raw trace bodies and prompt/tool content are never retained or logged. It makes no network request and is labeled as this-Mac partial coverage when metadata is unavailable or ambiguous.
- Cowlick uses the single Codex subscription identity active in its selected local Codex executable. It does not read, import, or switch Codex authentication files.
- Optional organization-billing accounts are limited to OpenAI API and Anthropic API. Account aliases and opaque credential references are stored in owner-only metadata; admin credentials are stored in macOS Keychain.
- Organization billing is fetched separately per account for the current month and held in memory. OpenAI organization costs are account-wide. Anthropic coverage is partial because its official cost report excludes Priority Tier usage. Cowlick does not aggregate accounts or providers and does not save billing history.
- Sparkle update checks and user-opened links are network paths.
- The optional reset forecast adds an HTTPS request to willcodexquotareset.com only after explicit opt-in; its response is attributed, minimally decoded, and kept in memory. Menu presentation may refresh data older than 30 seconds; no timer polls it.

Opening Settings → Accounts refreshes every saved billing account. Refresh All and each account's Refresh action also initiate a request. Cowlick contacts only the API belonging to that account:

- OpenAI API: `https://api.openai.com/v1/organization/costs`
- Anthropic API: `https://api.anthropic.com/v1/organizations/cost_report`

Those providers receive the administrator credential required by their billing API, the requested month-to-date interval, and normal HTTPS request metadata such as the user's IP address and Cowlick user-agent. Cowlick does not send Codex prompts, approval operations, or data from another provider.

The API-price-equivalent scan is not an organization-billing request. It runs locally after a Codex lifecycle event, a menu presentation, or a user refresh, with a freshness guard and no idle timer. It never sends the scanned model names or token counts to OpenAI, Cowlick, or another service.

Normal uninstall preserves saved provider accounts and their Keychain credentials. The contributor-only `./Scripts/uninstall_local.sh --purge` command verifies that every credential referenced by `provider-accounts.json` is absent from Keychain before removing that metadata. If Keychain access or verification fails, purge stops and preserves the metadata for a safe retry. Homebrew's declarative zap cannot remove Keychain items, so the cask preserves provider-account metadata and tells users to remove saved accounts in Cowlick before requesting zap.

The stored-file and permission inventory is in [PRIVACY.md](../PRIVACY.md).
