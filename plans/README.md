# Cowlick motion plans

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| [001](001-unify-notch-morph-motion.md) | Unify the notch morph | High | DONE |
| [002](002-add-native-notch-swipe.md) | Add native notch swipe interaction | Medium | DONE |

## Execution order

1. Execute 001 first so the panel and content share one motion vocabulary.
2. Execute 002 against that stable presentation boundary.
3. Review the combined result in simulated-notch mode, then on a physical notched MacBook before release.

The plans intentionally exclude NotchNook's unrelated widgets and utility-center scope. They improve Cowlick's hover/click/swipe grammar without changing its role as a Codex status and approval accessory.
