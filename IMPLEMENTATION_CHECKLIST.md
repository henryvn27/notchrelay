# Cowlick v1.0.0 implementation checklist

- [x] Establish product identity, app icon, bundle metadata, and Xcode targets.
- [x] Implement the authenticated local bridge, Codex hook helper, and safe approval fallback.
- [x] Implement session arbitration, notch/non-notch panel, menu bar, onboarding, settings, and diagnostics.
- [x] Implement optional Caps Lock signaling with state restoration and capability diagnostics.
- [x] Add Sparkle, local install/uninstall, universal packaging, Developer ID/notarization automation, and a Homebrew cask template.
- [x] Add unit/UI/smoke tests, security/privacy review, docs, CI, launch media, and contributor templates.
- [x] Build, install, uninstall, launch, visually inspect, profile, and verify the live bridge and safe fallback paths.
- [x] Run the macOS UI test runner successfully (12 tests, 0 failures).
- [ ] Import a Developer ID Application identity and configure the `cowlick-notary` profile.
- [ ] Produce and verify the signed/notarized update, DMG, release, and Homebrew installation before publishing.
