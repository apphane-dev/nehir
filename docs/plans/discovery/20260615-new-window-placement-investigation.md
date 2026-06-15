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

- **Confirmed reproducible** from a runtime trace capture (nehir v0.5.0,
  2026-06-15, 11:29:41Z–11:29:47Z). A new **Ghostty** window (`pid 897`,
  `windowId 2318`) was admitted to **workspace 1 on the main monitor (display
  1)** while the user's interaction monitor and confirmed focus were on the
  **secondary monitor (display 2)**.
- Placement for a new tiling window is decided in
  `WMController.resolveWorkspacePlacement` (`WMController.swift:1008`) →
  `createPlacementTarget` (`:1205`) from a snapshot captured at
  `CGSWindowCreated` time (`AXEventHandler.captureCreatePlacementContext`,
  `:3356`). Seven inputs feed one strict-priority decision; the existing dump
  shows only the result.
- **Most likely cause (H1):** a native app-switch into Ghostty
  (`focus_lease owner=native_app_switch reason=workspaceDidActivateApplication`)
  left a pending managed focus request pointing at Ghostty's *existing* window
  on display 1. `activeFocusRequestWorkspaceId` is checked **first** in
  `createPlacementTarget`, so the new window inherited display 1 — overriding
  the live interaction monitor (display 2) and confirmed focus (Telegram).
- **Cannot be fully disambiguated from the current trace** because the
  decisive event (`create_placement_resolved`) is not written to the dump. That
  is exactly what step 1 fixes. The evidence below narrows it to H1 vs H2
  (native-Space input) with H1 favored.
- **Likely fix direction:** when placing a *brand-new* window, do not let an
  app-switch-induced `activeFocusRequest*` (or the native-Space input) override
  the live `interactionMonitorId` / confirmed focus when they disagree. Details
  in [Fix direction](#fix-direction-pending-step-1-confirmation).

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

## Fix direction (pending step 1 confirmation)

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

1. In the repro `create_placement_resolved` line for `897:2318`, which input
   equals the resolved `workspace=45A8DBE4`? (Decides H1 vs H2 vs H3.)
2. At snapshot time, was `activeFocusRequestWorkspaceId` non-nil, and did it
   equal `45A8DBE4`? (Confirms/refutes H1 directly.)
3. Was `focusedWorkspaceId` nil at snapshot time (as `#1` suggests)? (Confirms
   the "focused workspace" input was disabled.)
4. What set the pending managed focus request — which call site during
   `workspaceDidActivateApplication`? Trace through `handleAppActivation` and
   `beginManagedFocusRequest` to name it for the fix.
