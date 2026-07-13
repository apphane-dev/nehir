# Ghostty inactive-workspace sibling acquires active-monitor AX geometry during same-app activation

**Status:** open characterization / source-backed boundary failure. One inactive
Ghostty window's live AX frame intersected the active monitor while another
Nehir workspace was selected, and current `main` repaired the geometry during
the same capture. The capture does not prove WindowServer visibility or a
user-visible flash. The exact geometry writer that unparked it is also not
identified yet, so this is not implementation-ready.

Verified against `main` at `ed374cf0` on 2026-07-13. Source line numbers will
drift; function names are included so the paths remain findable.

All runtime evidence is inlined below. This document does not depend on a local
trace file.

## Verdict

There is one confirmed cross-workspace **AX geometry drift**. It is a plausible
visible leak, but the capture does not establish that WindowServer rendered the
window:

```text
workspaceInactiveVisibleDrift
  token=WindowToken(pid: 82494, windowId: 42790)
  workspace=CF0EF057-15BC-4431-A6D4-B1D931E55060
  interactionWorkspace=754003B5-57B3-439D-8463-4C11C1E8B25A
  hiddenReason=workspaceInactive side=right
  live=(740,7 1316x1251)
  expectedPark=(2056,7)
  dx=1315.5 dy=0.0
  lastApplied=nil
  replacement=(2055,71 1316x1251)
  activeMonitor=(0,0 2056x1329)
```

`82494:42790` still belonged to workspace 4 while workspace 1 was active. Its
managed state said `workspaceInactive`, but a direct live AX read put most of
the window's geometry on the only monitor. `observedVisible=false` means this
record alone cannot prove pixels were rendered. This was not a workspace
reassignment.

Current defensive repair worked: by capture end the same token was back at
`liveAXFrame={{2055.0,7.0},{1316.0,1251.0}}`,
`hidden=workspaceInactive`, `observedVisible=false`, and the final
workspace-inactive drift scan was `none`.

What remains open is the initial mutation from the park position to `x=740`.
The strongest clue is same-pid app activation/focus while another Ghostty
window was being selected on the active workspace. The capture does not prove
whether Ghostty/AppKit/WindowServer moved the sibling or whether an already
executing Nehir AX operation landed after suppression.

## Topology and window identities

Single display:

```text
ID(displayId: 1)
frame=(0.0,0.0,2056.0,1329.0)
visibleFrame=(0.0,0.0,2056.0,1290.0)
displaySpacesMode=enabled
focusFollowsMouse=false
```

Workspaces:

```text
workspace 1 id=754003B5-57B3-439D-8463-4C11C1E8B25A
workspace 4 id=CF0EF057-15BC-4431-A6D4-B1D931E55060
```

The same Ghostty process had a managed window on each workspace:

```text
WindowToken(pid: 82494, windowId: 47320)
  workspace=754003B5-57B3-439D-8463-4C11C1E8B25A
  title="herdr session attach ~"

WindowToken(pid: 82494, windowId: 42790)
  workspace=CF0EF057-15BC-4431-A6D4-B1D931E55060
  title="exedev@easysell: ~"
```

At capture start workspace 1 was active. `42790` was correctly parked:

```text
workspace=CF0EF057-15BC-4431-A6D4-B1D931E55060
hidden=workspaceInactive
layout=macosHiddenApp
liveAXFrame={{2055.0,7.0},{1316.0,1251.0}}
observedVisible=false
windowId=42790 lastApplied=nil pending=nil inactiveWorkspace=true
```

Both Ghostty entries carried `layout=macosHiddenApp` initially. By capture end
they were back to `layout=standard`. Refresh counters also changed from
`appHidden requested=16` / `appUnhidden requested=1` to `18` / `3` during the
capture. Those counters do not identify the pid, so they are only supporting
evidence that app hide/unhide churn was present, not proof that either event
moved `42790`.

## Runtime sequence

### 1. Workspace 4 becomes active and `42790` is manipulated normally

At `11:01:32Z`, focus moved from workspace 1 to workspace 4. The user then
performed several horizontal trackpad-touch gestures and selected `42790`.
Managed focus requests `243` through `247` targeted that window while its
workspace was active.

Near the end of those gestures, workspace 4 settled at an unusual far-right
viewport anchor:

