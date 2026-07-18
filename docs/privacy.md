# Privacy details

- Prompt and result previews default off.
- Full prompts and approval operations are not persisted.
- Restart recovery persists only current working-session IDs, turn IDs, working directories, optional model names, and timestamps in an owner-only ledger; entries expire after 24 hours.
- Completed sessions are removed after 15 minutes.
- Diagnostics retain only ten sanitized events and ten errors in memory.
- No analytics or crash SDK is linked.
- No localhost server or external backend exists.
- Official quota comes from the local Codex app-server and is not persisted.
- Sparkle update checks and user-opened links are network paths.
- The optional reset forecast adds an HTTPS request to willcodexquotareset.com only after explicit opt-in; its response is attributed, minimally decoded, and kept in memory. Menu presentation may refresh data older than 30 seconds; no timer polls it.

The stored-file and permission inventory is in [PRIVACY.md](../PRIVACY.md).
