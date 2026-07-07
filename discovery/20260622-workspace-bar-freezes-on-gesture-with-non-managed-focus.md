# Workspace bar does not update during/after a trackpad column-switch gesture while a non-managed app holds focus — Discovery

Groom 2026-07-07: resolved — the workspace bar was rebuilt as a reactive lens over viewport selection (`8900a436`, "Make the workspace bar a reactive lens over viewport selection"), which removes the imperative focus-projection dependency that caused the freeze; see `completed/20260623-workspace-bar-reactive-viewport-lens.md`.

Discovery (2026-06-22). When the user performs a 3-finger trackpad
column-switch gesture on a workspace whose **confirmed focus is a non-managed
window** (e.g. a transient overlay, a native app-switcher foreground, or any
unmanaged app sitting on top), the workspace viewport scrolls between columns
correctly, but the **workspace bar does not update its selected-column indicator
at all** for the whole gesture and its snap animation. With the identical setup,
moving between the same columns via **hotkeys / native app-switch does update
the bar.**

Root cause: the gesture end handler writes the new viewport selection
(`state.selectedNodeId` / `state.activeColumnIndex`) to niri state, but its
managed-focus / refresh side effects are gated behind
`!controller.workspaceManager.isNonManagedFocusActive`. When a non-managed app
holds focus, that guard makes the handler take the
`focusSelection=suppressedNonManagedFocus` branch: it calls **neither**
`setManagedFocus` **nor** `requestWorkspaceProjectionRefresh`. Because the
workspace bar is derived from `confirmedManagedFocusToken` (the managed-focus
projection) and is only re-projected by a workspace-projection invalidation or a
relayout, the bar has nothing to react to and stays frozen on the column it was
on before the gesture.

This is the gesture-path sibling of
[`discovery/20260615-workspace-bar-focus-projection-routing.md`](20260615-workspace-bar-focus-projection-routing.md)
(that doc covers FFM/click focus confirms; this one covers the gesture end).
Both reduce to the same architectural fact: **the workspace bar is an imperative,
focus-projection-derived surface, not a reactive lens over viewport state**, so
any focus path that suppresses managed-focus confirmation also suppresses the
bar.

All code citations were verified against the main Nehir source tree at
`aff8a9a2` on 2026-06-22 (`git log -1 --format='%h %s'` → `aff8a9a2 Keep
transient popup surfaces out of managed activation`). Line numbers will drift.

---

## TL;DR

| Capture | `isNonManagedFocusActive` (start) | `focusSelection` on each `touch_scroll_gesture_end` | `managed_focus_requested` / `managed_focus_confirmed` emitted? | Workspace bar `lastAppliedFrame` changed during capture? |
| --- | --- | --- | --- | --- |
| **Failing** — gesture, non-managed focus on top | `true` (Teams `WindowToken(pid: 19084, windowId: 5842)` is the observed non-managed focus) | `suppressedNonManagedFocus` (×6) | **No** (only 7 × `hidden_state_changed`) | **No** — bar frame last touched ~91 s before capture started |
| **Working** — gesture, managed focus on top | `false` (Slack `WindowToken(pid: 51140, windowId: 4505)` is confirmed managed focus) | `requested` (×5) | **Yes** (5 × `managed_focus_requested`, 6 × `managed_focus_confirmed`) | **Yes** — bar refresh scheduler advances |
| **Working** — hotkeys, non-managed focus on top | `true` (same Teams token) | n/a (no gesture) | **Yes** — via `focus_lease` owner `native_app_switch` | **Yes** |

So the bug is **not** "gestures never update the bar," and **not** "non-managed
focus never updates the bar." It is specifically: the **gesture end's focus
side-effects are suppressed by the same `isNonManagedFocusActive` guard** that
the hotkey path bypasses via a focus lease.

---

## Topology / initial state required to reproduce

Single display (`ID(displayId: 1)`, `Built-in Retina Display`, notch, frame
`(0.0, 0.0, 2056.0, 1329.0)`). `displaySpacesMode=enabled`, one visible space,
`focusFollowsMouse=false`. Workspace bar enabled, `notchAware=true`,
`effectivePosition=belowMenuBar`, `barHeight=24.0`.

