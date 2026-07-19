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

Before a release, update versions, move the release notes from `Unreleased` into a dated `## 1.0.0` section, run a clean build/test, and execute a local candidate. Distribution preflight refuses to publish a version that has no matching changelog section.

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: …" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARYTOOL_PROFILE="cowlick-notary" \
SPARKLE_PRIVATE_KEY="…" \
./Scripts/create_release.sh 1.0.0
```

`create_release.sh` runs distribution preflight, including an exact Sparkle private/public-key match. Run `./Scripts/verify_update_signing.sh` separately to prove archive and signed-feed verification with an ephemeral test key. Execute the UI suite on an interactive logged-in Mac; hosted CI compiles it but intentionally does not claim headless execution.

Dispatch the Release workflow from protected `main` and enter `1.0.0` as the version. Do not create the tag manually. A separate read-only provenance job checks that the dispatch SHA is the exact current `main` commit using the same executable exercised by the release-script tests. The release then calls the same CI workflow used by pull requests against that exact commit; signing credentials remain unavailable until both provenance and CI pass. It performs isolated ephemeral keychain setup, a universal archive in deterministic repository-local DerivedData, Developer ID export, app notarization and stapling, final DMG notarization and stapling, a signed appcast, release-tag creation, draft release upload, downloaded-draft validation, public release publication and public-download validation. The Homebrew cask is rendered from the verified public DMG and updated only after every release check passes. It refuses a version that does not match `MARKETING_VERSION`, an existing tag aimed at another commit, or missing credentials.

Draft publication is repairable: rerunning the workflow for the same version and exact `main` commit may replace assets only while the release remains a draft. Published assets are immutable in this workflow. A rerun after publication downloads and validates the existing public files without replacing them, then may safely repair the downstream Homebrew cask. The workflow verifies checksums, notarization, Gatekeeper, signatures, universal architectures and the `releases/latest` Sparkle feed before touching the tap. It renders the cask from that verified public DMG, audits and installs it through a temporary local tap, and repeats signature and architecture checks against the Homebrew-installed app. Updating the public tap is the final step and is skipped when its cask already has identical content. That local cask install is the no-Xcode user path; do not announce the release if it fails.

For a release first published by the current run, any failure in public-download,
appcast, Homebrew audit/install, or tap-update validation returns the GitHub
release to draft automatically. Reruns of an already-published immutable release
are never demoted. This keeps a failed first release from remaining public while
preserving the safe repair path for a previously verified release.

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
