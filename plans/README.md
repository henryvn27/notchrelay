# Cowlick presentation and motion plans

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| [001](001-unify-notch-morph-motion.md) | Unify the notch morph | HIGH | DONE |
| [002](002-add-native-notch-swipe.md) | Add native notch swipe interaction | MEDIUM | DONE |
| [003](003-route-one-presentation-surface.md) | Route to exactly one presentation surface | HIGH | DONE |
| [004](004-prove-dynamic-notch-kit-adapter.md) | Prove a safe DynamicNotchKit adapter | HIGH | DONE — retain shell |
| [005](005-morph-one-surface.md) | Make the notch morph as one surface | HIGH | Implemented; physical QA pending |
| [006](006-physical-direct-manipulation.md) | Make direct manipulation feel physical | MEDIUM | Implemented; physical QA pending |
| [007](007-adopt-ping-island-surface-engine.md) | Adopt Ping Island's fixed-shell notch engine | HIGH | DONE — motion verified |
| [008](008-tighten-notch-motion.md) | Tighten the notch morph | HIGH | DONE — motion verified |
| [009](009-show-usage-in-notch.md) | Show Codex usage in the compact notch | MEDIUM | DONE — visual verified |
| [010](010-make-compact-notch-quiet.md) | Make the compact notch quiet and hover-revealed | HIGH | DONE |

Plans 001 and 002 record the first motion pass at `b009140`. The July 21 audit at `a937b39` found that pass insufficient: presentation ownership is still duplicated, the shell and content still run on separate timelines, and the threshold gesture is not direct manipulation. Plans 003–006 supersede the earlier motion assumptions without rewriting their historical record.

## Recommended execution order

1. **003** first. It defines whether the active surface is the notch or the menu bar and removes the current duplicate default.
2. **004** next as a bounded spike. Do not proceed to the migration unless approval focus, display selection, and Reduce Motion remain equivalent to Cowlick's current contract.
3. **005** after the shell decision. It installs Cowlick's restrained motion tokens and removes the competing AppKit/SwiftUI timelines.
4. **006** last. Gesture and press feedback should target the final shell rather than be rewritten twice.

Plans 004 and 005 are coupled: DynamicNotchKit is the recommended engine, but its stock 400 ms bouncy/blur/scale-zero effects are explicitly out of scope. Cowlick should use the MIT package's geometry and state structure behind a local adapter, then override or patch its motion and key-window behavior.

Plan 007 supersedes the retained-shell conclusion in plans 004 and 005. The current implementation proved that merely borrowing motion values does not fix the split AppKit/SwiftUI presentation. Ping Island's Apache-2.0 fixed-shell architecture is now the implementation base: keep AppKit stable, bound hit testing to the live surface, and let SwiftUI own the complete interruptible morph.

Plans 008 and 009 are the July 22 polish follow-up. Execute 008 first so the existing fixed-shell
motion is settled, then 009 so the usage label is judged against the final compact motion and
spacing. They share no implementation dependency beyond the current plan-007 surface.

Plan 010 is the user-directed interaction revision after physical use of plans 008 and 009. It
supersedes plan 002's scroll-to-expand behavior and the session-first compact layout from plan 009,
while preserving the fixed bounded host, quota data path, click access, and approval behavior.
