# Sparkle configuration

Cowlick is configured to use Sparkle 2.9.4 and to require EdDSA-signed update archives from a signed appcast once the public feed is released.

Public EdDSA key:

```
jdfVgATZX2FxlG7vDWmIFurSoELcZ/qJbnkQbaWg4H4=
```

The repository contains only the public key. The Sparkle private key must remain outside Git and be supplied to the release workflow as the protected GitHub Actions `release` environment secret `SPARKLE_PRIVATE_KEY`; `SPARKLE_KEY_ACCOUNT` can select a local Keychain account when preparing a release on a maintainer Mac. The key must never be committed or printed.

As of the current development snapshot, the GitHub `release` environment has no configured secrets, no signed update archive or `appcast.xml` has been published, and the public feed is not live. A release cannot be described as update-ready until the secret is configured and the generated archive, appcast signature, and update installation have been verified from the public assets.
