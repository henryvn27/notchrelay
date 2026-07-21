# 003 — Route to exactly one presentation surface

- **Status**: TODO
- **Commit**: a937b39
- **Severity**: HIGH
- **Category**: Purpose & frequency
- **Estimated scope**: 8 files, medium

## Problem

Cowlick always installs a menu-bar extra and independently always constructs the notch panel. The default settings also enable the non-notch floating panel and select a menu label containing the Cowlick icon. This produces two competing status surfaces and makes the icon unavoidable by default.

```swift
// Cowlick/App/CowlickApp.swift:9 — current
var body: some Scene {
  MenuBarExtra {
    MenuBarContentView(services: services)
  } label: {
    MenuBarLabelView(
      store: services.sessionStore,
      usageStore: services.usageStore,
      settings: services.settings
    )
  }
  .menuBarExtraStyle(.window)
```

```swift
// Cowlick/Stores/SettingsStore.swift:165 — current defaults
Key.showOnNonNotch: true,
// ...
Key.menuBarPresentation: MenuBarPresentation.iconAndDetails.rawValue,
```

## Target

Add a single presentation decision owned by a `PresentationCoordinator`:

- `automatic` (default): use only the notch surface when the selected display has a physical notch; otherwise use only one menu-bar item.
- `menuBar`: always use only the menu-bar item, including on a notched Mac.
- Do not show the floating top-center island on non-notched displays in either mode.
- Default menu-bar label: percentage text only. When quota is unavailable, show `--%`; never fall back to the Cowlick app icon.
- The menu pop-out remains `MenuBarContentView` and shows the percentage, quota progress bar, active work, settings, and quit actions.
- A screen-layout change recomputes the automatic route without creating a moment where both surfaces are visible.

Use an explicit state model:

```swift
enum PresentationPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case menuBar
}

enum ActivePresentation: Equatable, Sendable {
  case notch(displayID: CGDirectDisplayID)
  case menuBar
}
```

The coordinator resolves the route first, then applies it atomically: hide the outgoing surface before showing the incoming one. It must expose a binding suitable for `MenuBarExtra(..., isInserted:)` or own one `NSStatusItem`; do not create two menu-bar status items.

## Repo conventions to follow

- Persist settings through `SettingsStore.Key` and `didSet`, as in `Cowlick/Stores/SettingsStore.swift:97-138`.
- Resolve display capability through `NotchGeometryResolver`, not model-name checks or hardcoded notch widths.
- Keep the existing `MenuBarLabelContent.resolve(...)` pure and unit-testable in `CowlickTests/MenuBarPresentationTests.swift`.
- Preserve `NotchPanelInteractionPolicy`: the notch may become key only for an approval after user initiation.

## Steps

1. Add `PresentationPreference` and `ActivePresentation` in a new `Cowlick/Models/PresentationPreference.swift`.
2. Replace `showOnNonNotch` with `presentationPreference`, including a one-time migration: existing users with `showOnNonNotch == false` migrate to `.menuBar`; all other existing and new users migrate to `.automatic`.
3. Add `PresentationCoordinator` under `Cowlick/App/`. It observes screen changes, preferred-display changes, and presentation preference, and returns exactly one active route.
4. Make `CowlickApp` conditionally insert its one `MenuBarExtra`, or replace it with one coordinator-owned `NSStatusItem` if SwiftUI scene insertion cannot be driven reliably by Observation.
5. Make `NotchPanelController.updatePresentation()` require the coordinator's active route to be `.notch`; remove the non-notch fallback path from normal runtime.
6. Change the default `MenuBarPresentation` to `.percentageOnly`; change its unavailable state from `.app` to `.none` plus text `--%`.
7. Replace Settings' “Show on displays without a notch” toggle with “Presentation: Automatic / Menu bar” and explain the resolved current route underneath.
8. Add unit tests for notched automatic, non-notched automatic, explicit menu-bar override, unavailable quota, screen changes, and migration of existing defaults.

## Boundaries

- Do NOT show both notch and menu bar in any resolved state.
- Do NOT add a Dock icon.
- Do NOT retain the non-notch floating island as a third automatic surface.
- Do NOT change approval decision matching or hook behavior.
- If `MenuBarExtra` conditional insertion proves unreliable, STOP that approach and use one `NSStatusItem`; do not layer both implementations.
- If source differs from commit `a937b39`, STOP and re-audit before editing.

## Verification

- **Mechanical**: run `xcodegen generate`, `swift-format lint --strict --recursive Cowlick CowlickTests CowlickUITests`, and `xcodebuild test -project Cowlick.xcodeproj -scheme Cowlick -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`; all must exit 0.
- **Feel check**: launch with isolated defaults on a simulated notched display and a normal non-notched display, then confirm:
  - notched automatic shows only Cowlick's notch surface and no Cowlick menu-bar item;
  - non-notched automatic shows one menu-bar item and no top-center island;
  - menu-bar override hides the notch before the menu item appears;
  - percentage-unavailable state reads `--%` and never shows the app icon.
- **Done when**: an automated routing test proves there is exactly one active presentation for every capability/preference pair, and a short recording demonstrates all three transitions without duplicate surfaces.
