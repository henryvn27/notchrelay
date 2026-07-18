# Release guide

Public artifacts must never be ad hoc signed.

Required GitHub Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY_BASE64`
- `SPARKLE_PRIVATE_KEY`
- `HOMEBREW_TAP_TOKEN` with Contents write access only to the tap

Never print or commit these values.

Before a tag, update versions and changelog, run a clean build/test, and execute a local candidate:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: …" ./Scripts/create_release.sh 1.0.0
```

Run `./Scripts/verify_update_signing.sh` to prove archive and signed-feed verification with an ephemeral test key. Execute the UI suite on an interactive logged-in Mac; hosted CI compiles it but intentionally does not claim headless execution. Verify `codesign --verify --deep --strict`, `spctl`, app and DMG stapling, DMG mount/install, bridge flow, and a Sparkle test update. Pushing `v1.0.0` runs the release workflow: isolated ephemeral keychain setup, universal archive, Developer ID export, app notarization and stapling, final DMG notarization and stapling, signed appcast, GitHub release, and real-SHA cask update.

Build numbers increase monotonically; marketing versions follow semantic versioning. Protocol changes require compatibility or safe version rejection.