```text
workspace=4
activeColumnIndex=0
currentViewStart=-1968.2
targetViewStart=-1968.2
w42790:selected{
  cur=1976,7,1316,1251,
  target=1976,7,1316,1251,
  live=1976,7,1316,1251,
  hidden:nil
}
```

This is a useful reproduction clue: the future drifted window was the selected
same-app window and had recently occupied a mostly right-edge frame before its
workspace became inactive.

### 2. macOS focuses the other Ghostty window on inactive workspace 1

At `11:01:37Z`, `focusedWindowChanged` resolved to `82494:47320` on workspace
1 while workspace 4 was still active. Nehir first deferred the event as a
possible same-app close successor, then allowed it after no close/overlay
evidence appeared:

```text
close_recovery_inactive_successor_deferred
  token=WindowToken(pid: 82494, windowId: 47320)
  samePidActiveFocusedToken=WindowToken(pid: 82494, windowId: 42790)
  recentSameAppClose=false
  recentNonManagedFocus=false

close_recovery_activation_gate
  token=WindowToken(pid: 82494, windowId: 47320)
  isWorkspaceActive=false
  source=focusedWindowChanged
  decision=allow reason=no_close_or_overlay_evidence

reveal_decision
  token=WindowToken(pid: 82494, windowId: 47320)
  target_ws=754003B5-57B3-439D-8463-4C11C1E8B25A
  is_ws_active=false
  should_activate=true
```

That switch is intentional current behavior: a genuine same-app focus change
to a window on another Nehir workspace follows the target. It is the behavior
shipped in
[`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md),
not itself the sibling-geometry drift.

After workspace 1 became active, `42790` was marked
`hidden=workspaceInactive` and returned to the right-edge park near `x=2055`.
Its workspace assignment remained workspace 4.

### 3. Another app is focused, then a workspace-1 gesture selects Ghostty again

At `11:01:39Z`, Helium pid `16913` became the focused application on workspace
1. At `11:01:42Z`, direct workspace-bar navigation focused Helium window
`16913:47603`.

At `11:01:43Z`–`11:01:44Z`, another horizontal trackpad-touch gesture moved
workspace 1 from column 0 toward column 1. The selected column contained the workspace-1 Ghostty
window `47320`. Gesture completion issued:

```text
pending_focus_started request=250
  token=WindowToken(pid: 82494, windowId: 47320)
  workspace=754003B5-57B3-439D-8463-4C11C1E8B25A
  reason=mouseScrollSelection

activation_source_observed pid=82494 source=workspaceDidActivateApplication
focus_confirmed token=WindowToken(pid: 82494, windowId: 47320)
  workspace=754003B5-57B3-439D-8463-4C11C1E8B25A
  source=workspaceDidActivateApplication
```

The active workspace spring was moving `47320` toward its final frame:

```text
currentViewStart=246.4 -> targetViewStart=655.1
w47320:selected{
  cur=790,7,1304,1251,
  target=382,7,1304,1251,
  live=752,7,1304,1251
}
```

### 4. The inactive sibling appears at `x=740`

During that same activation/scroll interval, the workspace-inactive drift check
read `42790` directly at `(740,7 1316x1251)`. Two independent state surfaces
disagreed:

- Direct AX read used by the drift detector: `live=(740,7 1316x1251)`.
- Workspace-4 Niri/debug cache in the same record:
  `w42790 ... live=2055,7,1316,1251`, `cur=target=1976`.

The direct `x=740` is close to the inlined active workspace-1 live frame for
`47320` (`x=752`) but `42790` retained its own width (`1316`, not `1304`). That
similarity is suggestive of same-app activation/restoration coupling, but it is
not enough to attribute the write.

### 5. Existing reconciliation re-parks the sibling

The event was emitted from `trigger=hideWorkspace.skipAlreadyHidden`. Current
`hideWorkspace` does not actually trust the old hidden state blindly anymore:
it first checks the live frame and calls `hideWindow(...
reason:.workspaceInactive)` when the live frame intersects an active monitor.
The trace line is emitted after that corrective call is scheduled, so it can
still contain the pre-repair live frame.

Capture-end state proves the correction completed:

```text
WindowToken(pid: 82494, windowId: 42790)
  workspace=CF0EF057-15BC-4431-A6D4-B1D931E55060
  phase=hidden
  hidden=workspaceInactive
  liveAXFrame={{2055.0,7.0},{1316.0,1251.0}}
  observedVisible=false

windowId=42790 lastApplied=nil pending=nil inactiveWorkspace=true
Workspace-Inactive Visible Drift Scan: none
```

## Source mapping

### Gesture completion deliberately fronts the newly selected window

`MouseEventHandler` synchronizes selection to the gesture's active column, then
calls `controller.focusWindow(... reason: .mouseScrollSelection)` when focus
follows mouse and non-managed focus do not suppress it
(`Sources/Nehir/Core/Controller/MouseEventHandler.swift:2178-2197`). This is the
source-backed arming condition for request `250`.

`WMController.focusWindow` creates a managed request, then routes through
`performWindowFronting` (`Sources/Nehir/Core/Controller/WMController.swift:4086-4131`).
`performWindowFronting` performs three operations in order
(`WMController.swift:4044-4053`):

```swift
windowFocusOperations.activateApp(pid)
windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
windowFocusOperations.raiseWindow(axRef.element)
```

The live `activateApp` implementation is app-wide:

```swift
NSRunningApplication(processIdentifier: pid)?.activate(options: [])
```

Only the following focus and raise calls are window-specific. Therefore a
normal workspace-1 gesture selection of `47320` necessarily activates the whole
Ghostty process before focusing that individual window. Nehir has no API that
can guarantee AppKit/Ghostty leaves the parked geometry of sibling `42790`
untouched during that app-wide activation.

### App hide/unhide state is also applied per pid

`ServiceLifecycleManager.setupAppHideObservers` forwards
`NSWorkspace.didHideApplicationNotification` and
`didUnhideApplicationNotification` by pid
(`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:493-523`).

`AXEventHandler.handleAppHidden` marks every managed entry for that pid
`.macosHiddenApp`; `handleAppUnhidden` restores every matching entry to
`.standard` and requests a refresh
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:4997-5053`).
`WindowModel.restoreFromNativeState` changes only `layoutReason`/parent-kind
state; it does not itself write a frame or clear workspace-inactive hidden state
(`Sources/Nehir/Core/Workspace/WindowModel.swift:720-741`).

