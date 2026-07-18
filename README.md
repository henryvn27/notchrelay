<p align="center"><img src="Assets/AppIcon/cowlick-icon.svg" width="112" alt="Cowlick icon"></p>
<h1 align="center">Cowlick</h1>
<p align="center"><strong>Codex status and safe approval actions, right at the MacBook notch.</strong></p>
<p align="center"><a href="#install">Install</a> · <a href="docs/security.md">Security</a> · <a href="docs/privacy.md">Privacy</a> · <a href="docs/troubleshooting.md">Troubleshooting</a></p>

![Cowlick showing working, approval, and multi-session states](Assets/Screenshots/hero.png)

> **Looking for a download?** A signed public build has not been published yet. The verified path available today is the contributor install below; Cowlick will not advertise a DMG or Homebrew cask until that exact artifact is signed, notarized, and installation-tested.

Cowlick is a native, local-first macOS companion for OpenAI Codex. It stays hidden while idle, shows active projects and completion near the notch, and lets you allow once or deny supported Codex permission requests without becoming a second Codex client.

## What it does

- Shows working, approval, completed, failed, and multi-session states.
- Uses official Codex lifecycle hooks; it does not parse transcripts.
- Matches approval decisions to a unique pending request and never defaults to Allow.
- Falls back to Codex's normal approval UI if the app is unavailable, disconnected, malformed, or timed out.
- Uses the built-in display's real safe-area geometry; non-notch Macs get a compact top-center island.
- Shows current Codex quota from the local Codex app, with no account-file access or usage history.
- Can optionally display an attributed, unofficial reset forecast from [Will Codex Reset?](https://www.willcodexquotareset.com/); it is off by default and never presented as Cowlick data.
- Optionally pulses the Caps Lock LED while preserving its original state.
- Keeps prompt and result previews off by default.

## Install

### Public release

There is currently no prebuilt public download. Do not use or redistribute development-signed builds as a public release. When v1.0.0 passes its release gates, this section will link directly to the signed GitHub release and show the verified Homebrew command.

### Contributor install

Requirements: macOS 14+, Xcode 16 or newer, and XcodeGen.

```sh
git clone https://github.com/henryvn27/cowlick.git cowlick
cd cowlick
brew install xcodegen
./Scripts/install_local.sh
```

The contributor installer builds Cowlick, installs it in `~/Applications`, installs and merges the local Codex hooks, launches the app, and runs bridge diagnostics. Use `./Scripts/build_and_run.sh --verify` when developing without installing. Once the public release gates pass, normal installation will require no Xcode, Swift, Python, Node, npm, account, or cloud service.

## Approval safety

Cowlick's Allow button is never the default action. Every response contains the exact request UUID received from the helper. A timeout, invalid token, stale event, malformed response, mismatched UUID, unavailable app, or broken socket returns no decision, so Codex continues with its own normal approval prompt. Tool input is display-only and is never executed by Cowlick.

## Supported systems

- macOS 14 Sonoma or newer.
- Apple Silicon and Intel through a universal release binary.
- Notched and non-notched Macs, external displays, multiple displays, Spaces, and full-screen auxiliary presentation where macOS permits it.

## Privacy

Cowlick has no analytics, cloud backend, account, ads, or third-party crash reporter. It checks the signed Sparkle update feed. If you explicitly enable the unofficial reset forecast, it also requests data from willcodexquotareset.com and labels it as third-party data that Cowlick does not estimate or warrant. It does not persist full prompts, commands, quota history, forecast history, or session history. See [PRIVACY.md](PRIVACY.md) for every stored file, network path, and permission.

## How it works

Codex invokes the bundled `cowlick-hook` helper for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, and `Stop`. The helper sends authenticated, versioned newline-delimited JSON over a private Unix-domain socket. The native app arbitrates independent session state and returns synchronous approval decisions only when the request is still current.

For quota display, Cowlick asks the installed Codex app-server only for `account/rateLimits/read`; it does not read `auth.json` or request account identity. The optional reset forecast is fetched separately from `https://www.willcodexquotareset.com/api/forecast`, decoded as untrusted display-only data, and kept in memory.

See [architecture](docs/architecture.md) and the [bridge protocol](docs/protocol.md).

## Development

The project-local Codex Run action uses the same build command. See [CONTRIBUTING.md](CONTRIBUTING.md) for code style, testing, and pull-request guidance.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Security reports belong in a private [GitHub security advisory](https://github.com/henryvn27/cowlick/security/advisories/new), not a public issue.

Cowlick is MIT licensed. It is an unofficial community project and is not affiliated with, endorsed by, or sponsored by OpenAI. OpenAI and Codex are trademarks of their respective owners.
