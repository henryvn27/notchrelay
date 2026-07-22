# 010 — Make the compact notch quiet and hover-revealed

- **Status**: DONE
- **Commit**: 6fdead0
- **Severity**: HIGH
- **Category**: Purpose and frequency; easing and duration; missed opportunity
- **Estimated scope**: 8 files, medium

## Problem

Cowlick's compact surface still makes live task status the visual priority. During a working
session it renders a spinner, task name, project, and agent count around the hardware notch:

```swift
// Cowlick/Views/IslandHeaderView.swift:50 — current
private var statusGroup: some View {
  HStack(spacing: 5) {
    if let session {
      ZStack {
        statusSymbol(for: session)
```

```swift
// Cowlick/Views/IslandHeaderView.swift:83 — current
private var projectLabel: some View {
  HStack(spacing: 6) {
    if let session {
      VStack(alignment: .leading, spacing: 0) {
        Text(session.displayName)
```

Task details therefore remain visible even when the user has not asked for them. At the same time,
the surface only schedules collapse on hover exit; entering the hardware notch does not reveal the
details:

```swift
// Cowlick/Views/NotchRootView.swift:173 — current
private func handleHover(_ isHovering: Bool) {
  collapseIntent?.cancel()
  // ...
  guard !isHovering, presentation.isAttached, store.currentApproval == nil, isExpanded else {
    return
  }
```

The panel also captures precise trackpad/scroll-wheel input and turns it into expand/collapse:

```swift
// Cowlick/Windowing/NotchSwipeInterpreter.swift:174 — current
override func scrollWheel(with event: NSEvent) {
  guard event.hasPreciseScrollingDeltas, canInterpretSwipe() else {
    swipeInterpreter.reset()
    super.scrollWheel(with: event)
    return
  }
```

Finally, the 420–450 ms surface springs exceed the 300 ms budget for a frequently used UI and make
the morph feel delayed after the hover intent resolves:

```swift
// Cowlick/Support/NotchTheme.swift:32 — current
static let surfaceOpen = Animation.spring(
  response: 0.42, dampingFraction: 0.8, blendDuration: 0)
static let surfaceClose = Animation.spring(
  response: 0.45, dampingFraction: 1.0, blendDuration: 0)
```

## Target

- Compact Cowlick is always quota-first. When a real Codex quota is available, the primary wing
  shows the selected remaining/used percentage exactly as the idle usage display does. A live task
  never replaces it with a spinner, task name, project name, or agent count.
- The configured secondary quota metric remains eligible for the opposite wing. Existing explicit
  blank/pace/reset choices remain unchanged.
- A completed display session temporarily replaces only the secondary wing with a restrained
  10-point `checkmark` in `NotchTheme.success`. It uses the existing completion visibility timer;
  no new timer, toast, text label, or persistent badge is added.
- Moving the pointer into an attached compact notch schedules expansion after exactly 80 ms when
  session details exist. Leaving an attached expanded notch schedules collapse after exactly
  160 ms. One cancellable hover task owns both directions, so rapid enter/exit reversal cannot let
  stale work win.
- Clicking the compact surface still expands immediately. If the compact completion indicator was
  visible, the click also dismisses that indicator through the existing completion lifecycle while
  preserving the completed session in the expanded recent-session list.
- Scroll-wheel and trackpad scroll events are forwarded normally. They never expand or collapse
  Cowlick. Existing click, keyboard Escape, hover, and direct pull gestures remain available.
- Use interruptible SwiftUI springs only:

```swift
static let hoverOpenDelay = 0.08
static let hoverCloseDelay = 0.16
static let surfaceOpen = Animation.spring(duration: 0.28, bounce: 0.08)
static let surfaceClose = Animation.spring(duration: 0.24, bounce: 0)
```

- Expanded content keeps the existing 160 ms strong ease-out opacity reveal. The AppKit panel
  frame is not separately animated. Reduce Motion still removes spatial motion and keeps the
  existing 120 ms opacity feedback.

## Repo conventions to follow

- Motion values live in `Cowlick/Support/NotchTheme.swift`; do not add inline timings.
- `NotchRootView.motionReduced` already combines system Reduce Motion with Cowlick's setting.
- `CollapsedIslandView.usageText` and `CompactUsageSecondaryFormatter` remain the single quota
  formatting paths.
- `SessionStore.displaySession` and its existing `completionVisibleUntil` value own completion
  visibility. Do not create view-local completion timers.
- The fixed, bounded `NotchHostingView.interactiveRect` remains the hit-testing boundary. Preserve
  the compact 281×32 installed panel geometry and do not restore a maximum invisible host.
- Keep SF Pro, monospaced digits, the existing physical-black surface, and the current semantic
  colors. No glow, graph, progress bar, task ticker, or decorative icon is introduced.

## Steps

1. In `Cowlick/Support/NotchTheme.swift`, add `hoverOpenDelay = 0.08`, retain
   `hoverCloseDelay = 0.16`, and replace the two response-based surface springs with the exact
   280 ms/240 ms springs above.
2. In `Cowlick/Views/NotchRootView.swift`, replace `collapseIntent` with one `hoverIntent` task,
   cancel it on every pointer transition and on disappear, schedule attached compact expansion on
   enter only when `sessionSummaries` is nonempty, and schedule attached expanded collapse on exit.
   Preserve the DEBUG `--disable-auto-hover` test escape hatch.