This proves the same-pid coupling in Nehir's state machine, but not that the
unhide callback caused the physical `x=740` frame.

### The old Nehir-owned inactive layout-write leak is blocked

This capture does **not** have the signature of the fixed 2026-06-25 bug:

- drift recorded `lastApplied=nil`, not an active-monitor Nehir-applied target;
- the inactive workspace's cached layout still said `live=2055` while direct AX
  said `740`; and
- current source rebuilds inactive-window suppression before executing layout
  plans (`LayoutRefreshController.swift:476-499`).

Inside `LayoutDiffExecutor.execute`, ordinary frame updates are eligible for
`markWindowActive` / `unsuppressFrameWrites` only when the plan workspace is
active (`Sources/Nehir/Core/Controller/LayoutRefreshController.swift:4638-4669`).
An inactive workspace keeps those jobs classified inactive; the enqueue path
then records `skip-inactive` and refuses the frame
(`Sources/Nehir/Core/Ax/AXManager.swift:649-651`).

`hideInactiveWorkspaces` additionally rebuilds the inactive set and cancels
pending frame jobs before its hide loop
(`LayoutRefreshController.swift:2428-2478`). This makes an ordinary tracked
workspace-4 layout write an unlikely source of `x=740`.

This is strong negative evidence, not a proof of external authorship. A frame
job already executing on an app AX thread can land after cancellation; current
source explicitly documents that race and schedules delayed park reverification
for it (`LayoutRefreshController.swift:3044-3096`).

### Current repair is reactive, not preventive

For an entry whose model already says `workspaceInactive`, `hideWorkspace`
compares a direct live AX frame with the expected physical edge. If it intersects
any active monitor away from the expected park, it calls `hideWindow` again
before continuing (`LayoutRefreshController.swift:2604-2636`).

The detector intentionally scans every active monitor and uses direct AX geometry
rather than the Niri cache (`LayoutRefreshController.swift:2713-2786`). That is
why it observed `740` even though the workspace-4 cached layout still said
`2055`.

