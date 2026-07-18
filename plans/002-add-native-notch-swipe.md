# 002 — Add native notch swipe interaction

- **Status**: DONE
- **Commit**: b009140
- **Severity**: MEDIUM
- **Category**: Physicality, interruptibility, missed opportunity
- **Estimated scope**: 4 files, roughly 120 lines

## Problem

Cowlick advertises a pull-down interaction but currently uses only a SwiftUI `DragGesture`, which maps to pointer dragging and does not provide NotchNook-style two-finger trackpad access.

```swift
// Cowlick/Views/NotchRootView.swift:85 — current
private var pullDownGesture: some Gesture {
  DragGesture(minimumDistance: 8)
    .onEnded { value in
      guard presentation.isAttached, store.currentApproval == nil,
        value.translation.height > 12
      else { return }
      store.expand()
    }
}
```

The interaction is binary and responds only after the drag ends. Public NotchNook behavior supports hover, click, and swipe/scroll access at the notch; Cowlick should support the same input vocabulary for its smaller status scope.

## Target

- Recognize precise vertical `scrollWheel` events from a trackpad while the pointer is over the visible notch panel.
- Accumulate deltas per gesture phase and trigger once at 12 points of deliberate vertical movement.
- Downward movement expands; upward movement collapses when no approval is pending.
- Ignore horizontal-dominant scrolling, momentum-only follow-through, non-notch displays, and approval state.
- Preserve normal event propagation when Cowlick does not consume the gesture.
- Keep click and hover behavior intact.
- Make the existing pointer drag expand as soon as it crosses the threshold instead of waiting for release.

## Repo conventions to follow

- Narrow AppKit integration belongs in `Cowlick/Windowing/NotchPanelController.swift` or a focused file under `Cowlick/Windowing/`.
- Pure gesture classification should be a small testable type with no `NSEvent` dependency.
- `NSPanel` remains nonactivating except for approvals.
- The panel frame must remain tightly matched to the rendered island.

## Steps

1. Add a pure `NotchSwipeInterpreter` that accepts phase, vertical/horizontal delta, and momentum information; return `.expand`, `.collapse`, or nil after the threshold.
2. Add a focused `NSHostingView` subclass that forwards precise scroll events through the interpreter and calls an injected action only when consumed.
3. Wire the hosting view in `NotchPanelController`, gated by attached-notch presentation and pending-approval state.
4. Update the SwiftUI drag gesture to trigger on threshold crossing during `.onChanged`, once per gesture, and reset on end.
5. Add unit tests for direction, threshold, horizontal rejection, single-trigger behavior, momentum rejection, and reset.
6. Add a UI-test launch hook only if necessary for deterministic gesture verification; do not ship a debug gesture path in Release.

## Boundaries

- Do not capture global scroll events.
- Do not use an event tap or request Accessibility permission.
- Do not consume scrolling outside the visible Cowlick panel.
- Do not allow a swipe to dismiss or bypass an approval request.
- Do not modify provider usage/account files.
- If the cited code has drifted materially, stop and report instead of improvising.

## Verification

- **Mechanical**: unit tests for `NotchSwipeInterpreter`, full unit suite, and simulated-notch UI tests pass.
- **Feel check**: on a physical notched MacBook, place the pointer over the camera housing and make a short two-finger downward stroke. Confirm the island opens once, does not activate Cowlick, and an upward stroke collapses it. Horizontal scrolling must do nothing.
- Reverse direction before the threshold and confirm no accidental open. Repeat with an approval visible and confirm the gesture cannot collapse it.
- **Done when**: hover, click, pointer pull, and trackpad swipe all reach the same truthful expanded state without global input monitoring or focus theft.