3. Update `handleHeaderAction` so compact click always calls `store.expand()` when recent session
   detail exists. If `displaySession` is completed, call `dismissCompletion(sessionID:)` before
   expansion so `untilClicked` keeps its meaning. Expanded click continues to collapse.
4. In `CollapsedIslandView` and `IslandHeaderView`, keep the session only for the compact button's
   accessibility label and completion-state derivation. Render the visual header using quota data
   only. Add a testable helper that returns true only for `.completed`.
5. In `IslandHeaderView`, remove compact spinner/task/project/agent visuals. Render the primary
   percentage with 11-point semibold monospaced digits. Render a 10-point semibold green checkmark
   in the secondary wing while completion is visible; otherwise render the configured secondary
   metric unchanged. Use the existing `statusChange`/reduced-motion transition and expose
   `compact-completion-indicator` as an accessibility identifier without adding duplicate spoken
   content to the parent button.
6. In `NotchPanelController`, remove `canInterpretSwipe` and `handleSwipeAction` wiring. In
   `NotchHostingView`, remove the custom scroll interpreter properties and `scrollWheel` override,
   allowing `NSHostingView` to forward scroll normally. Leave the pure interpreter types/tests in
   place only if another compiled target still references them; otherwise remove the now-dead
   types and their focused tests in the same commit.
7. Update `CowlickUITests`: change the existing hover-stays-compact test to prove hover expands;
   add a compact working screenshot/assertion path that exposes quota but not visible task/project
   text; add completion-indicator coverage; and add a scroll regression proving scroll does not
   expand a compact notch. Keep the existing click and action-padding tests.
8. Add or update focused unit tests for completion-indicator derivation, 80/160 ms hover tokens,
   280/240 ms surface token intent where mechanically testable, accessibility copy, and unchanged
   quota formatting.

## Boundaries

- Do NOT change approval decision behavior, approval focus activation, menu-bar mode, provider
  quota fetching, settings defaults, or hook integration.
- Do NOT animate the AppKit panel frame or enlarge its stable compact hit region.
- Do NOT show task/session/project text in compact mode, including while working.
- Do NOT add new dependencies, timers, notifications, charts, progress bars, blur, glow, or bounce
  above `0.08`.
- Do NOT remove click or keyboard access merely because hover becomes available.
- If the source no longer matches commit `251661f` or the fixed bounded-host contract has changed,
  stop and report instead of improvising.

## Verification

- **Mechanical**:
  - `xcrun swift-format lint --recursive --strict Cowlick CowlickHook CowlickTests CowlickUITests`
  - `xcodebuild -project Cowlick.xcodeproj -scheme Cowlick-UnitTests -derivedDataPath DerivedData -destination 'platform=macOS' -jobs 8 CODE_SIGNING_ALLOWED=NO test`
  - Build the UI-test target and run the focused hover/compact/completion/scroll tests when the
    macOS UI runner materializes.
  - `git diff --check`
- **Feel check**: launch the Debug app with
  `--ui-testing --simulate-notch --usage-demo --state=working` and record compact → hover-open →
  exit-collapse → click-open at normal speed and 25% playback. Confirm:
  - compact shows quota only; no spinner, task, project, or agent count is visible;
  - the morph begins after a short intentional hover pause, stays top-anchored, and settles without
    overshoot or a second geometry animation;
  - rapid enter → exit → enter ends expanded with no stale close;
  - scroll leaves the state unchanged;
  - click opens immediately and the action row remains clickable.
- Launch `--state=completed` with deterministic usage. Confirm the compact right wing shows only the
  small green check, then click and confirm the indicator clears while expanded completed details
  remain available.
- Toggle Reduce Motion and confirm hover still changes state but spatial spring movement is gone;
  the 120 ms opacity feedback remains.
- Install the exact final commit, verify source SHA and healthy hook diagnostics, confirm compact
  geometry remains 281×32, and repeat the real background-app hover/click check.
- **Done when**: compact Cowlick is a quiet quota surface, task details appear only on explicit
  hover/click expansion, scroll cannot change state, completion is a temporary minimal check, and
  the installed exact build passes runtime, hit-testing, and visual verification.

## Result

Implemented in `6fdead0`. Compact mode now renders quota only, attached hover expands after 80 ms,
exit collapses after 160 ms, compact click opens recent activity immediately, and scroll events no
longer control the notch. A completed display session temporarily substitutes a 10-point green
checkmark on the secondary wing; clicking it dismisses the compact indicator while preserving the
completed row in expanded activity.

Verification completed:

- strict recursive `swift-format` and `git diff --check` passed;
- 429 unit tests and the four focused hover/quota/completion/scroll UI tests passed;
- normal-speed screen recording confirmed compact → hover-open → exit-collapse → click-open;
- deterministic working and completed screenshots confirmed the quota-only compact view and the
  minimal completion indicator;
- the local Release install reported source commit `6fdead0`, healthy Codex hooks and bridge, and
  restored the exact 281×32 compact geometry on the physical display;
- the installed app repeated the real hover-open and exit-collapse behavior over another app.

Final closeout evidence is recorded in Linear issue CS-2083.
