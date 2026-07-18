# Cowlick 1.0 security review

This review covers the public v1 source tree. It treats hook input, tool input, prompts, local IPC clients, existing hook configuration, update metadata, and release workflow inputs as security-sensitive boundaries.

## Validation rubric

| Criterion | Required evidence | Result |
|---|---|---|
| Approval fails closed | Every malformed, unavailable, stale, mismatched, duplicate, or timed-out path yields no Codex decision | Satisfied by focused protocol, bridge-client, and session-store tests |
| IPC is bounded and authenticated | Private socket and token, current-UID peer, strict protocol/version, 1 MiB read bound | Satisfied by code trace and socket integration tests |
| Configuration changes preserve ownership | Unknown fields and unrelated handlers survive install/remove; concurrent changes are not overwritten | Satisfied by installer tests and atomic-write controls |
| Untrusted content is inert and sanitized | No tool input execution; no complete private content in logs or diagnostics | Satisfied by code trace and diagnostics tests |
| Release authority is explicit | Hardened Runtime, Developer ID, notarization, stapling, EdDSA appcast, no ad hoc public package | Enforced by release scripts; public artifact validation requires account credentials |

## Candidate closure

| Candidate | Source / control / sink | Validation | Disposition |
|---|---|---|---|
| Socket listener starvation | Local client / separate accept and concurrent client queues plus receive timeout / synchronous approval wait | Code trace and bridge smoke test | Remediated |
| Approval identifier reuse | Repeated local UUID / fifteen-minute single-use registry and queue-head match / continuation resolution | Focused unit test | Remediated |
| Oversized input allocation or newline bypass | Hook stdin or socket bytes / incremental bounded reads / JSON decoding | Boundary tests at and beyond 1 MiB | Remediated |
| Hook installer over-removal or stale overwrite | Existing `hooks.json` / marker-or-exact-command ownership, lock, optimistic re-read / atomic replace | Merge, removal, unrelated-field, and idempotency tests | Remediated |
| Diagnostics disclosure or log injection | Untrusted paths/errors / credential, path, and control-character sanitization / retained diagnostics and Logger | Focused unit tests | Remediated |

No candidate survived validation as a known launch-blocking vulnerability. The relevant residual boundary is deliberate: another process already running as the same macOS user may be able to read that user's files and operate granted UI permissions.

## Release workflow review

The release workflow accepts certificate and notarization values only through GitHub Actions secrets, imports the certificate into an ephemeral keychain, signs the app and embedded helper with Developer ID, notarizes and staples the app before rebuilding the public containers, separately notarizes and staples the final DMG, verifies with `codesign`, `spctl`, and `hdiutil`, signs the Sparkle update with EdDSA, and then renders the cask checksum. The repository contains no certificate, private key, Apple password, or notarization credential.

The local packaging scripts refuse to create a public release package when a Developer ID Application identity is unavailable. This is intentional fail-closed behavior, not a development fallback.
