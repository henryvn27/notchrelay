# Performance verification

## Verified 1.0 baseline

Measured on an Apple M4 Mac mini with 16 GB RAM, macOS 26.3.1, using the universal Release build signed with an Apple Development identity. The overlay was hidden, the socket was listening, and no client was connected.

| Measurement | Result |
| --- | --- |
| Idle CPU, seven 10-second samples | 0.0% in every sample |
| Settled resident memory after 60 seconds | 23.1 MiB (`ps`); later memory-pressure sample 13.9 MiB |
| Idle threads | 4 |
| Idle wakeups, two 2-second `top` samples | 0 |
| First cold working event to on-screen panel | 509.6 ms |
| Subsequent working events to on-screen panel | 17.5-35.6 ms |
| Completion event to on-screen panel | 17.5-42.0 ms |

Presentation latency was measured from spawning the bundled helper until a Cowlick-owned on-screen window appeared through Core Graphics. The cold sample includes first-use process, socket, filesystem, and SwiftUI work. These numbers describe this machine and are not a claim about every supported Mac.

The implementation has no idle polling timer or display link. Socket accept work blocks on the Unix-domain listener; animation exists only while a visible working state is rendered. Completed sessions stop rendering after the configured visibility duration and are purged from memory after 15 minutes. Quota refresh is triggered at launch, menu access, relevant activity, or by the user, with a five-minute local-data interval. The opt-in third-party forecast uses a fifteen-minute interval for ordinary triggers and a 30-second freshness guard when the user opens the menu. No timer wakes the app to refresh either source.

## Measurement procedure

Build a Release app, launch it with no state injected, wait 60 seconds, and sample CPU and resident memory at 10-second intervals. Use `Scripts/measure_window_latency.swift` to measure a real helper-to-window transition. Measurements from Debug builds or synthetic view-only previews do not count as the release baseline.