This is containment after visibility reconciliation. It does not prevent the
sibling from acquiring active-monitor geometry between the external/untracked
move and the next hide pass; whether that interval renders as a visible flash is
unconfirmed.

## Root-cause confidence

### Proven

1. `82494:42790` remained assigned to inactive workspace 4 while workspace 1 was
   active.
2. Its managed hidden state remained `workspaceInactive`.
3. A direct AX frame read put it at `x=740`, geometrically intersecting the sole
   monitor, while the cached layout still had `x=2055`.
4. The drift happened in the same interval as Nehir selected and app-activated
   same-pid workspace-1 window `82494:47320`.
5. Current reconciliation detected and repaired the drift.
6. No other inactive window has a recorded active-monitor AX drift event in this capture.

### Strongest hypothesis, not yet proven

App-wide Ghostty activation, app unhide/restoration, or Ghostty/AppKit's reaction
to window-specific focus/raise restored the parked sibling to a recent
active-monitor frame. This fits:

- same pid and two-workspace setup;
- `NSRunningApplication.activate` preceding the target-specific calls;
- initial `macosHiddenApp` state and hide/unhide churn during the capture;
- direct live AX changing without a matching `lastApplied` record; and
- the drifted x being close to the active sibling's current spring x.

### Alternative still possible

An already-running AX position write landed after inactive-job cancellation.
The source comments in `scheduleDelayedParkReverify` establish that this race is
possible. The capture lacks a writer sequence or target for `42790`, so it
cannot rule this out.

### Ruled out by this evidence

- **Workspace reassignment:** `42790` stayed in workspace 4 throughout.
- **Persistent failure of the current drift repair:** final live frame was
  parked and the final scan was clean.
- **The fixed ordinary inactive-plan frame-write path as the obvious writer:**
  no `lastApplied` target and current suppression logic contradict that shape.
- **Multiple confirmed drifting windows:** only `42790` crossed the detector.

## Reproduction clues

There is **no deterministic minimal repro yet**. The capture gives a useful
high-confidence sequence, but it does not prove every step is required.

### Closest sequence represented by the capture

1. On one display, create two normal tiled windows from the same app, preferably
   Ghostty, on two Nehir workspaces:
   - window A on workspace 1;
   - window B on workspace 4.
2. As an optional toggle, explicitly Hide and Unhide Ghostty with macOS (for
   example, Cmd-H followed by reactivation) so both entries pass through
   `macosHiddenApp`; leave another app available for an intervening focus
   switch. Ordinary deactivation does not set `macosHiddenApp`, and the capture
   does not prove this toggle is required.
3. Activate workspace 4 and use horizontal trackpad scrolling to select
   window B. In the observed run, B had recently settled mostly beyond the
   right edge (`currentViewStart=-1968.2`, B at `x=1976`, width `1316`).
4. Cause Ghostty to focus window A on workspace 1 without closing a window.
   Nehir should follow the genuine same-app focus to workspace 1.
5. Focus a different app on workspace 1 (Helium in the observed run).
6. Horizontally scroll workspace 1 with the trackpad until window A's column
   becomes selected. Gesture completion should issue
   `reason=mouseScrollSelection`, which calls
   app-wide Ghostty activation before focusing A.
7. During the activation/spring, watch window B from workspace 4. The failure
   condition is:

   ```text
   hidden=workspaceInactive
   workspace(B) != interactionWorkspace
   live AX frame intersects the active display away from x≈2055
   ```

8. Confirm whether the existing hide pass re-parks B automatically.

### Likely minimal trigger

The probable core is simpler than the full sequence:

> Reactivate/focus one window of an app on the active workspace while another
> window of the same pid is parked as `workspaceInactive` on another Nehir
> workspace.

The far-right prior viewport position, the explicit hide/unhide, and the
trackpad gesture may only increase the probability. Test them as independent
toggles rather than assuming all are required.

### Confidence by precondition

