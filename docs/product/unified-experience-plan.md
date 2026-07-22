# Cowlick unified experience blueprint

**Status:** Product and interaction plan

**Date:** July 22, 2026

**Tracker:** [CS-2080](https://linear.app/controlstudios/issue/CS-2080/design-unified-cowlick-notch-and-menu-bar-experience)

**Delivery branch:** `integrate/cs-2051-final-candidate`
**Prototype:** [`../mockups/unified-experience.html`](../mockups/unified-experience.html)

## 1. The product decision

Cowlick is one Codex command surface with two mutually exclusive presentations:

- **Notch mode** is the complete experience on a notched Mac. It owns status, approvals, usage, settings access, Codex activation, live utilities, and the file tray. It never creates or depends on a menu-bar item.
- **Menu bar mode** is the complete Codex experience on a Mac without a notch, or when the user explicitly opts out of the notch. It owns status, approvals, usage, settings access, and Codex activation. It does not imitate a hardware notch and does not expose notch-only utilities.

There is no third default surface, hidden status icon, duplicate app menu, or fake notch on a notchless display. Cowlick remains a background accessory with no Dock icon by default.

The default presentation rule is:

```text
Automatic
├── Built-in display has a hardware notch → Notch mode only
└── No hardware notch                         → Menu bar mode only

Explicit override
└── Menu bar selected                         → Menu bar mode only
```

This rule supersedes the old product split in which status lived near the notch while quota planning lived in the menu bar.

## 2. What Cowlick should communicate

The primary job is not “show the name of a Codex chat.” It is “tell me what my agents are doing and let me step in when needed.” Every active session therefore has a structured activity snapshot:

| Field | User question | Example | Compact priority |
| --- | --- | --- | --- |
| **Project** | Where is this happening? | `Cowlick` | Always available; shown when space permits |
| **Goal** | What outcome is Codex pursuing? | `Design the unified notch experience` | Expanded surface |
| **Now** | What is it doing right now? | `Rendering the approval state` | Primary compact line |
| **State** | Does Henry need to act? | `Working`, `Approval needed`, `Failed` | Always visible through color, icon, and text |
| **Agents** | Is work delegated? | `2 subagents · 1 verifying` | Compact count; expanded detail |
| **Usage** | How much capacity remains? | `78% weekly left` | Always visible by default when available |

The Codex sidebar/chat title remains optional metadata in a detail or search context. It must never replace Project, Goal, or Now.

## 3. Structured live activity model

### 3.1 Proposed domain object

```swift
struct ActivitySnapshot: Equatable, Sendable {
  let sessionID: String
  let project: String
  let goal: ActivityText?
  let now: ActivityText?
  let phase: ActivityPhase
  let state: ActivityState
  let agents: [AgentActivity]
  let usage: UsageSummary?
  let updatedAt: Date
  let confidence: ActivityConfidence
}

struct ActivityText: Equatable, Sendable {
  let value: String
  let source: ActivityTextSource
  let observedAt: Date
}
```

`ActivityPhase` is a small, stable vocabulary: `orienting`, `researching`, `editing`, `building`, `testing`, `reviewing`, `delivering`, `waiting`, and `done`. `ActivityState` remains the urgency/state machine: `idle`, `working`, `awaitingApproval`, `completed`, `failed`, `stale`, and `disconnected`.

Phase answers what kind of work is happening. State answers whether it is moving and whether the user must act. They are not interchangeable.

### 3.2 Current source truth

Cowlick already receives or derives:

| Source | Current fields | What it can power |
| --- | --- | --- |
| `SessionStart` hook | session, cwd, model | Project, idle identity |
| `UserPromptSubmit` hook | prompt, turn, cwd | Goal fallback, Working |
| `PermissionRequest` hook | tool name, tool input, human description | Exact Approval state and safe Now copy |
| `SubagentStart` / `SubagentStop` hooks | agent ID, type, parent turn | Agent counts and delegated phase |
| `Stop` hook | last assistant message | Completion result |
| Local Codex JSONL observer | lifecycle markers, cwd, model, subagent lineage | Resilient state when hooks are unavailable |
| Local thread catalog | Codex display title | Optional metadata only |
| Codex app-server | rate-limit snapshot | Official usage and resets |

The existing bridge therefore supports a useful first version without inventing a new network service. The missing piece is an authoritative goal/activity event.

### 3.3 Goal precedence

Use the first valid source in order:

1. **Official Codex goal event or local read API** when OpenAI exposes one. This is the only source allowed to claim `Explicit goal` confidence.
2. **Cowlick activity hook extension** if Codex later supports a custom `GoalChanged` event.
3. **First active user prompt for the turn**, normalized locally to one sentence and capped at 96 visible characters. This is labeled `Prompt-derived` in details, never presented as a verbatim hidden system objective.
4. **Project fallback:** `Work in <Project>`.

Do not scrape the Codex window, parse encrypted reasoning, or decode the nested output of the internal goal tool. Those approaches are brittle and cross the privacy boundary.

### 3.4 Now precedence

Use the freshest valid source in order:

1. **Pending approval description:** `Waiting to publish the verified branch`.
2. **Safe assistant commentary:** the most recent visible `commentary` update from the local session transcript, bounded to its first useful sentence.
3. **Tool phase classification:** map allowlisted tool identifiers to authored phrases, for example:
   - read/search/find/open → `Inspecting the session model`
   - edit/patch/write → `Updating the activity model`
   - build/test/playwright/xcode → `Verifying the interaction`
   - git push/deploy/release → `Preparing delivery`
4. **Subagent activity:** `2 agents researching provider support`.
5. **Phase fallback:** `Working toward the goal`.

Cowlick should not display raw shell commands, tool JSON, absolute private paths, authentication values, error dumps, or model reasoning. A tool event may influence the phase while its raw payload remains discarded.

### 3.5 Freshness and failure behavior

- A Now line is **fresh** for 120 seconds after a commentary, tool, or lifecycle event.
- While a known long-running build/test is active, it remains fresh until a matching completion, failure, or the existing 10-minute observer ceiling.
- After 120 seconds without a new descriptive event, Cowlick falls back to the stable phase (`Testing…`) rather than showing stale prose.
- After 10 minutes without lifecycle evidence, the session becomes `Unconfirmed` and no longer claims active work.
- Hook and local-observer events are deduplicated by session, turn, source authority, and delivery sequence.
- Trusted hook state wins over local observation for the same session and turn. Only a trusted permission hook can create an approval.

### 3.6 Privacy contract

The feature remains local-first:

- No prompt, commentary, tool, goal, or result text is sent to Cowlick, OpenAI, or a third-party summarizer by Cowlick.
- Project, goal, now, chat title, and result remain in memory by default.
- `Show goal and activity text` is one understandable preference, on by default after a one-screen explanation. Separate advanced switches can hide prompt-derived Goal, commentary-derived Now, or result text.
- Diagnostics store only source categories, age, and sanitized error codes—not activity strings.
- Local JSONL parsing is allowlisted, incremental, size-bounded, owner-checked, and off the main actor.
- Lock Screen, screen sharing, and notification previews use a privacy-safe presentation unless the user explicitly enables detail.

## 4. Capability model

### 4.1 Shared capabilities: both modes

These are Cowlick capabilities, not notch features, and must have parity in both presentations:

| Capability | Compact | Expanded/popover |
| --- | --- | --- |
| Project, Goal, Now, State | State + Now + usage | Full hierarchy, timestamps, source confidence |
| Multi-session arbitration | Highest-priority session + count | All current sessions, filterable by state/project |
| Subagents | Count and activity pulse | Parent/child list with role and current phase |
| Safe approvals | Attention takeover | Project, tool, operation, timeout, Allow once, Deny |
| Completion and failure | Brief terminal signal | Result preview, retry/open diagnostics |
| Codex activation | Primary action | Open exact project/thread when supported |
| Official Codex quota | Percentage | 5-hour/weekly windows, reset times, refresh |
| Pace and runout | Warning marker | On-track/at-risk copy, projected empty time |
| Credits and code review | Attention marker | Remaining credits, review limit and reset |
| Local token/API-price equivalent | Optional compact warning | 7/30/custom-day totals and per-model history |
| Provider billing | Selected provider | Account switcher, month-to-date spend, coverage labels |
| Provider status | Incident dot | Incident description, source link, last refresh |
| Integration health | Warning state | Repair action, hook trust, bridge self-test |
| Settings/update/quit | Reachable action | Full controls and update state |
| Notifications | Native notification | Threshold, approval, completion preferences |
| WidgetKit + CLI | Outside the surface | Same data model and privacy rules |

### 4.2 CodexBar-equivalent usage platform

The current Cowlick usage screen covers only part of CodexBar. The target includes the complete capability categories documented by CodexBar:

- provider adapters with per-provider enablement and ordering;
- multiple accounts and a combined overview without merging unlike currencies or billing semantics;
- session, weekly, monthly, credit, and provider-specific meters;
- reset countdown or absolute time;
- used/remaining, percent/pace/both, and highest-risk automatic selection;
- historical usage and spend charts with configurable ranges;
- local Codex/Claude cost scans and per-model breakdowns;
- credits, code-review allowance, usage breakdown, and dashboard enrichments when explicitly enabled;
- provider status polling and incident badges;
- adaptive/manual/fixed refresh cadence;
- quota thresholds, reset notifications, and optional completion celebration;
- privacy redaction, personal-information hiding, and source/last-refresh labels;
- a Cowlick CLI and WidgetKit snapshot using the same usage engine.

CodexBar is MIT licensed. The implementation recommendation is to extract or vendor a pinned, reviewed provider core into a `CowlickUsageCore` boundary with attribution and upstream-diff tracking. Do not run CodexBar as a second application, preserve its menu-bar item, or import its product UI wholesale. Cowlick owns one surface and one design language.

The default remains zero-setup Codex usage through the local Codex app-server. Provider paths that need browser cookies, Full Disk Access, OAuth, or admin keys are off until the user explicitly enables that provider and sees the exact permission reason.

### 4.3 Notch-only capabilities

The official NotchNook product surface confirms widgets, live actions, a file shelf, swipe/scroll interaction, media, calendar, shortcuts, a webcam mirror, temporary file storage, and AirDrop. Cowlick should implement the relevant set as original Cowlick modules:

| Notch page | Capabilities | Default behavior |
| --- | --- | --- |
| **Work** | Structured Codex activity, sessions, agents, approvals, result/failure | Default page whenever Codex is active |
| **Usage** | Complete shared usage/provider surface | Remembers last provider; never replaces Work during approval |
| **Nook** | Now Playing, next calendar event, live actions, shortcuts, Mirror | Modules are user-reorderable; permissions are just-in-time |
| **Tray** | Drag/drop temporary file shelf, reveal, remove, share, AirDrop | Drop target expands on drag; files never upload to Cowlick |

Notch gestures:

- Hover gives restrained visual feedback while the surface stays compact; click or pull-down opens it. Leaving an expanded surface closes after 160 ms unless focus or drag is inside.
- Click toggles compact/expanded.
- Horizontal swipe changes pages and is interruptible.
- Pull/down gesture expands; upward gesture collapses.
- Dragging files over the notch switches directly to Tray without changing the long-term selected page.
- Approval interrupts the current page, but never destroys its state; resolving it returns to the prior page.
- Reduce Motion removes geometry interpolation and uses a short crossfade.

Camera, calendar, media, and file access are independently removable. Mirror starts only after an explicit click, shows the system camera indicator, stops immediately on collapse/page change, and is never used for presence detection.

### 4.4 Intentionally excluded

- A fake notch or NotchNook-style handler on notchless displays. Cowlick uses the menu bar there.
- A second Cowlick menu-bar item while notch mode is active.
- NotchNook branding, artwork, layout, sound design, or proprietary implementation.
- CodexBar’s independent per-provider status items. Cowlick has one selected surface with an internal provider switcher.
- Automatic browser-cookie import, Full Disk Access prompts, camera startup, or calendar access on first launch.
- Remote approvals in the first implementation. Local exact-UUID safety remains the contract.
- Raw transcript, command, tool-input, or reasoning display.

## 5. Surface specifications

### 5.1 Notch compact state

The compact notch is a status sentence, not an icon strip:

```text
┌ state + usage ─────── [physical camera] ─────── project · now ┐
│ ● 78%                                           Cowlick · Rendering mockups │
```

- The black surface is visually continuous with the hardware camera housing.
- The top edge never moves. The fixed AppKit host remains unchanged; SwiftUI owns one downward morph.
- State/approval owns the strongest color. Usage is secondary unless at risk.
- Now is preferred over the chat title. Project is retained as context.
- At narrow widths, truncation order is chat metadata → agent detail → Project → Now. State and approval never disappear.
- The minimized hardware-notch shell is exactly as tall as the safe-area notch and adds two matched 48-point wings; it never extends below the camera housing.
- Idle with usage available centers the primary percentage in the left wing. The right wing is user-selectable: blank, used/left meaning, window progress, pace balance (`+13%` banked, `-14%` behind), reset countdown, projected runway, or the opt-in reset probability. The shell never grows for a selection.
- Compact secondary values use terse visible tokens and complete VoiceOver labels; unavailable data leaves the wing blank rather than guessing.
- Both idle wing values use the same 11-point semibold typography. Pace color is semantic and redundant with the sign: banked (`+`) is green, 1–14 points behind (`-`) is yellow, and 15 or more points behind is red.

### 5.2 Notch expanded state

- Maximum working width: 560 pt; page content stays within a stable shell.
- Header: project, state, usage, page switcher, collapse affordance.
- Work page hierarchy: Project label → Goal (two lines) → Now (one/two lines) → phase timeline → sessions/agents.
- Approval replaces the Work body with one focused decision surface; secondary pages are disabled until resolved or deferred.
- Bottom action rail always provides Open Codex, Settings, Diagnostics, and Quit.
- Only the page body changes. Header, shell, actions, and selected-project identity persist through transitions.

### 5.3 Menu-bar compact state

- Exactly one Cowlick status item.
- Default label is a small state symbol plus official Codex percentage.
- Optional display choices mirror the relevant CodexBar controls: percent, pace, both, status only, auto highest-risk provider.
- Approval changes the symbol and concise text to `Review` without adding another item.

### 5.4 Menu-bar popover

- Width: 360–400 pt depending on chart visibility.
- Top segmented switch: Work / Usage. Notch-only pages do not appear.
- Work contains the same Project, Goal, Now, State, sessions, subagents, and approvals as the notch, with layout density adapted to a vertical popover.
- Usage contains the same provider selector, metrics, pace, history, billing, source, incident, and refresh state.
- Persistent actions: Open Codex, Settings, Diagnostics, Check for Updates, Quit.

## 6. State matrix

| State | Compact treatment | Expanded/popover treatment | Exit |
| --- | --- | --- | --- |
| Idle + usage | Usage percent; no task fiction | Usage summary, recent terminal sessions, next reset | New lifecycle event |
| Orienting/researching/editing/testing | State pulse + Now | Project, Goal, Now, phase, agents, usage | Next event/Stop |
| Multiple sessions | Highest-priority Now + count | Sessions grouped by urgency, then recency | Sessions complete |
| Approval | Orange takeover and `Review` | Exact project/tool/operation, timeout, Allow once/Deny | UUID-matched decision or defer |
| Completed | Green check and concise result | Evidence/result, Open Codex, dismiss | Timed dismissal/user action |
| Failed | Red state and project | Sanitized failure, retry/open diagnostics | New turn/dismiss |
| Unconfirmed | Muted clock | Explain stale/restart recovery; never claim active | Fresh trusted/local event |
| Integration degraded | Warning only when no higher-priority work | One repair action, limited-mode explanation | Trust/bridge passes |

Priority remains: approval → failed → working → recently completed → idle. A utility page can never cover an approval.

## 7. Setup redesign

The current seven-step flow ends with a security review instruction that asks the user to copy `/hooks`, open Codex, run the command, review several hooks, return, and check again. The security gate is valid; the choreography is not.

Replace it with a three-stage setup:

1. **Choose where Cowlick lives**
   - Automatic is preselected and visually explains Notch on this Mac or Menu bar on this Mac.
   - The alternate Menu bar choice is available on notched Macs.
2. **Connect Codex**
   - One `Install integration` action installs all six hooks, launches Cowlick, and runs the self-test.
   - The next security-required action is one primary `Review in Codex` button. Cowlick copies `/hooks`, opens/focuses Codex, and waits for the trust state. The screen auto-advances when review succeeds; there is no separate Check Again step.
3. **Ready**
   - A live preview shows the actual selected surface and current usage.
   - `Start Cowlick` closes onboarding.

If Codex cannot deep-link directly to the review screen, Cowlick should say exactly once: `Codex requires you to confirm new hooks. Paste /hooks in Codex, review Cowlick, then return.` A secondary `Use limited mode` continues with local status and usage while approvals remain in Codex. Permissions for Calendar, Camera, provider accounts, Full Disk Access, and notifications are requested later, at the moment the user enables the related feature.

## 8. Motion and interaction system

Cowlick already uses the Apache-2.0 Ping Island fixed-shell architecture. Keep it as the surface engine and improve within that ownership model:

- one stable transparent AppKit host;
- one top-anchored SwiftUI surface controlling width, height, corners, and body reveal;
- bounded hit testing so unused host space is click-through;
- no AppKit frame animation during state changes;
- passive hover feedback and 160 ms pointer-exit collapse;
- interruptible opening spring, critically damped closing spring;
- opacity-only body insertion clipped by the shell;
- immediate 80–100 ms press response;
- no blur stacks, glow, bounce, scale-from-zero, or independent child-card motion;
- transition distance and duration remain constant across Work, Usage, Nook, and Tray;
- Reduce Motion: no spatial interpolation, 120 ms opacity transition;
- Reduce Transparency: opaque semantic fills with preserved contrast.

Performance gates for the expanded feature set:

- idle WindowServer/CPU impact must remain within the existing Cowlick baseline plus a measured 0.2% CPU ceiling on the representative Mac;
- click-to-first-frame p95 under 100 ms; page-switch p95 under 150 ms;
- transcript parsing stays off-main and incremental; no full-file scan on every activity update;
- media waveform, Mirror, and charts stop rendering when their page is not visible;
- file drag previews are generated asynchronously and cached by file identity;
- provider refresh is adaptive and never tied to animation frames.

The expanded transcript observer is a credible performance-risk candidate, not a pre-approved optimization. Before implementation, capture the current observer’s CPU, allocations, bytes read, and event latency over a representative large session archive; then compare the identical workload after adding commentary/tool classification.

## 9. Accessibility

- Every icon has a visible label or VoiceOver label; color never carries state alone.
- Compact notch is one coherent accessibility element: `Cowlick, working in Cowlick, rendering approval state, 78 percent weekly remaining`.
- Expanded focus order follows Project → Goal → Now → session details → primary action → secondary actions.
- Approval focus starts on the request summary, not Allow.
- Allow and Deny remain distinct text buttons with no destructive default.
- All tabs, page switches, refreshes, and account changes work by keyboard.
- Dynamic Type equivalents use macOS text styles and allow two-line Goal/Now before truncation.
- High contrast, Reduce Motion, Reduce Transparency, VoiceOver, Full Keyboard Access, and screen-sharing privacy mode are release gates.

## 10. Implementation roadmap

### Phase 0 — Contract and fixtures

**Outcome:** Lock the domain and test vocabulary before reshaping views.

- Add `ActivitySnapshot`, `ActivityPhase`, source/confidence types, and privacy policy.
- Create deterministic fixtures for every state, long project/goal/now text, missing sources, subagents, and multiple providers.
- Add decision records for CodexBar MIT reuse and transcript allowlisting.
- Update the roadmap so the user-approved multi-provider and notch-utility scope supersedes the old post-1.0 exclusions.

**Gate:** Pure-model tests prove precedence, freshness, redaction, deduplication, and state priority.

### Phase 1 — Structured Work parity

**Outcome:** Both modes show Project, Goal, Now, State, sessions, agents, approvals, completion, and failures.

- Stop using `AgentSession.displayName` as the primary activity label.
- Preserve chat title only as optional metadata.
- Add bounded commentary and tool-phase extraction to the local observer.
- Rebuild the notch Work page and menu-bar Work tab from the same view model.
- Keep current exact-UUID approval behavior unchanged.

**Gate:** Unit tests, integration fixtures, VoiceOver labels, rendered notch/menu states, live hook run, and stale-source recovery all pass.

### Phase 2 — Usage parity and CodexBar core

**Outcome:** Every CodexBar-equivalent usage capability is available in both modes through one Cowlick usage engine.

- Establish the pinned MIT upstream boundary and notices.
- Port provider registry, multi-account/source selection, meters, reset formatting, pace, incidents, adaptive refresh, history, charts, CLI, widgets, and notifications.
- Reconcile Cowlick’s existing official Codex, API-price equivalent, reset forecast, and organization-billing models instead of duplicating them.
- Default to Codex only; progressive disclosure reveals additional providers.

**Gate:** Provider contract tests, credential/privacy review, cold/warm refresh measurements, chart accessibility, offline/stale/error fixtures, and cross-surface parity pass.

### Phase 3 — Notch Nook and Tray

**Outcome:** Notch users receive the relevant NotchNook-class utility set without another menu-bar app.

- Add Work / Usage / Nook / Tray navigation.
- Implement Now Playing, calendar next event/live activities, customizable shortcuts, Mirror, file shelf, Share/AirDrop, drag targeting, and page gestures.
- Add per-module permissions and disable/remove controls.

**Gate:** Physical-notch interaction video, file drag/drop, camera lifecycle, calendar denial, media absent, external display, multiple Spaces, rapid gesture reversal, keyboard, and Reduce Motion all pass.

### Phase 4 — Setup and customization

**Outcome:** A new user reaches useful status in one install action plus the unavoidable Codex review.

- Replace seven steps with the three-stage flow.
- Auto-detect trust and advance without Check Again.
- Add limited mode and just-in-time optional permissions.
- Add module ordering, provider ordering, compact display preferences, and privacy preview.

**Gate:** Clean-user install recording, hook rejection/retry, Codex unavailable, no-notch Mac, notched Mac, and uninstall/purge documentation pass.

### Phase 5 — Polish, hardening, and release

**Outcome:** The experience is visually calm, responsive, accessible, and installable.

- Run the motion polish pass against real hardware and long/live content.
- Benchmark observer, providers, Mirror, waveform, charts, and drag previews.
- Run the full macOS unit/UI suites locally and on the Mac mini after its disk blocker is resolved.
- Recapture truthful launch media with a lightweight fake UI state—not a screenshot containing another notch.
- Complete Developer ID signing, notarization, clean install, update, and uninstall proof.

**Gate:** No open release-blocking gap, all representative runtime journeys pass, and the shipped artifact matches the reviewed source SHA.

## 11. Test and release matrix

Minimum combinations:

- hardware: notched MacBook, notchless Mac, notched Mac + external display;
- mode: Automatic-notched, Automatic-menu, explicit menu override;
- appearance: light desktop, dark desktop, high contrast, reduced transparency;
- motion: standard and Reduce Motion;
- content: idle, working, long goal, multi-session, subagents, approval, complete, fail, stale, integration degraded;
- usage: loading, fresh, stale, exhausted, credits, incident, multiple accounts/providers, offline;
- permissions: camera denied/allowed, calendar denied/allowed, notifications denied/allowed, Full Disk Access absent;
- input: hover, click, keyboard, VoiceOver, horizontal swipe, pull, file drag/drop;
- lifecycle: cold launch, restart recovery, Codex closed, hook untrusted, app update, uninstall.

Every visual phase must produce screenshots at 1× and 2×. Motion phases must also produce an operated video showing compact → expanded → page switch → approval interruption → resolution → collapse, plus rapid reversal at reduced playback speed.

## 12. Success criteria

The design is implemented when:

1. A user can identify Project, Goal, Now, State, agent count, and official usage in under five seconds.
2. The chat/sidebar title never substitutes for the structured hierarchy.
3. Notch mode produces no Cowlick menu-bar item and still exposes every Cowlick action.
4. Menu bar mode produces no Cowlick notch surface and retains every shared Codex/usage feature.
5. Notch mode includes media, calendar/live activities, shortcuts, Mirror, file Tray, AirDrop/share, and direct gestures.
6. All CodexBar-equivalent usage capabilities are reachable in both modes through one internal engine.
7. Approvals remain exact-request, fail-deferred, and visually dominant over utility content.
8. Optional permissions are requested only when their feature is enabled.
9. Animation is interruptible, top-attached, reduced-motion safe, and free of nested frame/shell motion.
10. Clean setup requires one Cowlick action and one unavoidable Codex security review, with automatic completion detection.

## 13. Evidence and sources

- [NotchNook official page](https://lo.cafe/notchnook): current version, widgets, live actions, file shelf, scroll/swipe, notchless handler, and multi-monitor claims.
- [NotchNook on Setapp](https://setapp.com/apps/notchnook): media controls/artwork/waveform, calendar/live activities, shortcuts, file Tray/AirDrop, Mirror, and no extra menu-bar-space claim.
- [CodexBar README](https://github.com/steipete/CodexBar/blob/main/README.md): MIT product capabilities, providers, meters, history/spend, incidents, refresh, CLI, widgets, notifications, and privacy model.
- [CodexBar changelog](https://github.com/steipete/CodexBar/blob/main/CHANGELOG.md): current pace, multi-account, history, accessibility, performance, and source-selection behavior.
- [Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/): projects, parallel agents, long-running tasks, worktrees, approvals, and command-center product framing.
- [Ping Island](https://github.com/erha19/ping-island): Apache-2.0 fixed-shell architecture already adopted and attributed by Cowlick.

The NotchNook sources confirm capabilities, not an open-source implementation. Cowlick’s interface and code must remain original. CodexBar and Ping Island are the reviewed open-source reuse candidates, under MIT and Apache-2.0 respectively.
