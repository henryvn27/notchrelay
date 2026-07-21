# Security and threat model

The sensitive asset is authority to approve a Codex operation. Codex and the helper cross into Cowlick over local IPC. Tool names, prompts, descriptions, and tool input are untrusted display data. Releases cross the update boundary.

| Threat | Control |
|---|---|
| Local process spoofs approval | Random owner-only token, current-UID peer check, private socket mode, UUID, expiration |
| One request gets another answer | Exact UUID match in app and helper; queue-head-only, single-use decisions |
| Failure approves | Every malformed, unavailable, stale, timeout, auth, and socket path emits no decision |
| Tool input executes | Decode, truncate/render, optionally copy; never execute |
| Hook output injects behavior | No stdout for status, `{}` for Stop, fixed official permission dictionaries |
| Installer destroys config | Locked merge/validate, optimistic re-read, unknown-field preservation, private backup, atomic replace, exact marker/command ownership |
| Update is replaced | Public-artifact gate requiring HTTPS, Sparkle EdDSA, Developer ID, Hardened Runtime, notarization, and stapling; no public artifact exists yet |
| Diagnostics disclose data | Bounded sanitized metadata; secret and home-component redaction; no full values logged |
| Local rollout content spoofs activity | Treat it as same-user, display-only, untrusted input; allowlist record and event types, require owner regular files inside the resolved session root, bound lines and startup tail, expire stale state, and grant it no approval authority |
| Activity observation exposes private transcript content | Extract only lifecycle metadata, keep raw buffers transient, and never display, log, or persist prompt, message, command, tool-input, or result fields |
| Chat-title lookup crosses sessions or exposes prompt content | Match an exact UUID in current-user-owned regular SQLite files, require a local-host catalog row, sanitize and bound values, retain them only in memory, keep prompt-derived fallback behind prompt previews, and clear all copies when disabled |
| Lifecycle recovery leaks private work | Owner-only directory and file modes, atomic replacement under a file lock, minimal fields only, 24-hour stale ceiling, no prompt or operation content |
| Local quota access exposes account identity | Ask the installed Codex app-server only for `account/rateLimits/read`; never read `auth.json` or call account identity methods |
| Billing credential leaks through metadata | Store only an opaque credential reference in owner-only metadata; store the credential as a device-only macOS Keychain item |
| One billing account receives another account's result | Separate UUID, credential reference, refresh token, snapshot, and error state per account; reject provider or account-ID mismatches |
| Provider response or error leaks a secret | Fixed HTTPS endpoints, bounded responses, strict decoding, sanitized errors, no authorization-header or credential logging |
| Billing totals imply complete or subscription-equivalent coverage | Label values as organization API billing, mark Anthropic partial because its official cost report excludes Priority Tier usage, keep OpenAI account-wide, and perform no cross-account aggregation or API-to-subscription conversion |
| Local token or trace logs inflate an API-price estimate | Allowlist token/model/turn fields, require exact Priority-tier records, bound streamed lines and trace bodies, deduplicate filesystem and cumulative identities, contain counter drops, exclude unresolved forks and unknown models, and label incomplete coverage as partial |
| API-price estimate is mistaken for a bill | Separate it from account billing; label it “This Mac” and “estimate only”; exclude tool fees and disclose the bundled pricing date |
| Third-party forecast is mistaken for Cowlick truth | Disabled by default; separate heading, source link, and no-warranty attribution in settings and every display |
| Third-party response attacks the app | HTTPS-only fixed endpoint, ephemeral session, 10-second timeout, 512 KiB limit, strict minimal decoding, display-only values, no persistence |

Cowlick defends against accidental messages and other users. A process already running as the same user can generally read that user's files or drive granted UI; the app does not claim to withstand a fully compromised account.

The local observer can affect only displayed lifecycle state. Exact approval requests and decisions require the authenticated synchronous hook path and a matching unexpired request UUID.

Chat-title lookup is a separate display-only path. Titles never enter the hook protocol, socket protocol, approval request identity, lifecycle ledger, logs, or diagnostics. Project directory identity remains available as secondary context and the fallback label.

Core features need no Accessibility permission. Caps Lock may require Input Monitoring or Accessibility and stays off until explicitly enabled and tested. See [SECURITY.md](../SECURITY.md).

Enabling the unofficial forecast expands the network trust boundary to willcodexquotareset.com. Cowlick does not authenticate to that site, send Codex content, accept executable instructions, or combine its response with approval decisions. A compromised response can at worst supply bounded display values before validation and clamping.

Adding an organization-billing account expands the network boundary to that provider's official billing API. OpenAI accounts use `https://api.openai.com/v1/organization/costs`; Anthropic accounts use `https://api.anthropic.com/v1/organizations/cost_report`. Credentials are scoped by the provider, retrieved from Keychain only for a refresh, and never reused across accounts. OpenAI organization costs are treated as account-wide. Anthropic coverage is partial because its official cost report excludes Priority Tier usage. This feature reports actual organization API charges only and stays separate from the local API-price equivalent, which has no account attribution and makes no network request.

The lifecycle ledger is a recovery aid inside the documented same-user boundary. Cowlick rejects ledger files that are not regular files owned by the current user with owner-only permissions. The helper updates it before attempting socket delivery, so an app crash does not erase future working state; a Stop event removes only its matching session. Recovered entries are explicitly unconfirmed and cannot create an active count or passive island on their own.

## Pre-release v1.0 security review

The launch review traced the shipped local-rollout input, IPC, approval, hook-output, installer, diagnostics, update, and script boundaries. The review found and fixed the following issues before release packaging:

- Socket acceptance and client processing were separated so a synchronous approval cannot block the listener.
- Approval request UUIDs are single-use for fifteen minutes, preventing a repeated identifier from aliasing a pending continuation.
- Both sides enforce the 1 MiB bound while reading, including newline-terminated overflow cases; hook stdin is read incrementally.
- Hook removal requires Cowlick's explicit marker, a recognized legacy marker, or an exact configured command. Installation uses a private lock, private backups, validation, optimistic conflict detection, and an atomic rename.
- Diagnostics remove home-directory components, credentials, authorization headers, control characters, and complete untrusted values before retention or logging.
- Local lifecycle decoding locks identity to the first session envelope, bounds lines and startup tails, preserves partial appends, recovers from dropped file events, and has no approval authority.
- Hook repair now replaces stale Cowlick-owned definitions instead of treating their marker alone as healthy; private socket metadata failures clean up the listening descriptor and fail closed.

Focused regression tests cover each control. A same-user process with access to the token file remains inside the documented local-account trust boundary; Cowlick does not claim isolation from a compromised user account.