Visible workspace `B8C55829-F478-4242-8778-8716066A23EE` ("workspace 2") with 4
tiling columns. The session is in **non-managed focus**:
`observedManagedFocus=WindowToken(pid: 19084, windowId: 5842)` (Microsoft Teams),
`nonManaged=true`, reconcile snapshot `non-managed-focus=true`. (Teams here is
behaving as the non-managed foreground; the specific app is incidental — any
non-managed focus holder reproduces it.)

Repro: with that state held, perform a 3-finger trackpad swipe to move the
viewport across columns. The viewport moves; the workspace bar's selected
indicator does not.

---

## What the evidence proves

### 1. The gesture itself works — the viewport moves columns

The failing capture's `## Niri viewport trace` shows a full committed gesture on
workspace `B8C55829-…`:

```text
reason=touch_scroll_gesture_armed     … columns=4 activeColumnIndex=2 currentViewStart=1516.0 …
reason=touch_scroll_gesture_committed … cumulativeX=-15.639 … activeColumnIndex=2 …
reason=touch_scroll_gesture_update    … delta=39.096 … activeColumnIndex=2 currentViewStart=1582.5 gesture=true …
… many updates …
reason=touch_scroll_gesture_end_candidate … projectedViewStart=2426.037 closestSnap=2532.000 closestSnapColumn=3 …
reason=touch_scroll_gesture_end  … endedActiveColumnIndex=3 … selectedNode=NodeId(…2ABB8F94…) preferredFocus=WindowToken(pid: 6731, windowId: 5783) …
reason=scroll_animation_start … targetViewStart=2532.0 …
reason=scroll_animation_stop  … activeColumnIndex=3 currentViewStart=2532.0 …
```

The viewport's `activeColumnIndex` walks `2 → 3 → …`, `selectedNode` changes,
`currentViewStart` advances. The niri layer is doing its job. The capture
contains **six** `touch_scroll_gesture_end` records, landing on
`endedActiveColumnIndex` 0, 1, 2, 3, 3, 3 — i.e. multiple distinct columns were
visited. This is not a "gesture didn't commit" failure.

### 2. Every gesture end is classified `suppressedNonManagedFocus`

Each of the six `touch_scroll_gesture_end` records carries the same disposition:

```text
reason=touch_scroll_gesture_end … focusSelection=suppressedNonManagedFocus
  focusFollowsMouse=false endedGestureIsAnimating=true
  previousActiveColumnIndex=2 endedActiveColumnIndex=3
  preferredFocus=WindowToken(pid: 6731, windowId: 5783)
  confirmedFocus=WindowToken(pid: 19084, windowId: 5842)
```

`confirmedFocus` is the Teams non-managed token for every one of them. So the
handler resolved a `selectedWindow` (column moved), but took the branch that
does **not** request managed focus.

### 3. No managed-focus events are emitted during the failing gesture

The failing capture's `## Tracing logs` section contains **only**
`hidden_state_changed` events (7 of them) — the tiling visibility churn from
windows entering/leaving the viewport. There are **zero**
`managed_focus_requested` and **zero** `managed_focus_confirmed` records. By
contrast, the working gesture capture (managed focus on top) emits 5 ×
`managed_focus_requested` + 6 × `managed_focus_confirmed`, one per landed column
(`endedActiveColumnIndex` 0,1,1,2,3 with `confirmedFocus` tokens for Slack,
Helium, Slack, Ghostty, Finder respectively):

```text
reason=touch_scroll_gesture_end … focusSelection=requested
  endedActiveColumnIndex=1 confirmedFocus=WindowToken(pid: 51140, windowId: 4505)
reason=touch_scroll_gesture_end … focusSelection=requested
  endedActiveColumnIndex=0 confirmedFocus=WindowToken(pid: 51140, windowId: 4505)
reason=touch_scroll_gesture_end … focusSelection=requested
  endedActiveColumnIndex=1 confirmedFocus=WindowToken(pid: 57195, windowId: 4558)
…
```

### 4. The workspace bar receives no refresh during the failing capture

The failing capture's `-- Workspace Bar Frame Trace --` block's newest entry is
timestamped **~91 seconds before the capture started**:

```text
Runtime state at start: startedAt=2026-06-22T13:03:57Z
Workspace Bar Frame Trace (newest line):
  2026-06-22T13:02:26Z display=1 requested=(763.0, 1274.0, 530.0, 24.0)
    previous=(753.0, 1274.0, 550.0, 24.0) actual=(763.0, 1274.0, 530.0, 24.0) …
Workspace Bar snapshot:
  lastAppliedFrame=(763.0, 1274.0, 530.0, 24.0)   ← identical to the 13:02:26 line
```

