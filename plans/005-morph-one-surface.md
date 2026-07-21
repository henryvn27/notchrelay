# 005 — Make the notch morph as one surface

- **Status**: IMPLEMENTED — PHYSICAL QA PENDING
- **Commit**: a937b39
- **Severity**: HIGH
- **Category**: Interruptibility
- **Estimated scope**: 5 files, medium

## Problem

The AppKit panel frame and SwiftUI content use separate animation systems. The panel resizes through `NSAnimationContext`, while conditional content independently crossfades under a second `.animation`. During rapid state changes these timelines can start from different moments, making the shell look like a resizing black window with content swapping inside it.

```swift
// Cowlick/Windowing/NotchPanelController.swift:151 — current shell timeline
NSAnimationContext.runAnimationGroup { context in
  context.duration =
    expanding ? NotchTheme.panelExpandDuration : NotchTheme.panelCollapseDuration
  context.timingFunction = CAMediaTimingFunction(
    controlPoints: controlPoints.0,
    controlPoints.1,
    controlPoints.2,
    controlPoints.3
  )
  panel.animator().setFrame(geometry.panelFrame, display: true)
}
```

```swift
// Cowlick/Views/NotchRootView.swift:43 — current content timeline
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
.transition(contentTransition)
// ...
.animation(contentAnimation, value: layoutMode)
```

## Target

Drive compact, sessions, and approval from one explicit state transition. If plan 004 passes, the DynamicNotchKit adapter owns the shell state and Cowlick supplies these exact overrides. If plan 004 fails, add an interruptible Cowlick transition coordinator and use the same values:

```swift
static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
static let morph = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
static let reducedMotion = Animation.easeOut(duration: 0.12)
```

- Entering/exiting content starts at opacity 0 and scale 0.96 anchored to `.top`; never scale 0.
- The surface mask, frame, corner radii, shared header, and content transition in the same 240 ms morph transaction.
- The shared status and session title retain `matchedGeometryEffect`; non-shared list/approval content uses the top-anchored 0.96/opacity transition.
- Rapid expand/collapse/approval changes retarget from the current presentation rather than enqueueing stale animations.
- Reduce Motion uses opacity only for 120 ms.

## Repo conventions to follow

- Keep shared motion values in `Cowlick/Support/NotchTheme.swift`; existing durations and control points already live there at lines 26-46.
- Keep `@Environment(\.accessibilityReduceMotion)` plus the user override, as `NotchRootView` does at lines 6 and 88-90.
- Reuse the existing `@Namespace` and matched IDs in `IslandHeaderView.swift:53` and `:75`.

## Steps

1. Replace the separate panel/content animation triggers with one `NotchPresentationState` transition entry point.
2. Put the four exact animations above in `NotchTheme`; remove the old competing `contentSpring`, `contentCollapse`, and separate panel curve tokens after all call sites migrate.
3. Add asymmetric top-anchored transitions for compact, sessions, and approval content using scale 0.96 plus opacity; reduced motion uses opacity only.
4. Animate the mask corner radii in the same transaction as state and frame. Do not crossfade the black surface itself.
5. Cancel or retarget any pending state task when a newer state arrives; no fixed sleep may decide the final visible state.
6. Add a deterministic state-transition test that rapidly sends compact → sessions → compact → approval and asserts the last state wins.
7. Add a UI-test sequence with launch arguments that records each transition and the rapid-reversal case.

## Boundaries

- Do NOT animate layout properties on a polling loop.
- Do NOT use scale below 0.90; target 0.96 exactly.
- Do NOT use blur above 2 px; the default implementation should use no blur.
- Do NOT use a duration above 300 ms.
- Do NOT add bounce to frequently occurring working/status transitions.
- If source differs from commit `a937b39`, STOP and re-audit before editing.

## Verification

- **Mechanical**: run strict Swift format and the full macOS test command from plan 003. Add a transition-state unit test that passes under 50 rapid reversals.
- **Feel check**: record the debug fixture at 10% playback and confirm:
  - the lower notch edge, corner radii, header, and incoming content travel as one object;
  - no frame contains two fully readable content states;
  - spamming expand/collapse never jumps through hidden or restarts from compact geometry;
  - Reduce Motion keeps the 120 ms fade while removing scale and positional motion.
- **Done when**: a short side-by-side video shows continuous, interruptible morphs with no flash, double exposure, stale end state, or animation over 300 ms.

## Implementation result

The retained shell now uses one token set for its 240 ms expand and 180 ms collapse, while compact and expanded content use asymmetric opacity plus 0.96/0.98 top-anchored transitions instead of a scale-to-zero or independent spring. Status changes use a restrained 160 ms ease-out and Reduce Motion uses a 120 ms opacity-only transition. Mechanical tests pass. A physical-notch operated recording is still required before release; the host recorder could not target Cowlick's nonactivating status-bar panel in the active full-screen Space.
