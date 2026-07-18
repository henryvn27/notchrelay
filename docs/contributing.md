# Contributor guide

Install Xcode 16+ and XcodeGen, clone, then run `./Scripts/build_and_run.sh --verify`. `project.yml` is the Xcode project source of truth.

## Style

- Swift 6 strict concurrency and main-actor observable state.
- No disk, socket, or Git work on the main actor.
- Focused files and narrow AppKit bridges.
- Semantic labels, keyboard-safe approval controls, Reduce Motion support.
- No core third-party runtime dependency.
- Never weaken safe fallback to simplify a test.

```sh
xcrun swift-format lint --recursive --strict Cowlick CowlickHook CowlickTests CowlickUITests
xcodebuild -project Cowlick.xcodeproj -scheme Cowlick-UnitTests -derivedDataPath DerivedData test
xcodebuild -project Cowlick.xcodeproj -scheme Cowlick-UITests -derivedDataPath DerivedData test
git diff --check
```

Protocol, approval, and bridge changes require negative-path tests. Visible states require accessibility labels and rendered inspection.

The macOS UI suite requires an interactive WindowServer session in which Xcode's test runner can launch and control an `LSUIElement` application. Hosted CI builds the complete UI test bundle with `build-for-testing`; it does not claim to execute UI tests in a headless session. Run the UI-test command above on an unlocked, logged-in Mac before a release. If `testmanagerd` starts the runner but emits no `Test Case` event and never launches Cowlick, record that host limitation instead of reporting a pass.
