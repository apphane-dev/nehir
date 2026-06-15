# New Window Created on Wrong Monitor — Discovery (Step 2 of 2)

Reported issue: **a newly created window is placed on the main monitor even
though the currently active monitor is the secondary one.**

This is **step 2** of a two-step discovery. **Step 1**
(`20260615-new-window-placement-tracing.md`) adds the create-focus trace to the
runtime trace dump; it is a prerequisite for confirming the root cause here.
This doc contains the full investigation, hypotheses, fix direction, and **all
findings inlined from the repro trace** so it stands alone.

All file references should be re-verified before implementing; line numbers drift.

---

## TL;DR

> **Updated after step 1 landed** (2026-06-15, second capture set). The new
> `## Niri create focus trace` section wrote `create_placement_resolved` to
> the dump and **refuted both original hypotheses**. See
> [Step 1 confirmed — root cause revised](#step-1-confirmed--root-cause-revised-2026-06-15).

- **Root cause (H4, confirmed by tracing):** for every new Ghostty window
  captured with the new tracing, **all** snapshotted placement inputs are
  `nil` (`pending_workspace`, `pending_monitor`, `focused_workspace`,
  `focused_monitor`, `native_monitor`, `interaction_monitor`; only
  `frame_monitor` is occasionally non-nil). With the snapshot empty,
  `createPlacementTarget` falls straight through every priority branch to its
  final fallback, `fallbackWorkspaceId` (`WMController.swift:1271`), which is
  the **live** `interactionWorkspace()?.id` (`WMController.swift:2953`).
  `interactionWorkspace()` → `monitorForInteraction()` (`WMController.swift:922`)
  returns `monitors.first` — i.e. the **main** display, because
  `Monitor.current()` is built from `NSScreen.screens` whose index 0 is the
  main screen (`Monitor.swift:19`) — whenever `interactionMonitorId` **and**
  `confirmedManagedFocusToken` are both nil. That is exactly the transient
  state left behind by the app-switch / non-managed-focus churn. So a
  brand-new window is placed on the **main monitor regardless of where the
  user actually is.**
- `monitorForInteraction()` consults `interactionMonitorId`, then the focused
  token's monitor, then `monitors.first` — it **never** consults
  `previousInteractionMonitorId` (`WorkspaceManager.swift:166`), which exists
  precisely to remember the monitor across such a transient clear. That gap is
  the bug.
- The earlier reasoning (H1 favored) was a best-effort read of a dump that
  lacked `create_placement_resolved`; the `native_app_switch` lease observed in
  the first capture was a *consequence* of where focus ended up, not the
  *cause* of placement.
- **Fix direction (revised, surgical):** make `monitorForInteraction()` prefer
  `previousInteractionMonitorId` over the bare `monitors.first` fallback, so
  the new-window placement path preserves the last-known monitor across the
  transient clear. See [Fix direction (revised)](#fix-direction-revised-after-step-1).

The sections below this point are the **original step-2 investigation**,
preserved for context. The section above and the
[Step 1 confirmed](#step-1-confirmed--root-cause-revised-2026-06-15) section
supersede the H1/H2/H3 hypotheses.

---

## Step 1 confirmed — root cause revised (2026-06-15)

Step 1 landed (the runtime dump now includes a `## Niri create focus trace`
section that writes `create_placement_resolved`). Two captures taken with it
built (nehir v0.5.0, build `v92ab0c`) contain the decisive event for three
separate new **Ghostty** windows. All findings are inlined below; nothing in
this section depends on a trace file surviving.

### Monitor topology (identical in both captures, unchanged across each)

```
ID(displayId: 1) isMain=true  hasNotch=true  frame=(0.0, 0.0, 2056.0, 1329.0)
    visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
ID(displayId: 2) isMain=false hasNotch=false frame=(-282.0, 1329.0, 2560.0, 1440.0)
    visibleFrame=(-282.0, 1329.0, 2560.0, 1440.0) name=DELL P2423D
```

Workspace → monitor mapping (stable, from `-- Niri Viewports --`):
- **workspace 1** = `7BDEC9B0-C9A1-4CE7-8D55-81C7B311923E` → **display 1**
- **workspace 6** = `732AF6A9-86E9-44A5-BB39-BD8BAFAE75CD` → **display 2**

Display 1 is `isMain`. `monitors.first` therefore resolves to display 1
(`Monitor.current()` is `NSScreen.screens`, whose index 0 is the main screen —
`Monitor.swift:19`).

### The decisive evidence: `create_placement_resolved` with an empty snapshot

Capture A (startedAt `2026-06-15T17:47:13Z`, duration 6.844 s). At START the
user was on display 1 (`focus focused=897:4920`,
`interaction current=ID(displayId: 1)`). The new Ghostty window `897:5045`
resolved with **every** input nil:

```
create_placement_resolved token=WindowToken(pid: 897, windowId: 5045)
  workspace=7BDEC9B0-C9A1-4CE7-8D55-81C7B311923E
  pending_workspace=nil pending_monitor=nil
  focused_workspace=nil focused_monitor=nil
  native_monitor=nil frame_monitor=nil interaction_monitor=nil
```

Capture B (startedAt `2026-06-15T17:48:48Z`, duration 7.783 s). At START the
focus was non-managed (`focus focused=nil`, `non-managed-focus=true`,
`interaction current=ID(displayId: 1)`). Two more Ghostty windows resolved
the same way:

```
create_placement_resolved token=WindowToken(pid: 897, windowId: 5060)
  workspace=7BDEC9B0-C9A1-4CE7-8D55-81C7B311923E
  pending_workspace=nil pending_monitor=nil
  focused_workspace=nil focused_monitor=nil
  native_monitor=nil frame_monitor=nil interaction_monitor=nil

create_placement_resolved token=WindowToken(pid: 897, windowId: 5070)
  workspace=7BDEC9B0-C9A1-4CE7-8D55-81C7B311923E
  pending_workspace=nil pending_monitor=nil
  focused_workspace=nil focused_monitor=nil
  native_monitor=nil
  frame_monitor=Optional(Nehir.Monitor.ID(displayId: 1)) interaction_monitor=nil
```

All three resolved to workspace 1 (display 1). For `5070` the only non-nil
input is `frame_monitor=display 1`, which is just the window's own birth frame
— it was born on display 1's geometry, so it is consistent with the main
monitor, not an independent signal. The matching reconcile snapshot at the
end of capture B confirms the result: `5070` tiled at
`liveAXFrame={{1336.0, 0.0}, {1006.0, 1280.0}}` on `monitor=ID(displayId: 1)`.

### What this refutes and what it proves

| Hypothesis | Status | Evidence |
|---|---|---|
| **H1** pending managed focus from app switch wins | **Refuted** | `pending_workspace=nil`, `pending_monitor=nil` in all 3 events. The app-switch lease did **not** leave a pending request at capture time. |
| **H2** native Space input wins | **Refuted** | `native_monitor=nil` in all 3 events. `resolveNativeSpacePlacementMonitorId` returned nil. |
| **H3** same-app sibling preference | N/A (downstream) | Only fires off a `workspaceName` rule / authoritative target; none of the snapshot inputs produced an authoritative target. |
| **H4 (new, confirmed)** empty snapshot → live fallback → `monitors.first` | **Confirmed** | All snapshot inputs nil ⇒ `createPlacementTarget` reaches its final `fallbackWorkspaceId` branch ⇒ `interactionWorkspace()?.id` ⇒ `monitorForInteraction()` ⇒ `monitors.first` (main). |

### The mechanism, cited

1. `createPlacementTarget` (`WMController.swift:1195`) tries, in order:
   `activeFocusRequest*`, `focused*` (both via `managedFocusPlacementTarget`,
   `:1237`), `nativeSpaceMonitorId` (`:1257`), frame monitor (`:1266`),
   multi-monitor fast-AX frame (`:1274`), and only then (for new tiling,
   since `preferManagedFocusPlacement` already ran) `interactionMonitorId`
   (`:1260`), and finally `fallbackWorkspaceId` (`:1271`). With every
   snapshotted input nil and no usable frame, **only the last branch fires**.
2. `fallbackWorkspaceId` is `interactionWorkspace()?.id`, supplied live at the
   call site (`WMController.swift:2953`) — not snapshotted.
3. `interactionWorkspace()` (`WMController.swift:957`) → `monitorForInteraction()`
   (`WMController.swift:922`) falls back to `monitors.first` when both
   `interactionMonitorId` and `confirmedManagedFocusToken` are nil. It does
   **not** consult `previousInteractionMonitorId` (`WorkspaceManager.swift:166`).
4. So a new window, created during the transient post-app-switch window where
   focus/interaction state is cleared, is placed on the **main monitor** no
   matter where the user is.

### Why the reconcile snapshot still shows `interaction current=ID(displayId: 1)`

`captureCreatePlacementContext` reads the **raw** `interactionMonitorId` on the
main actor (`AXEventHandler.swift:3404`; `AXEventHandler` is `@MainActor` at
`:141`), and that raw value is `nil` at `CGSWindowCreated` time. The reconcile
snapshot, by contrast, runs `reconcileInteractionMonitorState`
(`WorkspaceManager.swift:3972`) which **writes back** a derived value —
`interactionMonitorId ?? focusedWorkspaceMonitor ?? monitors.first?.id` — so
the dump shows display 1 even when the raw value was nil. This is why the
snapshot and the `create_placement_resolved` `interaction_monitor` field
disagree: the former is reconciled, the latter is the raw capture.

### Caveat on these two captures

In **both** new captures the user was already on display 1, so placing the new
Ghostty window on display 1 was *not* a visible misplacement — the symptom was
**latent**. What the captures prove is the **mechanism**: a real new window
funnels through the empty-snapshot → `monitors.first` fallback. In the original
repro (user on display 2) the identical mechanism routes the window to display
1 — that is the reported bug. The remaining open question is *what* on the main
actor clears the raw `interactionMonitorId` to nil during the app-switch
sequence (see [Open questions](#open-questions-for-step-1-output)); the fix
below is robust to it regardless.

---

## Inlined trace findings (self-contained)

> Source: runtime trace capture, nehir v0.5.0, startedAt 2026-06-15T11:29:41Z,
> endedAt 2026-06-15T11:29:47Z, duration 5.372 s. Captured during/after the bug.

### Monitor topology (unchanged across the capture)

```
ID(displayId: 1) isMain=true  hasNotch=true  frame=(0.0, 0.0, 2056.0, 1329.0)
    visibleFrame=(0.0, 0.0, 2056.0, 1290.0) name=Built-in Retina Display
ID(displayId: 2) isMain=false hasNotch=false frame=(-282.0, 1329.0, 2560.0, 1440.0)
    visibleFrame=(-282.0, 1329.0, 2560.0, 1440.0) name=DELL P2423D
```

Display 2 sits physically **above** display 1 (display 2's y-origin `1329` ==
top of display 1's frame). **Display 1 is `isMain`.**

### Workspace → monitor mapping (stable)

- **workspace 1** = `45A8DBE4-01E6-490A-8D85-B02BEED5AD30` → **display 1**
- **workspace 6** = `DEB08563-2A37-4094-BCF1-1D01647C36F9` → **display 2**

Both visible at start and end. Workspaces 2–5, 7 had no columns.

### State at START (11:29:41Z) — user is on the secondary monitor

Focus / interaction targets:

```
interactionWorkspace=DEB08563… (workspace 6 → display 2)
interactionMonitor=ID(displayId: 2)
wmCommandTarget=WindowToken(pid: 33877, windowId: 1989)   ← Telegram
observedManagedFocus=WindowToken(pid: 33877, windowId: 1989)
focus focused=33877:1989 pending=nil scratchpad=nil
interaction current=ID(displayId: 2) previous=ID(displayId: 1)
lease=false
```

So: **confirmed focus = Telegram (display 2); interaction monitor = display 2.**

Managed windows at start:

| token | app (bundleId) | workspace | display | phase | liveAXFrame |
|---|---|---|---|---|---|
| 897:2314 | ghostty (`com.mitchellh.ghostty`) | 45A8DBE4 (ws1) | **1** | tiled, visible | {525,0 1006×1280} |
| 12399:149 | vscode (`com.microsoft.VSCodeInsiders`) | 45A8DBE4 | 1 | offscreen, hidden=layoutTransient(left) | … |
| 33418:1692 | helium (`net.imput.helium`) | 45A8DBE4 | 1 | offscreen, hidden=layoutTransient(left) | … |
| 84013:1025 | slack (`com.tinyspeck.slackmacgap`) | 45A8DBE4 | 1 | tiled, visible | {-793,0 1310×1280} |
| 33877:1989 | telegram (`ru.keepcoder.Telegram`) | DEB08563 (ws6) | **2** | tiled, visible | {-272,1329 2540×1430} |

**Ghostty already had one window (`2314`) on display 1** before the new window
appeared.

### The triggering event sequence (`## Tracing logs`)

Exact records, in order:

```
#1  11:29:44  non_managed_focus_changed active=true fullscreen=false
              preserve=false preserve_pending=false
              plan=focus=focused=nil,pending=nil,non_managed=true
#2  11:29:45  window_admitted token=897:2314  workspace=45A8DBE4  mode=tiling
              plan=phase=tiled desired=workspace=45A8DBE4,mode=tiling
#3  11:29:45  window_admitted token=897:2318  workspace=45A8DBE4  mode=tiling
              plan=phase=tiled desired=workspace=45A8DBE4,mode=tiling
#4  11:29:45  managed_focus_confirmed token=897:2318 workspace=45A8DBE4
              monitor=Optional(ID(displayId: 1)) fullscreen=false
              plan=focus=focused=897:2318,pending=nil
#5  11:29:45  focus_lease_changed owner=native_app_switch
              reason=workspaceDidActivateApplication
              plan=focus=focused=897:2318,pending=nil,lease=native_app_switch
#6  11:29:45  managed_focus_confirmed token=897:2318 … displayId: 1
              lease=native_app_switch
#7  11:29:45  managed_focus_requested token=897:2318 workspace=45A8DBE4
              monitor=Optional(ID(displayId: 1))
              plan=focus=focused=897:2318,pending=897:2318,lease=native_app_switch
#8  11:29:45  managed_focus_confirmed token=897:2318 … focused=897:2318,pending=nil
#9  11:29:45  managed_replacement_metadata_changed token=897:2318 …
#10 11:29:45  window_admitted token=897:2314  workspace=45A8DBE4 …   (re-emit during rule reeval)
#11 11:29:45  window_admitted token=897:2318  workspace=45A8DBE4 …   (re-emit during rule reeval)
#12 11:29:45  hidden_state_changed token=84013:1025 (slack) hidden=true plan=phase=offscreen
#13–#15       managed_replacement_metadata_changed token=897:2318 …
```

Key reads from this sequence:

1. **`#3` is the bug.** The new Ghostty window `897:2318` is admitted with
   `workspace=45A8DBE4` (display 1) already baked in. The workspace is decided
   *before* admission (see code path below), so this is the decision being
   recorded, not a post-hoc move.
2. **`#1` clears confirmed focus first.** `non_managed_focus_changed active=true
   preserve=false` → `plan=focus=focused=nil,…`. At the moment the new window's
   `CGSWindowCreated` fired, `confirmedManagedFocusToken` was very likely `nil`,
   which means `resolveFocusedPlacementWorkspaceId` (`AXEventHandler.swift:3378`)
   would have returned `nil` → the placement context's `focusedWorkspaceId` was
   likely `nil`. This knocks input #2 (focused workspace) out of contention and
   pushes the decision onto input #1 (`activeFocusRequest*`) or #3
   (`nativeSpaceMonitorId`).
3. **`#5` is the app-switch signature.** `focus_lease owner=native_app_switch
   reason=workspaceDidActivateApplication`. The new window was created in the
   wake of an app activation into Ghostty (e.g. Cmd-Tab to Ghostty, or Ghostty
   self-activating on new-window). This is the mechanism most likely to have set
   `activeFocusRequestWorkspaceId` toward Ghostty's existing workspace on
   display 1.

### State at END (11:29:47Z)

```
interaction-monitor=ID(displayId: 1)
previous-interaction-monitor=ID(displayId: 2)
focused=WindowToken(pid: 897, windowId: 2318)
focus-lease=native_app_switch
```

New window `897:2318` now managed:

```
WindowToken(pid: 897, windowId: 2318) workspace=45A8DBE4 … phase=tiled
  liveAXFrame={{1032.0, 0.0}, {1006.0, 1280.0}}   ← display 1, right of 2314
```

Both Ghostty windows (`2314` at x=18→525, `2318` at x=1032) ended tiled on
**display 1**, in workspace 1. Slack (`84013:1025`) was pushed offscreen
(`hidden_state_changed`, `#12`) to make room — workspace 1 went from 4 columns
to 5 (`activeColumnIndex` 3 → 4), confirming the new window slotted into the
display-1 tiling layout.

### What the dump does *not* contain (the gap step 1 closes)

No `create_placement_resolved` line. The `## Niri viewport trace` records
(`reason=ax_focus_confirm_*`, token `897:2318`) are all *post-admission* focus
confirmation on workspace 1 — they confirm the window is now on display 1, not
*why* it was placed there. The decisive pre-admission placement event is in
`createFocusTrace`, which the dump writer (`WMController.swift:2655`–`2696`) does
not emit.

---

## The placement decision path (cited)

1. `AXEventHandler.handleCGSWindowCreated` (`:420`) →
   `captureCreatePlacementContext(windowId:spaceId:)` (`:3356`) snapshots a
   `WindowCreatePlacementContext` (`:80`):
   - `nativeSpaceMonitorId` ← `resolveNativeSpacePlacementMonitorId` (`:3388`)
   - `activeFocusRequestWorkspaceId/MonitorId` ←
     `controller.workspaceManager.activeFocusRequestWorkspaceId` etc.
   - `focusedWorkspaceId/MonitorId` ← `resolveFocusedPlacementWorkspaceId`
     (`:3378`), which reads `confirmedManagedFocusToken`
   - `interactionMonitorId` ← `controller.workspaceManager.interactionMonitorId`
2. `processCreatedWindow` (`:425`) → `prepareCreateCandidate` →
   `WMController.resolvedWorkspaceId` (`:1908`) →
   `resolveWorkspacePlacement` (`:1008`) → `createPlacementTarget` (`:1205`).
3. In `resolveWorkspacePlacement`, for a new tiling window, before any workspace
   *rule* is applied:
   - `structuralReplacementWorkspaceId` (`:1019`) — N/A here.
   - `inheritTrackedParentWorkspace` (`:1026`) — N/A (not a child/sheet).
   - `createPlacementTarget(...)` is computed with
     `preferManagedFocusPlacement: existingEntry == nil &&
     restrictWorkspaceRuleToPlacementMonitor` == **true** for new tiling.
   - `preferSameAppSiblingWorkspace` (`:1043`) → `workspaceForNewSiblingWindow`
     (`:1086`) — see H3.
   - then the `workspaceName` rule branch (`:1054`) and finally
     `defaultWorkspaceId(placementTarget:)` (`:1186`).
4. `createPlacementTarget` (`:1205`) with `preferManagedFocusPlacement == true`
   tries, in order, `managedFocusPlacementTarget` (`:1298`) for
   **(a)** `activeFocusRequest*`, then **(b)** `focused*`; then `nativeSpaceMonitorId`,
   then frame monitor, then fast-AX-frame monitor (multi-monitor), then
   `interactionMonitorId`, then `fallbackWorkspaceId`.
   `managedFocusPlacementTarget` returns `isAuthoritative: true`, so whichever
   of (a)/(b) hits **wins outright** and short-circuits the rest.
5. `WMController.addWindow` call site: `WMController.swift:2893`; the
   `.windowAdmitted` reconcile event is emitted inside
   `WorkspaceManager.addWindow` (`WorkspaceManager.swift:2456`) — this is the
   `#3` trace record.

`activeFocusRequestWorkspaceId` is `sessionState.focus.pendingManagedFocus.workspaceId`
(`WorkspaceManager.swift:1054`) — i.e. the workspace of the **pending** managed
focus request at snapshot time.

---

## Hypotheses

### H1 — pending managed focus request from the app switch (favored)

The `native_app_switch` / `workspaceDidActivateApplication` activation into
Ghostty began a managed focus request toward Ghostty's existing window `897:2314`
on display 1, setting
`sessionState.focus.pendingManagedFocus.workspaceId = 45A8DBE4`. When the new
window's `CGSWindowCreated` fired, `captureCreatePlacementContext` snapshotted
that pending request, and `createPlacementTarget`'s **first** check
(`activeFocusRequest*`) resolved authoritatively to workspace 1 / display 1 —
overriding both the live interaction monitor (display 2) and the (just-cleared,
see `#1`) confirmed focus.

Consistent with: the `native_app_switch` lease (`#5`), the existing Ghostty
window already living on display 1, and the `#1` focus clear that disables the
"focused workspace" input. Disambiguator from step 1: `create_placement_resolved`
would show `pending_workspace=45A8DBE4` == resolved `workspace`.

### H2 — native Space input

macOS created the window on display 1's Space (where Ghostty already had a
window). With `focusedWorkspaceId` cleared by `#1`, input #3
(`nativeSpaceMonitorId`) could win if `activeFocusRequest*` was also nil at
snapshot time. Consistent with the outcome; disambiguator from step 1:
`create_placement_resolved` would show `pending_workspace=nil` and
`native_monitor=ID(displayId: 1)` == resolved workspace's monitor.

### H3 — same-app sibling preference (likely rule-out)

`shouldPreferSameAppSiblingWorkspace` (`WMController.swift` near `:1164`) only
fires when the rule decision returned a `workspaceName` *and* that workspace
already exists. Plain Ghostty has no workspace rule in this config, so this
branch should be inactive. Verify by checking `evaluation.decision.workspaceName`
is `nil` for the Ghostty window. `workspaceForNewSiblingWindow` (`:1086`) also
respects `targetMonitorId` (the placement target's monitor), so even if reached
it would not force a *different* monitor than the placement target already
chose — it is downstream of H1/H2, not an independent cause.

---

## Reproduction steps (for a fresh capture with step 1 in place)

1. Two monitors: main (display 1) + secondary (display 2). Topology as inlined
   above (secondary above main is incidental; any 2-monitor layout reproduces).
2. On **display 1**, have a Ghostty window open in workspace 1.
3. Focus **Telegram** (or any app) on **display 2**. Confirm
   `interaction-monitor=ID(displayId: 2)` in a runtime dump before proceeding.
4. Trigger the app switch into Ghostty + new window (Cmd-Tab to Ghostty, then
   Ghostty's new-window action — the exact trigger that produced the
   `workspaceDidActivateApplication` lease). Start runtime trace capture just
   before.
5. Stop capture. Read the new `## Niri create focus trace` section: find
   `create_placement_resolved token=…:2318 workspace=45A8DBE4 …` and compare
   `workspace=` against `pending_workspace` / `focused_workspace` /
   `native_monitor` / `frame_monitor` / `interaction_monitor`.

---

## Fix direction (revised after step 1)

**Primary fix (confirmed root cause H4):** the new-window placement fallback
resolves to `monitors.first` because `monitorForInteraction()`
(`WMController.swift:922`) ignores `previousInteractionMonitorId`. Make it
consult the previous monitor before falling back to `monitors.first`:

```swift
func monitorForInteraction() -> Monitor? {
    if let interactionMonitorId = workspaceManager.interactionMonitorId,
       let monitor = workspaceManager.monitor(byId: interactionMonitorId) {
        return monitor
    }
    // NEW: preserve the last-known monitor across a transient clear
    if let previousInteractionMonitorId = workspaceManager.previousInteractionMonitorId,
       let monitor = workspaceManager.monitor(byId: previousInteractionMonitorId) {
        return monitor
    }
    if let focusedToken = workspaceManager.confirmedManagedFocusToken,
       let workspaceId = workspaceManager.workspace(for: focusedToken),
       let monitor = workspaceManager.monitor(for: workspaceId) {
        return monitor
    }
    return workspaceManager.monitors.first
}
```

This is the smallest change that fixes the reported case: in the original
repro the user was on display 2, so `previousInteractionMonitorId` would hold
display 2 at the moment the new window's snapshot is empty, and the fallback
would place the window on display 2 instead of snapping to main.

`previousInteractionMonitorId` is already maintained by `updateInteractionMonitor`
(`WorkspaceManager.swift:3939`) whenever the monitor changes, and it is exposed
in the dump as `previous-interaction-monitor`, so the fix is low-risk and
observable. Add a regression test on the inlined scenario (two monitors,
confirmed focus + interaction on display 2, app-switch into an app whose
existing window is on display 1, spawn a new window, assert the resolved
workspace is on display 2) near
`Tests/NehirTests/AXEventHandlerTests.swift:9703`.

A narrower alternative is to make only `createPlacementTarget`'s final
`fallbackWorkspaceId` branch consult `previousInteractionMonitorId`, but fixing
`monitorForInteraction()` is preferred because the fallback chain is shared by
all interaction-monitor consumers, and they have the same blind spot.

---

The candidate fixes below are the **original (pre-step-1) options**, retained
for context. They were predicated on H1/H2 and are now **moot** — step 1
proved the snapshot inputs were nil, so none of them was the winning input.

## Fix direction (pending step 1 confirmation) — historical

These are candidate fixes, to be selected after step 1 names the winning input.
All touch `createPlacementTarget` / `resolveWorkspacePlacement`
(`WMController.swift:1008`–`1296`) or the snapshot in
`AXEventHandler.captureCreatePlacementContext` (`:3356`).

### If H1 confirmed (pending managed focus from app switch wins)

The placement authority for a **brand-new** window should not be a pending focus
request that (a) was initiated by an app-switch lease, not by the user, and (b)
targets an *existing sibling's* monitor that differs from the live interaction
monitor. Options:

- **A. Scope what gets snapshotted.** In `captureCreatePlacementContext`, do not
  treat an app-switch-leased pending request as placement-authoritative. Either
  skip `activeFocusRequest*` when the current lease owner is `native_app_switch`,
  or clear it from the snapshot when it conflicts with `interactionMonitorId`.
- **B. Reorder authority for new windows.** For `existingEntry == nil` only,
  prefer `interactionMonitorId` (the monitor the user is actually on) over
  `activeFocusRequest*` when they disagree, and only fall back to the pending
  request when there is no interaction monitor signal.
- Prefer the more surgical option (A) first; (B) changes broader precedence and
  needs the existing placement tests re-run.

### If H2 confirmed (native Space wins)

Demote `nativeSpaceMonitorId` to non-authoritative in `createPlacementTarget`
when it disagrees with `interactionMonitorId` / confirmed focus — i.e. let the
native Space seed a *candidate* but not override the live interaction monitor for
new windows. Keep it authoritative when it agrees (common single-monitor /
first-window case).

### Guard regardless of cause

Add a regression test on the exact inlined scenario: two monitors, confirmed
focus + interaction monitor on display 2, an app's existing window on display 1,
spawn a new window of that app via an app-switch lease, assert the new window's
`desired.workspaceId` resolves to a workspace on **display 2**. The placement
tests under `Tests/NehirTests/AXEventHandlerTests.swift` (esp. around the
`focusedUntrackedStandardWindowAdmissionUsesCapturedCreatePlacementContext`
test, `:9703`) are the right neighbourhood to extend.

---

## Open questions for step 1 output

**Answered (2026-06-15, second capture):**

1. ✅ Which input equals the resolved workspace? **None of the snapshotted
   inputs.** All of `pending_*`, `focused_*`, `native_monitor`,
   `interaction_monitor` are `nil` (only `frame_monitor` non-nil for one
   window, and only because it was born on display 1). The decision is made by
   the **live fallback** `fallbackWorkspaceId = interactionWorkspace()?.id`,
   which degenerates to `monitors.first` (main). ⇒ H4, H1 and H2 refuted.
2. ✅ Was `activeFocusRequestWorkspaceId` non-nil / equal to the resolved
   workspace? **No — `pending_workspace=nil`.** Refutes H1 outright.
3. ✅ Was `focusedWorkspaceId` nil at snapshot time? **Yes —
   `focused_workspace=nil`, `focused_monitor=nil`.** The "focused workspace"
   input was disabled in all three events.
4. ⬜ (still open, secondary) **What clears the raw `interactionMonitorId` to
   nil on the main actor right before these `CGSWindowCreated` events?**
   `StateReducer.nonManagedFocusChanged` (`StateReducer.swift:340`) does **not**
   touch it, so the nil comes from an `updateInteractionMonitor(nil, …)` call
   elsewhere in the `workspaceDidActivateApplication` / `focusedWindowChanged`
   churn. Name that call site. Note: the proposed fix via
   `previousInteractionMonitorId` is correct regardless of the answer, but
   identifying the writer would let us also stop the spurious clear.