So between 13:02:26 and the capture end (~13:04:02) — the entire window
containing the gesture — the bar's `lastAppliedFrame` did not change. The
start-snapshot refresh counters (`workspaceBarRefreshDebugState requestCount=3497
scheduledCount=2755 executionCount=2755 isQueued=false`) confirm the bar refresh
scheduler is **alive and not stuck** (`isQueued=false`, execution count is
non-zero and tracks requests). The bar simply has no new projection to apply,
because no workspace-projection invalidation reached it.

### 5. The hotkey path updates the bar despite identical non-managed focus

The hotkeys capture starts from the **same** precondition
(`observedManagedFocus=WindowToken(pid: 19084, windowId: 5842)`,
`nonManaged=true`) and the bar updates. Its `## Tracing logs` show the
difference — a focus lease drives managed focus unconditionally:

```text
#1 event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
     … lease=native_app_switch … non_managed=true
#2 event=managed_focus_confirmed token=WindowToken(pid: 19084, windowId: 5842)
#3 event=managed_focus_requested token=WindowToken(pid: 23546, windowId: 4635)   ← VSCode
#6 event=managed_focus_confirmed token=WindowToken(pid: 23546, windowId: 4635)
#22 event=managed_focus_requested token=WindowToken(pid: 57195, windowId: 537)    ← Helium
#24 event=managed_focus_confirmed token=WindowToken(pid: 57195, windowId: 537)
```

The `native_app_switch` lease bypasses the non-managed-focus suppression and
confirms managed focus for each target, which emits
`invalidateProjection(.focusProjection, …)` per confirm. (See "Why hotkeys still
work" below for why `.focusProjection` is enough to move the bar here even though
it is routed status-bar-only — the lease path also requests relayout/workspace
projection as part of the activation transition.)

---

## Root cause: the gesture end couples viewport selection, managed focus, and bar refresh behind one non-managed-focus guard

### The gesture end handler

In `MouseEventHandler`, after the snap is resolved the handler syncs niri's
viewport selection to the landed column, then conditionally drives managed focus:

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:1986
selectedWindow = syncViewportSelectionToActiveColumn(columns: columns, state: &endState)
…
// :1989-2004
var didRequestFocus = false
if let selectedWindow {
    rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)
    if !controller.focusFollowsMouseEnabled,
       !controller.workspaceManager.isNonManagedFocusActive,        // ← the gate
       let target = controller.managedKeyboardFocusTarget(for: selectedWindow.token)
    {
        _ = controller.renderKeyboardFocusBorder(for: target, …)
        controller.suppressMouseMoveToFocusedWindow(for: selectedWindow.token)
        controller.focusWindow(selectedWindow.token)                // → setManagedFocus
        didRequestFocus = true
    }
}
```

`syncViewportSelectionToActiveColumn` (`MouseEventHandler.swift:2164-2176`)
writes `state.selectedNodeId` from the active column's active tile — so **niri
viewport selection does update** regardless of focus. That is why the viewport
moves but the bar does not: the viewport state changed, the focus state did not.

The `controller.focusWindow(...)` call is what reaches
`WorkspaceManager.setManagedFocus` (`WorkspaceManager.swift:1132`), which on a
real change emits the focus invalidation:

```swift
// Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1132-1160 (setManagedFocus)
…
changed = applyFocusReconcileEvent(.managedFocusConfirmed(token: …)) || changed
if changed {
    notifySessionStateChanged()
    invalidateProjection(.focusProjection, reason: "managedFocusChanged")   // :1155
}
```

When `isNonManagedFocusActive == true`, the guard at `MouseEventHandler.swift:1993`
short-circuits before `focusWindow`, so `setManagedFocus` is never called,
`confirmedManagedFocusToken` does not advance, and no `.focusProjection`
invalidation is emitted.

### The disposition log confirms which branch ran

Right after the guard, the handler records the disposition it took
(`MouseEventHandler.swift:2006-2018`):

```swift
// Sources/Nehir/Core/Controller/MouseEventHandler.swift:2006-2018
let focusSelectionDisposition: String
if selectedWindow == nil {
    focusSelectionDisposition = "none"
} else if controller.focusFollowsMouseEnabled {
    focusSelectionDisposition = "suppressed"
} else if controller.workspaceManager.isNonManagedFocusActive {
    focusSelectionDisposition = "suppressedNonManagedFocus"   // ← failing trace
} else if didRequestFocus {
    focusSelectionDisposition = "requested"                   // ← working trace
} else {
    focusSelectionDisposition = "skippedNoManagedTarget"
}
```

This is exactly the `focusSelection=suppressedNonManagedFocus` value seen on
every gesture end in the failing capture, and `focusSelection=requested` in the
working capture.

### The workspace bar reads managed focus, and is driven by invalidations

The bar's content is a projection of the **confirmed managed focus token**, not
of the viewport's `activeColumnIndex` / `selectedNodeId`:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:692-701 (workspaceBarItems)
WorkspaceBarDataSource.workspaceBarItems(
    for: monitor,
    options: options,
    workspaceManager: workspaceManager,
    appInfoCache: appInfoCache,
    niriEngine: niriEngine,
    focusedToken: workspaceManager.confirmedManagedFocusToken,   // ← sole focus source
    settings: settings
)
```

