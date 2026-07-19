# Release guide

Public artifacts must never be ad hoc signed.

Run source preflight before creating a tag:

```sh
./Scripts/release_preflight.sh 1.0.0 --source-only
./Scripts/test_release_scripts.sh
```

Required GitHub Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY_BASE64`
- `SPARKLE_PRIVATE_KEY`
- `HOMEBREW_TAP_TOKEN` with Contents write access only to the tap

Never print or commit these values. The Developer ID certificate secret is a base64-encoded `.p12`; the notary key secret is the base64-encoded App Store Connect API `.p8`. `HOMEBREW_TAP_TOKEN` should be a fine-grained token with Contents write access only to `henryvn27/homebrew-cowlick`.

Before a tag, update versions and changelog, run a clean build/test, and execute a local candidate:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: …" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARYTOOL_PROFILE="cowlick-notary" \
SPARKLE_PRIVATE_KEY="…" \
./Scripts/create_release.sh 1.0.0
```

`create_release.sh` runs distribution preflight, including an exact Sparkle private/public-key match. Run `./Scripts/verify_update_signing.sh` separately to prove archive and signed-feed verification with an ephemeral test key. Execute the UI suite on an interactive logged-in Mac; hosted CI compiles it but intentionally does not claim headless execution.

Pushing `v1.0.0` from the current head of protected `main` runs the release workflow. A separate read-only provenance job verifies that the tag is the exact current `main` commit before any release secret or tagged repository script is used. The release job then performs isolated ephemeral keychain setup, universal archive, Developer ID export, app notarization and stapling, final DMG notarization and stapling, signed appcast, GitHub release, and real-SHA cask update. It also refuses a tag that does not match `MARKETING_VERSION` or lacks any required secret.

After publishing, verify from a clean user account:

```sh
brew install --cask henryvn27/cowlick/cowlick
codesign --verify --deep --strict ~/Applications/Cowlick.app 2>/dev/null || \
  codesign --verify --deep --strict /Applications/Cowlick.app
spctl --assess --type execute --verbose=2 /Applications/Cowlick.app
```

Complete onboarding without Terminal, run working/approval/completed tests, verify a signed Sparkle update from an older test build, then uninstall and confirm unrelated Codex hooks remain.

Build numbers increase monotonically; marketing versions follow semantic versioning. Protocol changes require compatibility or safe version rejection.