| Precondition | Confidence it matters | Evidence |
|---|---:|---|
| Same pid has windows on two Nehir workspaces | High | Both tokens are Ghostty pid `82494`; only inactive sibling `42790` drifted. |
| Active-workspace sibling is app-activated/focused | High | Request `250` and `workspaceDidActivateApplication` immediately precede the drift interval; source calls app-wide activate. |
| Inactive sibling already has `workspaceInactive` state | High | Explicit in the drift record and final state. |
| Intervening focus to another app | Medium | Helium was focused before Ghostty request `250`; this guarantees a real app activation rather than only same-app window focus. |
| Ghostty passes through `macosHiddenApp` | Medium/low | Present at capture start and app hide/unhide counters advanced, but events are not pid-correlated. |
| Inactive sibling was recently selected near the right edge | Medium/low | True in the captured sequence and supplies a recent active-monitor geometry, but causality is unproven. |
| Trackpad animation must be in flight | Medium/low | Drift coincided with a spring, but app activation can be generated by other focus commands too. |

## Evidence needed from the next reproduction

Do not plan a behavior change from this single capture. The next useful capture
must attribute the first `2055 -> active-monitor` AX mutation for the inactive
sibling. Add or obtain these checkpoints before implementing:

1. **Focus-fronting before/after snapshot.** Around `performWindowFronting`, record
   the target token and live AX frames of every managed same-pid sibling:
   before `activateApp`, after `activateApp`, after `focusSpecificWindow`, and
   after `raiseWindow`.
2. **Pid-correlated app lifecycle events.** Record `appHidden` / `appUnhidden`
   with pid, affected tokens, workspace ids, hidden states, and live frames
   before/after the refresh.
3. **Frame-writer provenance.** For `42790`, retain the latest requested target,
   backend (`AXManager`, SkyLight park, reveal, delayed reverify), sequence id,
   start/finish timestamps, and cancellation/suppression state even when
   `lastApplied` is later cleared.
4. **WindowServer frame observation.** Correlate the first CGS frame change for
   `42790` with the checkpoints above, including whether Nehir had any write in
   flight.
5. **Repair latency and visibility.** Record when the live frame first intersects
   an active monitor, whether WindowServer reports it visible, and when the
   corrective park is observed, so a user-visible flash can be confirmed and
   quantified rather than inferred.

Interpretation:

- Frame changes immediately after `activateApp`, before any Nehir window-specific
  call: app/AppKit/WindowServer activation side effect.
- Frame changes after `focusSpecificWindow` or `raiseWindow`, with no Nehir frame
  target for `42790`: Ghostty/AX focus side effect.
- A Nehir target for `42790` starts before suppression and finishes after the
  workspace switch: stale in-flight frame job.
- No sibling movement on repeated runs: the current sequence is probabilistic;
  vary only the medium/low-confidence toggles above.

## Relationship to prior work

- [`../completed/20260625-inactive-workspace-frame-writes-leak.md`](../completed/20260625-inactive-workspace-frame-writes-leak.md)
  fixed the Nehir-owned ordinary inactive-plan frame-write leak and added the
  live-frame drift repair exercised here. This capture is a residual transient
  with a different signature (`lastApplied=nil`, cached `live=2055`). Do not
  reopen that completed root unless writer provenance shows an inactive layout
  frame actually escaped suppression.
- [`20260616-workspace-inactive-stale-live-frame.md`](20260616-workspace-inactive-stale-live-frame.md)
  documents the older stale-hidden metadata family and now records its resolved
  state. The new finding proves that external/unattributed geometry can still
  violate the same invariant temporarily even though reconciliation now
  self-heals it.
- [`../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md`](../completed/20260706-same-app-focus-switch-reveals-inactive-workspace-window.md)
  intentionally follows genuine same-app focus to another workspace. Preserve
  that policy; the bug here is the non-target sibling acquiring active-monitor
  AX geometry, not the target workspace switch.
- [`20260708-cluster-specific-tracing-improvements.md`](20260708-cluster-specific-tracing-improvements.md)
  provides the common observability direction. This finding adds a concrete
  geometry-provenance need: decision -> focus/fronting action -> per-sibling
  observed frame result.

## Next action

Attempt the reproduction matrix above with the four fronting checkpoints before
writing a fix plan. If `activateApp` or target-specific focus reliably moves the
inactive sibling, plan prevention or immediate post-fronting re-park around that
boundary. If a stale Nehir write is identified instead, fix its sequencing /
cancellation owner. If neither reproduces, retain the current defensive repair
and treat writer-provenance tracing as the only justified change.
