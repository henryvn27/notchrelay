# Open-source notch engine research

Reviewed July 21, 2026 against Cowlick's MIT license, macOS 14 deployment target, SwiftUI/AppKit architecture, approval focus policy, multi-display requirements, and motion direction.

| Repository | License | Fit | Verdict |
| --- | --- | --- | --- |
| [mrkai77/DynamicNotchKit](https://github.com/mrkai77/DynamicNotchKit) | MIT | Native Swift package; custom expanded and compact SwiftUI content; notch/floating geometry; hover and transition configuration | **Use as the engine candidate behind a Cowlick adapter.** Pin and review an exact revision. Override motion and patch key-window policy. |
| [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) | GPL-3.0 | Most mature full notch product and useful behavioral reference | Do not copy or link into MIT Cowlick without an intentional GPL relicensing decision. |
| [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll) | GPL-3.0 | Polished native Dynamic Island product with gestures | Reference behavior only; license is incompatible with the intended MIT reuse path. |
| [jackson-storm/DynamicNotch](https://github.com/jackson-storm/DynamicNotch) | GPL-3.0 | Active native notch implementation | Reference behavior only for the same license reason. |
| [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island) | GPL-3.0 | Closest product match: multiple coding agents including Codex | Reference product states only; do not reuse implementation in MIT Cowlick. |
| [MioMioOS/MioIsland](https://github.com/MioMioOS/MioIsland) | CC BY-NC 4.0 | Close coding-agent/notch product match | Do not reuse: non-commercial restriction is not an acceptable general-purpose app dependency. |
| [f/textream](https://github.com/f/textream) | No repository license detected | Notch/floating teleprompter surface | Do not copy unlicensed source. |

## Recommended boundary

DynamicNotchKit already handles the lower-level shell Cowlick should stop reinventing: physical-notch detection, compact leading/trailing areas, expanded content, screen-relative panel placement, hover lifetime, and hidden/compact/expanded state. Its source is small enough to review and its MIT terms are compatible with Cowlick.

Do not adopt its visual defaults wholesale. At reviewed commit `cd0b3e52d537db115ad3a9d89601f20e0bee8d27`, upstream defaults include 400 ms bouncy/smooth transitions, scale-to-zero compact content, 10 px blur transitions, an ease-in window fade, a panel that always reports `canBecomeKey == true`, and a half-screen backing window. Cowlick needs a pinned fork or adapter that:

1. preserves `NotchPanelInteractionPolicy` and nonactivating passive status;
2. uses the user's preferred display and current Spaces behavior;
3. skips intermediate hidden states when converting compact/expanded;
4. supplies Cowlick's sub-300 ms restrained motion tokens and Reduce Motion behavior;
5. retains Cowlick content and approval semantics rather than importing a second product model.

## Decision

Run plan 003 regardless. Then run plan 004 as a bounded adapter spike. If the adapter passes focus, display, state-reversal, and Reduce Motion gates, use it as the shell and execute plan 005 on top. If it fails any gate, retain Cowlick's shell and execute plan 005 directly; the audit does not justify weakening approval safety merely to remove custom code.
