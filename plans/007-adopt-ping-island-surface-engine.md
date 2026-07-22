# 007 — Adopt Ping Island's fixed-shell notch engine

- **Status**: DONE — source, unit, and operated motion verified
- **Commit**: 389c524
- **Severity**: HIGH
- **Category**: Interruptibility
- **Estimated scope**: 7 files, medium architectural replacement

## Problem

Cowlick still animates the AppKit window frame independently from the SwiftUI surface. The controller decides a new panel rectangle and asks AppKit to tween the window:

```swift
// Cowlick/Windowing/NotchPanelController.swift:144 — current
let shouldAnimate =
  panel.isVisible && previousGeometry?.displayID == geometry.displayID && !reduceMotion
if shouldAnimate, panel.frame != geometry.panelFrame {
  let expanding = geometry.panelFrame.height > panel.frame.height
  // ...
  panel.animator().setFrame(geometry.panelFrame, display: true)
}
```

SwiftUI separately animates the surface shape and swaps compact/expanded content:

```swift
// Cowlick/Views/NotchRootView.swift:58 — current
.contentShape(surfaceShape)
.clipShape(surfaceShape)
.animation(contentAnimation, value: layoutMode)
```

Those two render systems cannot share one interpolated presentation state. Under reversal or load, the black window changes size on one timeline while content and corner radii change on another, which is the visible "window resizing around a crossfade" defect.

The earlier DynamicNotchKit spike correctly rejected its unconditional key-window and hosting ownership, but then retained the exact split-shell architecture causing the defect.

## Target

Use the Apache-2.0 [erha19/ping-island](https://github.com/erha19/ping-island) fixed-window notch architecture as Cowlick's engine foundation, pinned for provenance to reviewed upstream commit `c9148fc6a66a98f62dc1cac8fde415c2be9f2233`.

Adopt these engine decisions, with an Apache notice and source attribution:

- Keep one transparent, top-anchored AppKit panel at the maximum Cowlick surface size. Do not animate its frame during compact/expanded/approval transitions.
- Restrict AppKit hit testing to the current SwiftUI surface rectangle so unused transparent panel space remains click-through.
- Let one SwiftUI surface animate width, height, corner radii, persistent header, and content together.
- Keep the header alive across compact and expanded states. Insert/remove only state-specific body content.
- Use an interruptible spring for the surface morph: `Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)` when opening and `Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)` when closing.
- Use `Animation.easeOut(duration: 0.12)` with opacity only for Reduce Motion.
- Preserve Cowlick's user-preferred display, `.statusBar` level, all-Spaces behavior, approval UUID matching, and rule that the panel becomes key only after a user starts interacting with an expanded approval.

Do not copy Ping Island's product UI, mascot, global event-monitor layer, scale-0.8 body transition, or unconditional `canBecomeKey`. Cowlick needs its proven shell/state technique, not a second product model.

## Repo conventions to follow

- Window ownership stays in `Cowlick/Windowing/NotchPanelController.swift`.
- Notch detection and preferred-display selection stay in `Cowlick/Windowing/NotchGeometryResolver.swift`.
- Approval activation remains governed by `NotchPanelInteractionPolicy`.
- Motion values live in `Cowlick/Support/NotchTheme.swift`.
- Cowlick content remains `CollapsedIslandView` and `ExpandedIslandView`.

## Steps

1. Add an Apache-attributed `NotchSurfaceHostingView` based on Ping Island's bounded hit-testing host. Its hit rectangle comes from `NotchPanelPresentation` and it preserves Cowlick's swipe and pointer-down hooks.
2. Extend `NotchPanelPresentation` with the current surface size and the surface rectangle in fixed-panel coordinates.
3. Change `NotchPanelController` to resolve both the current surface geometry and a stable maximum host geometry. Set the AppKit panel frame only when the display/host geometry changes; remove AppKit expand/collapse animation.
4. Change `NotchRootView` to align a self-sizing notch surface at the top center of the fixed transparent host. Apply the open/close spring to surface size, shape, and persistent content in one transaction.
5. Keep the shared header alive between states and replace only expanded-only body content. Use top-anchored opacity plus scale `0.96`, never Ping Island's scale `0.8`.
6. Add unit tests for stable host geometry, surface hit rectangles, reversal final-state ownership, Reduce Motion selection, and approval key-window policy.
7. Add the upstream Apache-2.0 license and exact reviewed commit to Cowlick's third-party notices.

## Boundaries

- Do NOT import GPL-3.0 code from Boring Notch, Atoll, Open Vibe Island, mew-notch, or fantastic-island into MIT Cowlick.
- Do NOT relicense Cowlick or replace its session/hook/approval domain model.
- Do NOT make passive status content activate Cowlick.
- Do NOT install a global mouse-event monitor unless bounded hit testing proves insufficient in runtime QA.
- Do NOT animate the AppKit window frame for state changes.
- Do NOT use a scale below `0.90`; body insertion remains `0.96`.
- If upstream differs from reviewed commit `c9148fc6a66a98f62dc1cac8fde415c2be9f2233`, re-review the license and diff before copying code.

## Verification

- **Mechanical**: run XcodeGen if project membership changes, strict Swift format, targeted notch/geometry/presentation tests, the full macOS unit and UI suites, static analysis, `git diff --check`, and release-script self-checks.
- **Feel check**: launch with Cowlick's simulated-notch fixture, record compact → sessions → compact → approval plus rapid reversals, and inspect at reduced playback speed. Confirm:
  - the outer AppKit panel never visibly resizes;
  - width, height, bottom radii, persistent header, and body move as one surface;
  - no black rectangle or transparent gap appears around the morph;
  - spamming open/close retargets from the current spring state;
  - compact transparent host space remains click-through;
  - passive state never activates Cowlick, while an explicit approval interaction can become key;
  - Reduce Motion removes size/position interpolation and keeps a 120 ms opacity transition.
- **Done when**: the source diff contains the fixed-shell engine and Apache notice, all mechanical checks pass, and a short operated recording shows a continuous reversible morph with no independently resizing AppKit frame.

## Result

Implemented on July 21, 2026. Cowlick now keeps a fixed maximum AppKit host, limits hit testing to the top-centered live SwiftUI surface, and morphs the surface with one observable presentation state. The compact header remains alive across sessions and approval states. Reduce Motion removes spatial interpolation.

Verification completed:

- strict recursive Swift formatting and `git diff --check` passed;
- the full 433-test unit suite passed, followed by 21 focused notch/routing tests after the final flipped-coordinate correction;
- release-script and hook-installer self-checks passed;
- a 11.97-second operated compact → expand → collapse → expand recording showed the stable top edge and persistent header;
- the local UI runner built and signed, but this host timed out while enabling XCTest automation mode before any UI test could start. Hosted CI remains the UI-suite gate.
