# Open-source notch engine research

Reviewed July 21, 2026 against Cowlick's MIT license, macOS 14 deployment target, SwiftUI/AppKit architecture, approval focus policy, multi-display requirements, and motion direction.

| Repository | License | Fit | Verdict |
| --- | --- | --- | --- |
| [erha19/ping-island](https://github.com/erha19/ping-island) | Apache-2.0 | Current native SwiftUI/AppKit implementation; fixed top window, self-morphing surface, and bounded hit testing | **Use its fixed-shell interaction architecture as Cowlick's foundation.** Preserve Cowlick's product model and focus policy. |
| [mrkai77/DynamicNotchKit](https://github.com/mrkai77/DynamicNotchKit) | MIT | Native Swift package; custom expanded and compact SwiftUI content; notch/floating geometry; hover and transition configuration | Earlier adapter candidate; rejected after the bounded spike because its hosting and key-window ownership conflicted with Cowlick's approval policy. |
| [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) | GPL-3.0 | Most mature full notch product and useful behavioral reference | Do not copy or link into MIT Cowlick without an intentional GPL relicensing decision. |
| [Ebullioscopic/Atoll](https://github.com/Ebullioscopic/Atoll) | GPL-3.0 | Polished native Dynamic Island product with gestures | Reference behavior only; license is incompatible with the intended MIT reuse path. |
| [jackson-storm/DynamicNotch](https://github.com/jackson-storm/DynamicNotch) | GPL-3.0 | Active native notch implementation | Reference behavior only for the same license reason. |
| [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island) | GPL-3.0 | Closest product match: multiple coding agents including Codex | Reference product states only; do not reuse implementation in MIT Cowlick. |
| [MioMioOS/MioIsland](https://github.com/MioMioOS/MioIsland) | CC BY-NC 4.0 | Close coding-agent/notch product match | Do not reuse: non-commercial restriction is not an acceptable general-purpose app dependency. |
| [f/textream](https://github.com/f/textream) | No repository license detected | Notch/floating teleprompter surface | Do not copy unlicensed source. |

## Selected boundary

Ping Island's fixed top-window architecture solves the specific defect without importing a second product model: AppKit owns one stable transparent host, a bounded hosting view keeps unused space click-through, and SwiftUI owns the visible surface morph. The reviewed Apache-2.0 source is pinned at commit `c9148fc6a66a98f62dc1cac8fde415c2be9f2233`.

Adopt only that architectural seam and its restrained open/close spring values. Cowlick keeps:

1. `NotchPanelInteractionPolicy` and nonactivating passive status;
2. the user's preferred display and existing Spaces behavior;
3. Cowlick's session, hook, and approval state model;
4. Cowlick's persistent compact header and expanded body;
5. instant spatial state changes when Reduce Motion is enabled.

## Decision

The DynamicNotchKit adapter failed its bounded ownership gate, so it is not the base. Plan 007 supersedes the earlier retained-shell conclusion: use Ping Island's stable-host/self-morphing-surface design while retaining Cowlick's focus, routing, and approval safety boundaries.
