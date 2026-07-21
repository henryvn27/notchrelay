# Security policy

Report suspected vulnerabilities through a private [GitHub security advisory](https://github.com/henryvn27/cowlick/security/advisories/new). Do not include secrets, private prompts, or approval commands in a public issue. Before the first public release, security fixes are maintained on the default branch; after releases begin, the latest published version will be the supported release line.

## Security invariants

- No bridge error, timeout, parse failure, authentication failure, or stale response may become an approval.
- Approval decisions match one unexpired request UUID and cannot be reused.
- IPC is a private current-user Unix-domain socket authenticated by a random owner-only token.
- Bridge tool input is untrusted display data and is never executed.
- Local Codex lifecycle observation is untrusted and display-only; it cannot create an approval request or decision.
- Hook stdout contains only the official Codex-compatible decision shape or a neutral Stop object.
- Existing Codex hooks and unknown fields survive install and removal.
- Organization billing credentials remain in macOS Keychain; owner-only account metadata contains only aliases and opaque references.
- Billing results and refresh state are isolated by account UUID, and Cowlick performs no cross-provider aggregation.
- Every public update archive and appcast must be EdDSA signed; every public app release must be Developer ID signed, hardened, notarized, and stapled. The [GitHub Releases page](https://github.com/henryvn27/cowlick/releases) is the source of truth for published versions.
- Diagnostics never expose full prompts, commands, tokens, secrets, or private home paths.

Credential exposure, cross-account billing disclosure, approval spoofing or reuse, arbitrary execution from bridge input, update-signature bypass, destructive configuration mutation, and diagnostics disclosure are reportable.

Repository: Cowlick

Supported version: the latest published release; before the first release, security fixes are maintained on `main`.
