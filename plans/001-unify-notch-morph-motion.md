# 001 — Unify the notch morph

- **Status**: DONE
- **Commit**: b009140
- **Severity**: HIGH
- **Category**: Easing, duration, interruptibility, cohesion
- **Estimated scope**: 4 files, roughly 100 lines

## Problem

The AppKit panel frame and SwiftUI content currently animate with different timing systems, while every compact status change forces a full view replacement.

```swift
// Cowlick/Windowing/NotchPanelController.swift:109 — current
if shouldAnimate, panel.frame != geometry.panelFrame {
  let expanding = geometry.panelFrame.height > panel.frame.height
  NSAnimationContext.runAnimationGroup { context in
    context.duration = expanding ? 0.28 : 0.22
    context.timingFunction = CAMediaTimingFunction(
      name: expanding ? .easeOut : .easeInEaseOut)
    panel.animator().setFrame(geometry.panelFrame, display: true)
  }
}
```

```swift
// Cowlick/Views/NotchRootView.swift:38 — current
.id(contentIdentity)
.transition(.move(edge: .top).combined(with: .opacity))
...
.animation(contentAnimation, value: contentIdentity)
```

```swift
// Cowlick/Views/NotchRootView.swift:73 — current
private var contentIdentity: String {
  if let approval = store.currentApproval { return "approval-\(approval.id)" }
  if store.isExpanded { return "sessions" }
  guard let session = store.displaySession else { return "idle" }
  return "compact-\(session.id)-\(session.status.shortLabel)"
}
```

The result can feel layered rather than physical: the shell reaches its destination before the content spring, and Working → Completed slides the whole compact surface instead of changing the status in place.

## Target

- Put panel durations and SwiftUI spring values in `NotchTheme`.
- Expand downward in 240 ms with a strong ease-out.
- Collapse in 180 ms with ease-in-out.
- Use an interruptible SwiftUI spring with `response: 0.24`, `dampingFraction: 0.90`.
- Animate the expanded/compact mode transition, not the session/status identity.
- Change compact status symbols in place with opacity plus a subtle 0.94 scale; never scale from zero.
- Under Reduce Motion, remove movement and keep a 120 ms opacity transition.
- Preserve the panel's stable top edge and existing notch geometry.

## Repo conventions to follow

- Motion and shape tokens live in `Cowlick/Support/NotchTheme.swift`.
- Reduce Motion already combines `@Environment(\.accessibilityReduceMotion)` with `settings.reducedAnimation` in `NotchRootView` and `CollapsedIslandView`.
- AppKit frame changes remain isolated in `NotchPanelController`; SwiftUI views must not mutate `NSPanel`.

## Steps

1. Add shared expand, collapse, content-spring, hover-open, and hover-close values to `NotchTheme`.
2. Replace the hard-coded `NSAnimationContext` values in `NotchPanelController` with the shared tokens and explicit cubic timing functions.
3. Remove session/status from the root transition identity. Transition only between compact, expanded sessions, and approval modes.
4. Give `CollapsedIslandView` an in-place status-symbol transition using opacity and scale 0.94, driven by a stable status identity.
5. Keep button press feedback at 100 ms and hover feedback under 140 ms.
6. Add or update UI tests so a simulated-notch hover expands and a completion state remains accessible without a whole-surface replacement.

## Boundaries

- Do not change session priority, approval behavior, hook routing, or panel geometry.
- Do not add dependencies.
- Do not add decorative bounce, blur, glow, or overshoot.
- Do not modify provider usage/account files.
- If the cited code has drifted materially, stop and report instead of improvising.

## Verification

- **Mechanical**: `xcodebuild test -project Cowlick.xcodeproj -scheme Cowlick-UnitTests -destination 'platform=macOS' -parallel-testing-enabled NO` and the simulated-notch UI tests must pass.
- **Feel check**: launch with `--ui-testing --simulate-notch --state=working`; hover to expand, leave and re-enter during collapse, and switch Working → Completed. Confirm the top edge never moves, the shell and contents arrive together, and rapid reversals retarget smoothly.
- Toggle Reduce Motion and confirm position movement disappears while state opacity remains legible.
- **Done when**: the compact-to-expanded morph reads as one surface growing downward from the camera housing and status changes do not slide the entire island.
