# Sparkle configuration

Cowlick is configured to use Sparkle 2.9.4 and to require EdDSA-signed update archives from a signed appcast once the public feed is released.

Public EdDSA key:

```
U2GKgH2li8tJeeXoL5raezmbqNXRuIHa8yvIW3dn7m4=
```

The repository contains only the public key. The Sparkle private key must remain outside Git and be supplied to the release workflow as the protected GitHub Actions `release` environment secret `SPARKLE_PRIVATE_KEY`; `SPARKLE_KEY_ACCOUNT` can select a local Keychain account when preparing a release on a maintainer Mac. The key must never be committed or printed.

The first-release Ed25519 private key is stored only as the protected GitHub Actions `release` environment secret. No signed update archive or `appcast.xml` has been published yet, so the public feed is not live. A release cannot be described as update-ready until the generated archive, appcast signature, and update installation have been verified from the public assets.
