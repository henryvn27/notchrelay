# 006 — Make direct manipulation feel physical

- **Status**: TODO
- **Commit**: a937b39
- **Severity**: MEDIUM
- **Category**: Physicality & origin
- **Estimated scope**: 4 files, small

## Problem

The drag gesture is a 12-point threshold that immediately toggles state; it does not track gesture progress or velocity. The collapsed island's press response only changes opacity, so clicking the object lacks physical compression.

```swift
// Cowlick/Views/NotchRootView.swift:103 — current drag
DragGesture(minimumDistance: 8)
  .onChanged { value in
    guard !pullDownTriggered, presentation.isAttached, store.currentApproval == nil,
      value.translation.height > 12
    else { return }
    pullDownTriggered = true
    store.expand()
  }
```

```swift
// Cowlick/Views/CollapsedIslandView.swift:76 — current press feedback
func makeBody(configuration: Configuration) -> some View {
  configuration.label
    .opacity(configuration.isPressed ? 0.82 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
}
```

## Target

- During a downward drag, map the first 24 points of translation to a restrained 0...1 reveal progress with rising friction after 24 points.
- Commit expansion when predicted downward travel exceeds 28 points or downward velocity exceeds approximately 0.11 points/ms; otherwise spring back.
- Use `Animation.spring(duration: 0.5, bounce: 0.2)` for release so interrupted gestures carry velocity.
- Press feedback uses scale 0.97 and opacity 0.90 for 140 ms with strong ease-out `cubic-bezier(0.23, 1, 0.32, 1)` equivalent.
- Reduce Motion retains opacity feedback but removes drag translation and press scale.

## Repo conventions to follow

- AppKit swipe normalization already lives in `Cowlick/Windowing/NotchSwipeInterpreter.swift`; keep trackpad-specific normalization there and SwiftUI drag presentation in `NotchRootView`.
- Use the existing combined system/user Reduce Motion check in `NotchRootView.swift:88-90` and `CollapsedIslandView.swift:67-69`.
- Motion values belong in `NotchTheme`.

## Steps

1. Replace `pullDownTriggered` with gesture progress state and a timestamped sample sufficient to calculate velocity.
2. Apply progress to the final shell's top-anchored reveal transform; do not resize the whole panel on every gesture event.
3. On end, decide using predicted travel or velocity, then expand or spring to rest with `{ duration: 0.5, bounce: 0.2 }`.
4. Add scale 0.97, opacity 0.90, and 140 ms ease-out to `IslandPressButtonStyle`; gate scale with Reduce Motion.
5. Add gesture tests for short-fast expand, long-slow expand, insufficient drag cancellation, upward drag, and approval-state rejection.
6. Record mouse click, trackpad swipe, and SwiftUI drag separately so their input paths remain consistent.

## Boundaries

- Do NOT allow drag expansion while an approval is present.
- Do NOT use distance alone; velocity must be represented.
- Do NOT move the notch shell under Reduce Motion.
- Do NOT add hover scaling or haptic feedback; these are high-frequency and unnecessary for Cowlick.
- If the final shell from plan 004/005 differs from the audited shell, adapt only the named gesture surface and re-check geometry before editing.

## Verification

- **Mechanical**: run strict Swift format, `CowlickTests/NotchSwipeInterpreterTests.swift`, the new gesture-policy tests, and the full macOS test command from plan 003.
- **Feel check**: at 10% playback confirm:
  - content follows the pointer for the first 24 points and resistance increases after that;
  - a quick short flick expands, while a slow short pull returns smoothly;
  - release preserves direction without a hard stop;
  - press compression originates from the notch surface and returns within 140 ms;
  - Reduce Motion keeps opacity feedback but removes travel and scale.
- **Done when**: gesture tests pass and a short recording shows direct, interruptible control without threshold snapping.