`WorkspaceBarDataSource.workspaceItems(...)` marks windows/apps as
focused/selected by matching entries against that `focusedToken` (see
`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`). Nothing in the
projection reads the niri viewport column. So if `confirmedManagedFocusToken`
does not change, a re-projection would produce an identical snapshot and the
selected indicator would not move.

The bar is re-projected only when a workspace-projection refresh runs. The
projection invalidation router routes `.focusProjection` to the **status bar
only**, not the workspace bar:

```swift
// Sources/Nehir/Core/Controller/WMController.swift:541-553
func requestProjectionRefresh(_ invalidation: ProjectionInvalidationRequest) {
    workspaceBarRefreshDebugState.invalidationCounts[invalidation.kind, default: 0] += 1
    switch invalidation.kind {
    case .workspaceProjection:
        requestWorkspaceProjectionRefreshScheduling()   // ← updates workspace bar
    case .focusProjection:
        requestFocusProjectionRefreshScheduling()       // ← status bar only
    case .settingsProjection:
        requestSettingsProjectionRefreshScheduling()
    case .layoutProjection, .displayProjection:
        break
    }
}
```

```swift
// Sources/Nehir/Core/Controller/WMController.swift:586-590
private func requestFocusProjectionRefreshScheduling() {
    // Focus changes are only interesting while the status bar is actually
    // displaying workspace info, so skip them when the feature is off.
    requestStatusBarRefreshScheduling(reason: "focusProjection", requireFeatureEnabled: true)
}
```

