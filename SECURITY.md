# Security policy

Report suspected vulnerabilities through a private [GitHub security advisory](https://github.com/henryvn27/cowlick/security/advisories/new). Do not include secrets, private prompts, or approval commands in a public issue. Supported security fixes are provided for the latest release.

## Security invariants

- No bridge error, timeout, parse failure, authentication failure, or stale response may become an approval.
- Approval decisions match one unexpired request UUID and cannot be reused.
- IPC is a private current-user Unix-domain socket authenticated by a random owner-only token.
- Bridge tool input is untrusted display data and is never executed.
- Hook stdout contains only the official Codex-compatible decision shape or a neutral Stop object.
- Existing Codex hooks and unknown fields survive install and removal.
- Update archives and appcasts are EdDSA signed; public releases are Developer ID signed, hardened, notarized, and stapled.
- Diagnostics never expose full prompts, commands, tokens, secrets, or private home paths.

Credential exposure, approval spoofing or reuse, arbitrary execution from bridge input, update-signature bypass, destructive configuration mutation, and diagnostics disclosure are reportable.

Repository: Cowlick
Version: development snapshot
