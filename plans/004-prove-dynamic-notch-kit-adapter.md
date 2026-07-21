# 004 — Prove a safe DynamicNotchKit adapter

- **Status**: TODO
- **Commit**: a937b39
- **Severity**: HIGH
- **Category**: Cohesion & tokens
- **Estimated scope**: 7 files, medium spike before migration

## Problem

Cowlick owns a custom panel, custom geometry, custom state changes, and custom content transitions. This duplicates a mature open-source notch engine, but replacing the shell blindly would regress Cowlick's approval focus policy and inherit motion that does not fit the product.

```swift
// Cowlick/Windowing/NotchPanelController.swift:52 — current custom shell
init(store: SessionStore) {
  self.store = store
  panel = NotchPanel(
    contentRect: CGRect(origin: .zero, size: NotchTheme.compactSize),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
  )
```

DynamicNotchKit is MIT licensed and supplies notch detection, compact leading/trailing content, expanded content, hover state, window lifecycle, and configurable transitions. Its public panel, however, can become key unconditionally, and its stock style uses 400 ms bouncy/smooth animations plus blur and scale-zero transitions. Those defaults must not ship in Cowlick.

## Target

Build a bounded adapter spike against a version-pinned fork of `https://github.com/mrkai77/DynamicNotchKit` at reviewed commit `cd0b3e52d537db115ad3a9d89601f20e0bee8d27` or a newer explicitly reviewed SHA. The fork must retain the upstream MIT notice and expose only the minimum hooks Cowlick requires:

```swift
struct CowlickNotchTransitionConfiguration {
  let opening = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
  let closing = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
  let conversion = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
  let skipIntermediateHides = true
}
```

Patch the fork or wrap the panel so `canBecomeKey` is false except when Cowlick has an expanded approval and the user initiated interaction. Preserve Cowlick's `.statusBar` level and collection behavior. The adapter must accept Cowlick's existing `CollapsedIslandView` and `ExpandedIslandView`; no product-content rewrite belongs in this spike.

## Repo conventions to follow

- Dependencies are declared in `project.yml` with exact versions or exact revisions and materialized with XcodeGen, as Sparkle is in `project.yml:7-10`.
- Approval focus is constrained by `NotchPanelInteractionPolicy` in `Cowlick/Windowing/NotchPanelController.swift:27-31`.
- Display selection comes from `NotchGeometryResolver.preferredScreen`, including the user's preferred-display choice.
- Motion tokens live in `NotchTheme`, not inside feature views.

## Steps

1. Create a Cowlick-owned fork of DynamicNotchKit or vendor the reviewed MIT source with its license. Do not point at an unreviewed moving branch.
2. Add a minimal configurable key-window policy to the fork: default false; Cowlick supplies a closure for approval/user-initiation state.
3. Add the exact dependency revision to `project.yml`, regenerate `Cowlick.xcodeproj`, and commit both resolved package manifests.
4. Add `CowlickNotchAdapter` behind a debug-only feature flag. Map hidden, compact, sessions, and approval states to DynamicNotchKit without intermediate hidden states.
5. Supply Cowlick's exact transition configuration above and disable the package's default blur, bouncy, scale-zero, and haptic-hover effects.
6. Preserve `preferredDisplay`, multi-display/Space behavior, accessibility announcements, click-to-activate approval, and swipe routing.
7. Add adapter contract tests and a debug comparison harness that can run legacy and adapter shells separately with the same fixture state.
8. Review the spike. Proceed to replacing `NotchPanelController` only if every gate below passes; otherwise keep the current shell and execute plan 005 directly.

## Boundaries

- Do NOT depend on Boring Notch, Atoll, DynamicNotch, or Open Vibe Island source; they are GPL-3.0.
- Do NOT depend on MioIsland source; its repository license is CC BY-NC 4.0.
- Do NOT copy DynamicNotchKit's stock transition values or scale-zero transitions.
- Do NOT weaken `NotchPanelInteractionPolicy`, approval UUID matching, or nonactivating behavior.
- Do NOT remove Cowlick's geometry implementation until the adapter passes physical notched-Mac QA.
- If the reviewed DynamicNotchKit revision changes or the fork is unavailable, STOP and re-review license and diff.

## Verification

- **Mechanical**: run `xcodegen generate`, strict Swift format, the full macOS test command from plan 003, and `./Scripts/test_release_scripts.sh`; all must exit 0 and package resolution must be reproducible from a clean cache.
- **Feel check**: record legacy and adapter shells at 120 fps if available, triggering working, expand, approval, completion, collapse, display switch, Space switch, and rapid expand/collapse. Confirm:
  - the adapter remains attached to the physical notch with no initial frame flash;
  - rapid reversal retargets from the current visual state and never hides between compact and expanded;
  - clicking passive status never activates Cowlick; clicking an approval action activates only after the pointer-down policy runs;
  - Reduce Motion drops scale/position movement but preserves a 120 ms opacity transition.
- **Done when**: the adapter passes all safety and visual gates and the diff review shows only MIT-compatible source and notices; otherwise the documented result is “retain Cowlick shell.”