In practice the working gesture/hotkey paths update the bar not through
`.focusProjection` directly but because the accompanying relayout / workspace
transition requests a `.workspaceProjection` refresh. In `LayoutRefreshController`
relayout execution plans set the effect unconditionally:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1060-1064
if refresh.kind != .visibilityRefresh, refresh.needsVisibilityReconciliation {
    plan.effects.requestWorkspaceProjectionRefresh = true
    plan.effects.updateTabbedOverlays = true
    plan.effects.refreshFocusedBorderForVisibilityState = true
}
```

(and four more sites at `:1068`, `:1102`, `:1171`, `:1528`), which
`executeRefreshExecutionPlan` routes to
`controller.requestWorkspaceProjectionRefresh()`.

The failing gesture path emits **none** of these: no `setManagedFocus`, no
`.focusProjection`, no relayout, no `.workspaceProjection`. The bar has no
trigger and no new data, so it freezes.

---

## Why hotkeys still work (the contrast that isolates the bug)

The hotkey / Cmd-Tab / Dock-activation path enters `handleAppActivation` →
`handleManagedAppActivation` and acquires a **focus lease**
(`owner=native_app_switch`, seen as `event=focus_lease_changed` in the hotkeys
capture). That lease path confirms managed focus for the resolved target
regardless of `isNonManagedFocusActive` (the whole point of the lease is to
authoritatively take focus from an external activator), then requests relayout /
workspace projection as part of the activation transition. The result is the
stream of `managed_focus_requested` / `managed_focus_confirmed` events and bar
movement seen in the hotkeys capture, starting from the same Teams non-managed
focus state.

The gesture path has **no equivalent lease or fallback**. Its only focus-driving
statement is the guarded `controller.focusWindow(selectedWindow.token)` inside
the `!isNonManagedFocusActive` block. So under non-managed focus it silently
drops focus selection (`suppressedNonManagedFocus`) and, with it, every signal
the bar listens to.

---

## Architectural framing (the user's hypothesis, confirmed)

The reporter asked whether this is because the workspace bar is handled with
mutable state instead of being a reactive lens. **Yes, and the code confirms it
on two levels:**

1. **Scheduling is imperative and scattered.** `requestWorkspaceProjectionRefresh()`
   (`WMController.swift:557`) is invoked manually from a handful of call-sites
   (`AXEventHandler.swift:536`; the `effects.requestWorkspaceProjectionRefresh`
   sites in `LayoutRefreshController.swift`; via
   `invalidateProjection(.workspaceProjection, …)` in `WorkspaceManager.swift:247`).
   There is no "viewport column changed → re-project bar" subscription. The bar
   hears about the world only when a specific mutation path remembers to notify
   it.
2. **The bar's content is a projection of managed focus, not of viewport
   state.** `WorkspaceBarDataSource.workspaceItems(...)` derives the selected
   indicator from the `focusedToken` argument (`confirmedManagedFocusToken`); it
   never reads `activeColumnIndex` / `selectedNode` / `currentViewStart`.

A single missed invalidation call-site (here, the `!isNonManagedFocusActive`
guard) therefore silently severs "world changed" from "bar re-derived." A
reactive lens over viewport state would have re-projected on every gesture
update regardless of focus disposition, because the viewport values demonstrably
changed (the capture shows `activeColumnIndex` marching 2→3→0→1→2→0). The
imperative model has exactly this failure mode.

### Nuance: there is a real semantic choice embedded in today's design

The bar today means **"the managed-focused window."** When a non-managed app is
on top, there is, by that definition, nothing managed to highlight. So this is
not purely an oversight; the guard encodes a deliberate "don't yank the
managed-focus anchor around while an unmanaged app owns focus" policy (the same
policy visible in `handleFocusFollowsMouse` at `MouseEventHandler.swift:1253`,
which bails FFM on the same `isNonManagedFocusActive` flag). The bug is the
**conflation** of two concerns through one guard:

- *Viewport selection* — which column the viewport is parked on (always meaningful
  to show, and demonstrably changing).
- *Managed-focus selection* — which managed window the bar should highlight as
  focused (genuinely ambiguous under non-managed focus).

Suppressing the focus half currently suppresses the bar half too, because the
bar reads focus state rather than viewport state and is driven by focus
invalidations rather than viewport invalidations.

---

## Fix directions (no implementation in this pass)

Three options, increasing in scope. The choice forces a product decision: **what
should the bar show when the viewport is parked on a column whose window is not
the managed focus?**

### Option A — Minimal: emit a workspace-projection refresh on gesture-end viewport selection change

Keep current semantics ("bar = managed focus") but plug the missed call-site.
After `syncViewportSelectionToActiveColumn` writes the new `selectedNodeId` /
`activeColumnIndex`, request a workspace-projection refresh unconditionally
(without going through `setManagedFocus`), so the bar re-projects. Since the
projection reads `confirmedManagedFocusToken` (unchanged), this would re-project
an identical focus snapshot — i.e. it fixes only the *accompanying* bar churn
(visible-window-icon updates as columns scroll past), **not** the selected-column
indicator, which would still point at the stale managed focus.

- Pro: smallest change; no semantic shift; no new state.
- Con: **does not move the selected indicator** to the gesture's landed column
  (that requires the bar to know about viewport position — see Option C). So
  Option A alone is likely insufficient for what the reporter expects ("the bar
  should follow my gesture"). It is only sufficient if the reported freeze is
  purely about icon membership churn, which the evidence does not support — the
  selected indicator is the visible symptom.

### Option B — Route `.focusProjection` to the workspace bar too

Make focus changes workspace-bar-relevant (the Option A of the sibling doc
`20260615-workspace-bar-focus-projection-routing.md`):

```swift
case .workspaceProjection, .focusProjection:
    requestWorkspaceProjectionRefreshScheduling()
