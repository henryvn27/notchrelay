# Cowlick presentation and motion plans

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| [001](001-unify-notch-morph-motion.md) | Unify the notch morph | HIGH | DONE |
| [002](002-add-native-notch-swipe.md) | Add native notch swipe interaction | MEDIUM | DONE |
| [003](003-route-one-presentation-surface.md) | Route to exactly one presentation surface | HIGH | TODO |
| [004](004-prove-dynamic-notch-kit-adapter.md) | Prove a safe DynamicNotchKit adapter | HIGH | TODO |
| [005](005-morph-one-surface.md) | Make the notch morph as one surface | HIGH | TODO |
| [006](006-physical-direct-manipulation.md) | Make direct manipulation feel physical | MEDIUM | TODO |

Plans 001 and 002 record the first motion pass at `b009140`. The July 21 audit at `a937b39` found that pass insufficient: presentation ownership is still duplicated, the shell and content still run on separate timelines, and the threshold gesture is not direct manipulation. Plans 003–006 supersede the earlier motion assumptions without rewriting their historical record.

## Recommended execution order

1. **003** first. It defines whether the active surface is the notch or the menu bar and removes the current duplicate default.
2. **004** next as a bounded spike. Do not proceed to the migration unless approval focus, display selection, and Reduce Motion remain equivalent to Cowlick's current contract.
3. **005** after the shell decision. It installs Cowlick's restrained motion tokens and removes the competing AppKit/SwiftUI timelines.
4. **006** last. Gesture and press feedback should target the final shell rather than be rewritten twice.

Plans 004 and 005 are coupled: DynamicNotchKit is the recommended engine, but its stock 400 ms bouncy/blur/scale-zero effects are explicitly out of scope. Cowlick should use the MIT package's geometry and state structure behind a local adapter, then override or patch its motion and key-window behavior.
