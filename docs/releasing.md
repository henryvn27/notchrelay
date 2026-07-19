# Release guide

Public artifacts must never be ad hoc signed.

Run source preflight before dispatching a release:

```sh
./Scripts/release_preflight.sh 1.0.0 --source-only
./Scripts/test_release_scripts.sh
```

Create a GitHub Actions environment named `release`, restrict it to protected branches, and store these as environment secrets rather than repository secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY_BASE64`
- `SPARKLE_PRIVATE_KEY`
- `HOMEBREW_TAP_TOKEN` with Contents write access only to the tap

Never print or commit these values. The Developer ID certificate secret is a base64-encoded `.p12`; the notary key secret is the base64-encoded App Store Connect API `.p8`. `HOMEBREW_TAP_TOKEN` should be a fine-grained token with Contents write access only to `henryvn27/homebrew-cowlick`.

Before a release, update versions and changelog, run a clean build/test, and execute a local candidate:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: …" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARYTOOL_PROFILE="cowlick-notary" \
SPARKLE_PRIVATE_KEY="…" \
./Scripts/create_release.sh 1.0.0
```

`create_release.sh` runs distribution preflight, including an exact Sparkle private/public-key match. Run `./Scripts/verify_update_signing.sh` separately to prove archive and signed-feed verification with an ephemeral test key. Execute the UI suite on an interactive logged-in Mac; hosted CI compiles it but intentionally does not claim headless execution.

Dispatch the Release workflow from protected `main` and enter `1.0.0` as the version. Do not create the tag manually. A separate read-only provenance job checks that the dispatch SHA is the exact current `main` commit using the same executable exercised by the release-script tests. Only then can the `release` job enter the protected GitHub environment and read release credentials. It performs isolated ephemeral keychain setup, universal archive, Developer ID export, app notarization and stapling, final DMG notarization and stapling, signed appcast, release-tag creation, GitHub release publication, and real-SHA cask update. It refuses a version that does not match `MARKETING_VERSION`, an existing tag aimed at another commit, or missing credentials.

Keeping these credentials exclusively in the protected `release` environment is a security boundary: historical tag-triggered workflows in Git history do not declare that environment and therefore cannot read its secrets.

After publishing, verify from a clean user account:

```sh
brew install --cask henryvn27/cowlick/cowlick
codesign --verify --deep --strict ~/Applications/Cowlick.app 2>/dev/null || \
  codesign --verify --deep --strict /Applications/Cowlick.app
spctl --assess --type execute --verbose=2 /Applications/Cowlick.app
```

Complete onboarding without Terminal, run working/approval/completed tests, verify a signed Sparkle update from an older test build, then uninstall and confirm unrelated Codex hooks remain.

Build numbers increase monotonically; marketing versions follow semantic versioning. Protocol changes require compatibility or safe version rejection.