```

- Pro: fixes the whole family of "focus changed but bar didn't" bugs in one
  place; reuses existing coalescing.
- Con: **still does not fix this gesture case** — the failing gesture emits no
  `.focusProjection` at all (it is suppressed before `setManagedFocus`), so
  routing `.focusProjection` differently has nothing to route. Option B is
  orthogonal to this bug; it addresses the sibling click/FFM bug.

### Option C — Make the bar's selected indicator a lens over viewport column (the architectural fix)

Decouple "which column is highlighted" from `confirmedManagedFocusToken`:

- Add the visible workspace's `activeColumnIndex` (or `selectedNode`'s owning
  window) to `WorkspaceBarProjectionOptions` / `WorkspaceBarDataSource` inputs,
  sourced from the niri engine.
- Drive the workspace **pill / column** selected state from viewport position;
  keep the per-window **focus dot** from `confirmedManagedFocusToken`.
- Invalidate the bar on viewport selection change (the gesture handler already
  has the new `selectedNodeId` in hand at `MouseEventHandler.swift:1986`; emit a
  workspace-projection refresh there).

This is the reactive-lens direction. It makes the bar correct under both
non-managed focus and suppressed-focus gestures, because it no longer depends on
the guarded focus path at all for "where am I."

- Pro: fixes the reported bug at its architectural root; eliminates the class of
  "missed invalidation" failures for viewport-driven UI; aligns the bar's
  "selected" concept with what the user actually sees (the viewport column).
- Con: largest scope; introduces a second source of truth for "selected" that
  must be reconciled with "focused" (e.g. when managed focus and viewport column
  disagree — exactly the non-managed-focus case). Needs a clear rule for when
  the per-window focus dot is shown vs. the viewport-column highlight.

### Recommendation

The reporter's expectation ("bar follows the gesture") implies the selected
indicator should track the viewport column, which is Option C. Option A alone is
insufficient; Option B is a good adjacent fix for the sibling bug but does not
address this one. A pragmatic path: land Option B (fixes the click/FFM family)
**and** a scoped version of Option C that adds viewport-column as a bar input
and emits a workspace-projection refresh at the gesture-end call-site, leaving
the managed-focus guard intact (so the anchor policy is preserved) while still
moving the bar.

---

## Test coverage gaps

No existing test exercises "gesture end under non-managed focus." Relevant
existing coverage:

- `RefreshRoutingTests` validates `.workspaceProjection` coalescing and
  `requestWorkspaceProjectionRefresh` scheduling, but does not simulate a
  gesture-end path or assert that a suppressed-focus gesture still refreshes the
  bar.
- `WorkspaceBarDataSourceTests` passes a fixed `focusedToken` and checks
  projection shape; it does not read viewport column and does not assert
  refresh triggering.
- `WorkspaceManagerTests` observes focus invalidations, not their consumers, and
  not the gesture path.

Recommended regression tests (after the fix is confirmed in the reporter's
repro):

1. **Gesture end under non-managed focus still moves the bar's viewport-derived
   selected state.** Drive a gesture end with `isNonManagedFocusActive == true`,
   assert the bar's selected column/pill reflects the landed column (requires
   Option C input) and that a workspace-projection refresh was requested.
2. **Gesture end under managed focus still confirms focus and refreshes the bar.**
   The `focusSelection=requested` path; assert `managed_focus_confirmed` and bar
   refresh both occur.
3. **Focus anchor policy preserved.** Under non-managed focus, the gesture end
   must **not** call `setManagedFocus` / advance `confirmedManagedFocusToken`
   (the guard's original purpose still holds).

---

## Open questions

- **What exactly should "selected" mean on the bar under non-managed focus?**
  The reporter's expectation ("follow the gesture") implies viewport column
  (Option C). Confirm with the reporter before implementing, because it changes
  the bar's semantics, not just a refresh path.
- **Is the same freeze seen with 4-finger gestures and with
  mouse-button-initiated column moves?** The mechanism is finger-count- and
  input-source-independent (the guard is in the shared gesture-end handler), so
  it should reproduce identically; a confirming trace would strengthen the fix
  scope.
- **Does the freeze also affect the status bar's workspace-name display?**
  `.focusProjection` is routed to the status bar, but the failing gesture emits
  no `.focusProjection` either, so the status bar is likely frozen for the same
  reason on the same gesture. Worth confirming in the same follow-up trace.
