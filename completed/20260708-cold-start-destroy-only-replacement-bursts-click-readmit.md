# Cold start destroy-only replacement bursts remove live windows; clicked pids are the only durable readmission

**Status:** completed — fix shipped on `main` as `a55b4e33` ("Keep live windows through CGS space churn"). The CGS `spaceWindowDestroyed` path now carries a `spaceId`, runs liveness verification, and confirms AX membership before removing a live window. A secondary parked-hidden-window placement fix also landed. Moved from `discovery/` to `completed/` on 2026-07-08. Regression tests were intentionally not added pending user repro confirmation per the runtime-debug workflow; the implemented guard path is observable through the new `destroy_liveness_decision` / `destroy_liveness_verification` trace events.

Discovery 2026-07-08, verified against `main` at `d4cc52`. Implementation verified against `main` at `a55b4e33` on 2026-07-08. Line numbers will drift; function names are included so the source citations remain findable.

Cross-link cluster: [`LC-1` in `20260708-cross-discovery-relevance-clusters.md`](../discovery/20260708-cross-discovery-relevance-clusters.md#lc-1--lifecycleadmission-desync-false-removals-partial-enumeration-and-replacement-bursts). This is the latest cold-start lifecycle/admission-desync capture and should be read with [`20260707-cold-start-wipe-recurs-post-liveness-fix-only-focused-pid-readmitted.md`](20260707-cold-start-wipe-recurs-post-liveness-fix-only-focused-pid-readmitted.md) and [`20260707-external-display-column-admission-click-required.md`](20260707-external-display-column-admission-click-required.md).

## Follow-up: clean cold start makes the failure worse, but confirms the same mechanism

A later clean cold-start capture on `nehir v8a25e7*` reproduced the same fault with higher blast radius. It did **not** simply leave two windows unmanaged. It initially enumerated nine visible windows, then destroy-only replacement bursts collapsed the model and the layout was rebuilt piecemeal only as pids received focus or pid reevaluation. At the end, eight windows were managed, six were hidden/parked, two were visible, and Ghostty `W(82494/27176)` was still a visible unmanaged WindowServer window.

Initial topology matched the earlier capture: built-in Retina `displayId=1` at `(0, 0, 2056, 1329)` and DELL P2423D `displayId=2` at `(-312, 1329, 2560, 1440)`. Nehir started with `windows total=0`, but WindowServer/AX exposed these visible normal windows on the external-display coordinate band:

```text
Claude       W(46598/27069) frame={{0, -1410}, {600, 1410}}     axWindowsCount=1 axContainsWindow=true
Code         W(53999/25718) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=2 axContainsWindow=true
Helium       W(28651/26466) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
Helium       W(28651/24872) frame={{442, -1410}, {743, 1410}}   axWindowsCount=4 axContainsWindow=true
Helium       W(28651/26317) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
Slack        W(51532/24203) frame={{0, -1410}, {900, 1410}}     axWindowsCount=1 axContainsWindow=true
Helium       W(28651/22680) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
Ghostty      W(82494/27176) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=1 axContainsWindow=true
Code         W(53999/23432) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=2 axContainsWindow=true
```

AX enumeration was complete for those pids at startup:

```text
14:01:52 ax_windows_query pid=46598 newContext=true count=1 windowIds=[27069]
14:01:52 ax_windows_query pid=51532 newContext=true count=1 windowIds=[24203]
14:01:52 ax_windows_query pid=82494 newContext=true count=1 windowIds=[27176]
14:01:52 ax_windows_query pid=53999 newContext=true count=2 windowIds=[25718, 23432]
14:01:52 ax_windows_query pid=28651 newContext=true count=4 windowIds=[26466, 24872, 22680, 26317]
```

The first Niri insertion batch placed eight non-Ghostty windows into workspace `EDADB791-6F3A-48C0-9D28-8D7F6C77239A` from an empty workspace:

```text
14:01:52 W(51532/24203) beforeColumns=0 landedColumn=0
14:01:52 W(46598/27069) beforeColumns=0 landedColumn=7
14:01:52 W(53999/25718) beforeColumns=0 landedColumn=6
14:01:52 W(53999/23432) beforeColumns=0 landedColumn=5
14:01:52 W(28651/26466) beforeColumns=0 landedColumn=4
14:01:52 W(28651/24872) beforeColumns=0 landedColumn=3
14:01:52 W(28651/22680) beforeColumns=0 landedColumn=2
14:01:52 W(28651/26317) beforeColumns=0 landedColumn=1
```

Immediately after that, the model was effectively reset. Claude was inserted again one second later with `beforeColumns=0`, proving the previous column set had been removed:

```text
14:01:53 W(46598/27069) beforeColumns=0 landedColumn=0
14:01:59 W(28651/26317) beforeColumns=1 landedColumn=1
14:01:59 W(28651/24872) beforeColumns=2 landedColumn=4
14:01:59 W(28651/26317) beforeColumns=2 landedColumn=2
14:01:59 W(28651/26466) beforeColumns=2 landedColumn=3
14:02:03 W(51532/24203) beforeColumns=5 landedColumn=1
14:02:20 W(53999/25718) beforeColumns=6 landedColumn=1
14:02:20 W(53999/23432) beforeColumns=7 landedColumn=2
```

The managed-replacement trace names the destructive mechanism: all affected bursts were destroy-only (`creates=0`) and replayed as `reason=no_match`:

```text
pid=53999 key=(53999,EDADB791...) creates=0 destroys=2 matched=false rekeyed=false replayed=2
  replay.destroy W(53999/25718)
  replay.destroy W(53999/23432)
pid=28651 key=(28651,EDADB791...) creates=0 destroys=3 matched=false rekeyed=false replayed=3
  replay.destroy W(28651/26466)
  replay.destroy W(28651/22680)
  replay.destroy W(28651/26317)
pid=28651 key=(28651,EDADB791...) creates=0 destroys=1 matched=false rekeyed=false replayed=1
  replay.destroy W(28651/24872)
pid=51532 key=(51532,EDADB791...) creates=0 destroys=1 matched=false rekeyed=false replayed=1
  replay.destroy W(51532/24203)
pid=46598 key=(46598,EDADB791...) creates=0 destroys=1 matched=false rekeyed=false replayed=1
  replay.destroy W(46598/27069)
pid=82494 key=(82494,3095283B...) creates=0 destroys=1 matched=false rekeyed=false replayed=1
  replay.destroy W(82494/27176)
```

The Ghostty destroy was especially damaging because it was keyed to inactive workspace `3095283B-1742-4563-93FB-EE0E31823F1B`; unlike the active workspace pids, it never received a focus/pid recovery path and ended the capture unmanaged:

```text
Visible Unmanaged WindowServer Windows at end:
  Ghostty W(82494/27176) frame={{2055, 39}, {1011, 1251}} axWindowsCount=1 axContainsWindow=true
```

AX still does not explain the destroys. The raw AX notification ring contained only focused-window changes — seventeen entries such as `AXFocusedWindowChanged pid=28651 window=nil` and `AXFocusedWindowChanged pid=53999 window=nil` — and no `AXUIElementDestroyed` notifications.

End state was internally inconsistent even for recovered pids:

```text
windows total=8 tiled=8 floating=0 hidden=6
visible columns: W(53999/23432), W(51532/24203)
hidden parked:  W(28651/22680), W(28651/24872), W(28651/26317), W(28651/26466), W(46598/27069), W(53999/25718)
visible unmanaged: W(82494/27176)
```

This follow-up strengthens the original hypothesis: complete AX enumeration and initial layout insertion happen first; then CGS/space-lifecycle feedback produces destroy-only replacement bursts; later focus/reevaluation partially rebuilds the active workspace, but inactive or unclicked pids can remain unmanaged.

## Summary

A cold-start capture on `nehir vd4cc52` shows eight visible normal app windows. They were all seen by AX and initially inserted into the Niri column layout, but a burst of destroy-only managed-replacement events immediately removed the live windows. Some pids were later recovered by incidental pid/focus reevaluation, but two user-facing windows — Telegram `W(7665/23117)` and Claude `W(20217/23233)` — only re-entered the layout after explicit native app activation (`workspaceDidActivateApplication`), matching the observed workaround: click the missing window and it becomes a column.

This is **not** the old full-rescan under-enumeration shape. AX returned all initial windows for the relevant pids, and the Niri insertion trace shows all eight tokens were seated at cold start. The failure happens after admission: a false destroy path tears down live entries, then focused admission is the recovery path for clicked pids.

## Captured topology and initial state

Two displays were present:

- Built-in Retina Display: `displayId=1`, `frame=(0, 0, 2056, 1329)`, `visibleFrame=(0, 0, 2056, 1290)`.
- DELL P2423D: `displayId=2`, `frame=(-312, 1329, 2560, 1440)`, `visibleFrame=(-312, 1329, 2560, 1410)`.

At capture start, Nehir had no managed windows, but WindowServer/AX exposed eight visible normal app windows, all physically on the DELL-space coordinate band (`y=-1410..0`) and AX-owned:

```text
Telegram     W(7665/23117)  frame={{899, -1410}, {470, 1410}}   axWindowsCount=1 axContainsWindow=true
Helium       W(28651/22680) frame={{109, -1410}, {1801, 1251}}  axWindowsCount=1 axContainsWindow=true
Ghostty      W(82494/22015) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=2 axContainsWindow=true
Code         W(53999/23432) frame={{87, -1410}, {1819, 1410}}   axWindowsCount=4 axContainsWindow=true
Code         W(53999/23435) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
Code         W(53999/23434) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
Claude       W(20217/23233) frame={{0, -1410}, {900, 1410}}     axWindowsCount=1 axContainsWindow=true
Code         W(53999/23433) frame={{899, -1410}, {1011, 1251}}  axWindowsCount=4 axContainsWindow=true
```

The AX windows query trace confirms the initial enumeration returned these windows:

```text
23:54:03 ax_windows_query pid=20217 newContext=true count=1 windowIds=[23233]
23:54:03 ax_windows_query pid=82494 newContext=true count=2 windowIds=[5915, 22015]
23:54:03 ax_windows_query pid=28651 newContext=true count=1 windowIds=[22680]
23:54:03 ax_windows_query pid=7665  newContext=true count=1 windowIds=[23117]
23:54:03 ax_windows_query pid=53999 newContext=true count=4 windowIds=[23432, 23435, 23434, 23433]
```

The Niri insertion trace also seated all eight tokens in the same cold-start workspace `41E56E87-0231-413E-8E33-74088656AF2C` before the wipe:

```text
23:54:03 token=W(20217/23233) beforeColumns=8 landedColumn=2
23:54:03 token=W(28651/22680) beforeColumns=8 landedColumn=0
23:54:03 token=W(7665/23117)  beforeColumns=8 landedColumn=1
23:54:03 token=W(82494/22015) beforeColumns=8 landedColumn=7
23:54:03 token=W(53999/23432) beforeColumns=8 landedColumn=3
23:54:03 token=W(53999/23435) beforeColumns=8 landedColumn=6
23:54:03 token=W(53999/23434) beforeColumns=8 landedColumn=5
23:54:03 token=W(53999/23433) beforeColumns=8 landedColumn=4
```

## Failure sequence

### 1. All eight live windows were removed as destroyed

Within the first second, the event stream first admitted the windows, then removed every one:

```text
#27 23:54:04 window_admitted W(7665/23117)  context=pid_reevaluation
#29 23:54:04 window_admitted W(20217/23233) context=pid_reevaluation
#31 23:54:04 window_admitted W(28651/22680) context=pid_reevaluation
#33 23:54:04 window_admitted W(53999/23432) context=pid_reevaluation
#35 23:54:04 window_admitted W(53999/23433) context=pid_reevaluation
#37 23:54:04 window_admitted W(53999/23434) context=pid_reevaluation
#39 23:54:04 window_admitted W(53999/23435) context=pid_reevaluation
#41 23:54:04 window_admitted W(82494/22015) context=pid_reevaluation

#44 23:54:04 window_removed W(82494/22015) phase=destroyed
#46 23:54:04 window_removed W(53999/23435) phase=destroyed
#48 23:54:04 window_removed W(53999/23434) phase=destroyed
#50 23:54:04 window_removed W(53999/23433) phase=destroyed
#52 23:54:04 window_removed W(7665/23117)  phase=destroyed
#55 23:54:04 window_removed W(28651/22680) phase=destroyed
#57 23:54:04 window_removed W(20217/23233) phase=destroyed
#69 23:54:04 window_removed W(53999/23432) phase=destroyed
```

The removals interleaved with `managed_focus_cancelled` and `focus_lease_changed owner=window_close_focus_recovery`, the same `handleRemoved(token:)` fingerprint as the earlier cold-start wipe captures.

### 2. The replacement trace shows destroy-only bursts, not create/rekey pairs

The managed-replacement trace is more explicit than earlier captures. Each affected pid received a structural replacement burst with `creates=0`, then the flush found no match and replayed destroys:

```text
enqueueManagedReplacementDestroy pid=7665  token=W(7665/23117)  creates=0 destroys=1 policy=structural
flushManagedReplacementBurst pid=7665  creates=0 destroys=1 matched=false rekeyed=false replayed=1
replayManagedReplacementEvents.destroy pid=7665 token=W(7665/23117)

enqueueManagedReplacementDestroy pid=20217 token=W(20217/23233) creates=0 destroys=1 policy=structural
flushManagedReplacementBurst pid=20217 creates=0 destroys=1 matched=false rekeyed=false replayed=1
replayManagedReplacementEvents.destroy pid=20217 token=W(20217/23233)

enqueueManagedReplacementDestroy pid=28651 token=W(28651/22680) creates=0 destroys=1 policy=structural
flushManagedReplacementBurst pid=28651 creates=0 destroys=1 matched=false rekeyed=false replayed=1
replayManagedReplacementEvents.destroy pid=28651 token=W(28651/22680)
```

For Code, the first burst removed three sibling windows (`23435`, `23434`, `23433`) with `creates=0 destroys=3`, and a later burst removed `23432` with `creates=0 destroys=1`.

### 3. AX destroy notifications are excluded for the destructive phase

The raw AX notification dump contains only focused-window changes, and no `AXUIElementDestroyed` / miniaturized notifications:

```text
23:54:04 ax=AXFocusedWindowChanged pid=53999 window=nil
23:54:04 ax=AXFocusedWindowChanged pid=53999 window=nil
23:54:04 ax=AXFocusedWindowChanged pid=53999 window=nil
23:54:05 ax=AXFocusedWindowChanged pid=82494 window=nil
23:54:08 ax=AXFocusedWindowChanged pid=82494 window=nil
23:54:08 ax=AXFocusedWindowChanged pid=82494 window=nil
23:54:09 ax=AXFocusedWindowChanged pid=82494 window=nil
23:54:13 ax=AXFocusedWindowChanged pid=82494 window=nil
```

The ring is not full, so the absence is meaningful for this capture. The windows were subscribed during `getWindowsAsync` because each initial per-pid AX query succeeded; if AX had delivered a destroy notification for these subscribed windows, the always-on raw ring would have recorded it.

### 4. Two windows only came back after native app activation / click

Telegram did not re-enter the layout until the user activated it:

```text
#154 23:54:19 focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
#155 23:54:19 window_admitted W(7665/23117) context=focused_admission
#159 23:54:19 window_admitted W(7665/23117) context=pid_reevaluation

activation_source_observed pid=7665 source=workspaceDidActivateApplication
window_decision W(7665/23117) context=focused_admission existingMode=nil outcome=trackedTiling
create_placement_resolved W(7665/23117) context_source=ax_focused_admission_synthesized
focused_admission_guard W(7665/23117) outcome=trackPreparedCreate reason=direct_focused_admission suppressedByUnrequestedGuard=false
track_prepared_create W(7665/23117) admissionContext=focusedAdmission mode=tiling
```

Claude behaved the same way two seconds later:

```text
#218 23:54:21 focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
#219 23:54:21 window_admitted W(20217/23233) context=focused_admission
#225 23:54:21 window_admitted W(20217/23233) context=pid_reevaluation

activation_source_observed pid=20217 source=workspaceDidActivateApplication
window_decision W(20217/23233) context=focused_admission existingMode=nil outcome=trackedTiling
create_placement_resolved W(20217/23233) context_source=ax_focused_admission_synthesized
focused_admission_guard W(20217/23233) outcome=trackPreparedCreate reason=direct_focused_admission
track_prepared_create W(20217/23233) admissionContext=focusedAdmission mode=tiling
```

At capture end, those two clicked pids were managed again, but Helium `W(28651/22680)` was still a visible unmanaged WindowServer window with `axContainsWindow=true`:

```text
Managed total=7 tiled=7 hidden=6
Visible Unmanaged WindowServer Windows:
  Helium W(28651/22680) frame={{-1010, 83}, {1011, 1251}} axWindowsCount=1 axContainsWindow=true
```

So the recovery is not a general repair pass. It is pid/window-focus driven: clicked pids recover, unclicked pids can remain outside the model.

## Source-backed analysis

### CGS space-destroy is still treated as unverified window death

`CGSEventObserver` decodes `spaceWindowDestroyed` as `.destroyed(windowId, spaceId)` (`Sources/Nehir/Core/SkyLight/CGSEventObserver.swift:321-327`). `AXEventHandler.cgsEventObserver(_:didReceive:)` then throws away the `spaceId` and routes both `.destroyed` and `.closed` to `handleCGSWindowDestroyed` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:862-868`).

`handleCGSWindowDestroyed` calls `handleWindowDestroyed(..., verifyWindowServerLiveness: false)` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1471-1476`). That bypasses the liveness gate that the AX callback uses (`handleRemoved(pid:winId:)` passes `verifyWindowServerLiveness: true` at `Sources/Nehir/Core/Controller/AXEventHandler.swift:1902-1907`).

Inside `handleWindowDestroyed`, the WindowServer liveness check only runs when `verifyWindowServerLiveness` is true (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4838-4848`). With the CGS flag set to false, a prepared destroy can proceed into `enqueueManagedReplacementDestroy` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4852-4862`).

That source shape matches the capture:

- no AX destroyed notifications;
- destroy-only managed-replacement bursts;
- removals labeled `phase=destroyed` even though the same windows were still AX/WindowServer-live.

### Destroy-only replacement bursts eventually call `handleRemoved(token:)`

`enqueueManagedReplacementDestroy` appends destroy events to a `(pid, workspaceId)` burst and schedules a flush (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4952-4994`). `flushManagedReplacementBurst` only completes a rekey if it finds a create/destroy pair; otherwise it records `matched=false` and replays the ordered events with reason `no_match` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5885-5950`).

The replay path records the create/destroy counts before processing (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5033-5053`). In this capture the counts are `creates=0`, so there is nothing to rekey; the replay is pure destroy. A replayed destroy reaches `processPreparedDestroy`, whose only body is `handleRemoved(token:)` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:4885-4887`). `handleRemoved(token:)` removes the entry from `WorkspaceManager`, requests a window-removal refresh, and only then schedules pid rule reevaluation (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1997-2010`).

This explains why a live window can be ejected from the layout and then require a later incidental pid/focus event to return.

### Focused admission is the click recovery path

`NSWorkspace.didActivateApplicationNotification` is routed to `handleAppActivation(..., source: .workspaceDidActivateApplication)` (`Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:344-357`). The focused-admission path synthesizes a create placement context, prepares a create candidate, and on the direct path calls `trackPreparedCreate(candidate, admissionContext: .focusedAdmission)` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3375-3467`).

`WindowAdmissionContext.focusedAdmission` is explicitly documented as the case where the window took AX focus before Nehir otherwise knew about it (`Sources/Nehir/Core/Reconcile/WMEvent.swift:35-37`). The Telegram and Claude readmissions are exactly this context, followed by pid reevaluation.

### AX enumeration was not the first failure

`AXManager.rawWindowEnumerationForApp` returns the windows from `AppAXContext.getWindowsAsync()` and can record count mismatches when AX returns fewer windows than WindowServer sees (`Sources/Nehir/Core/Ax/AXManager.swift:435-457`). This capture has no `ax_window_count_mismatch` or `full_rescan_omission` evidence for the affected normal windows. Instead, the successful initial AX queries and insertion trace show the windows were known before the false destroys.

## Hypothesis

Cold-start admission relocates/restores windows that are physically on the external display's space while the interaction workspace is on the built-in display. WindowServer emits `spaceWindowDestroyed` for the old space membership as those windows leave their original space. Nehir treats those CGS `.destroyed` events as unverified window death, enqueues structural replacement destroys, finds no matching creates, and replays the destroys into `handleRemoved(token:)`.

After that, only paths that re-query or focus a pid can recover it. Code and Ghostty happened to receive incidental reevaluations/focus events. Telegram and Claude did not recover until explicit app activation, and Helium remained unmanaged at the end.

## Fix direction (original)

- Do not treat CGS `spaceWindowDestroyed` as window death without a liveness oracle. Reuse or mirror the AX destroy liveness gate for CGS destroy events.
- Preserve and inspect the `spaceId` from `spaceWindowDestroyed`; a window leaving one space during Nehir-driven startup relocation should be modeled as a space-membership change, not a close.
- For destroy-only managed-replacement bursts (`creates=0`, live WindowServer/AX still resolves the token), defer or cancel the replay instead of handing it to `handleRemoved(token:)`.
- Add a bounded post-removal re-enumeration retry for alive pids so recovery is not dependent on the user clicking the missing window.

No tests were changed for this discovery. Per runtime-debug workflow, add regression coverage only after a candidate fix is validated in the real repro.

## Final implementation (shipped `a55b4e33`)

The landed fix addresses the first two fix directions directly: it splits the CGS destroy origin, threads the `spaceId` through, and runs liveness verification on the space-destroy path. The third and fourth directions (cancel destroy-only bursts / bounded post-removal retry) were not needed once the upstream gate stopped producing false removes.

### CGS space-destroy now carries its own origin and verifies liveness

`cgsEventObserver(_:didReceive:)` no longer routes `.destroyed` and `.closed` through one handler. It branches on `spaceId`: `spaceId == 0` is treated as a real close (`handleCGSWindowClosed`), any nonzero `spaceId` is a space-membership removal (`handleCGSSpaceWindowDestroyed`, which now receives the `spaceId`) (`Sources/Nehir/Core/Controller/AXEventHandler.swift:958-967`).

A new `WindowDestroyOrigin` enum (`axDestroyed`, `cgsSpaceDestroyed(spaceId:)`, `cgsWindowClosed`) tags every destroy path (`Sources/Nehir/Core/Controller/AXEventHandler.swift:37-66`). `handleWindowDestroyed` now takes an `origin` parameter, so every decision point knows whether the trigger was an AX destroy, a CGS space-destroy, or a CGS window-close (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5071-5076`).

The decisive change: `handleCGSSpaceWindowDestroyed` calls `handleWindowDestroyed(..., verifyWindowServerLiveness: true, origin: .cgsSpaceDestroyed(spaceId:))` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1604-1612`). Previously the CGS path hard-coded `verifyWindowServerLiveness: false`, which is exactly what bypassed the liveness gate and allowed the cold-start false wipe. `handleCGSWindowClosed` keeps the old unverified behavior (`origin: .cgsWindowClosed`) because a real close is not the cold-start failure mode.

### Liveness verification confirms AX before removing a space-churned window

`handleWindowDestroyed` now has two liveness deferral branches. When the WindowServer still reports the window's pid, it defers to `scheduleDestroyLivenessVerification` as before (`reason=window_server_alive`) (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5135-5152`). For CGS space-destroys specifically, when the WindowServer no longer resolves the window at all (`windowServerPid == nil`), it still defers rather than removing, because a space-destroy can briefly make the window invisible to `resolveWindowInfo` during the space transition (`reason=window_server_unresolved`, gated on `origin.requiresAXConfirmationWhenWindowServerMissing`) (`Sources/Nehir/Core/Controller/AXEventHandler.swift:5156-5177`).

`scheduleDestroyLivenessVerification` gained a `confirmAXWhenWindowServerMissing` flag (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1918-1921`). When set (true for CGS space-destroys), the deferred task queries AX even when the WindowServer oracle is missing, and keeps the token if AX still enumerates it (`outcome=keep, reason=ax_contains_token`) (`Sources/Nehir/Core/Controller/AXEventHandler.swift:1939-1990`). A real AX-missing result still removes (`outcome=remove, reason=ax_missing_token` / `window_server_missing`). This closes the nil-oracle branch that previously fell through to immediate removal.

### New trace points make the guard observable

Two trace events were added so future captures can distinguish keep vs remove decisions without inference: `destroy_liveness_decision` (origin, spaceId, verify flag, WindowServer pid, outcome, reason) at the synchronous decision point, and `destroy_liveness_verification` (origin, WindowServer alive, AX enumeration result, outcome, reason) at the deferred re-check (`Sources/Nehir/Core/Controller/AXEventHandler.swift:215-229`, `:419-433`, `:1415-1449`). This directly answers the observability gap flagged in the cold-start-wipe-recurs discovery.

### Secondary: parked hidden windows no longer leak onto adjacent displays

The changeset also fixed `HiddenWindowPlacementResolver` so hidden/parked windows do not bleed onto a neighbor monitor. The parking origin search now iterates orthogonal candidates for both horizontal and vertical orientations (previously it only tried the requested edge and its opposite, and only generated vertical candidates for horizontal layouts), and picks the placement with the least cross-monitor overlap, breaking ties by proximity then edge preference (`Sources/Nehir/Core/Layout/SideHiding.swift:184-258`, `:280-315`). This addresses the parked-Helium-on-wrong-display symptom seen in the captures.

### Changeset

`.changeset/20260708171704-fix-cold-start-cgs-space-destroy-events-removing.md` — `nehir: patch` — "Fix cold-start CGS space-destroy events removing live windows and avoid parked hidden windows leaking onto adjacent displays."

### Validation

The worker ran `mise run format:check` (passed), `swift test --filter AXEventHandlerTests` (177 tests passed), and `mise run test` (1432 tests passed) on the worktree. No tests were added or modified, per the runtime-debug workflow. The fix awaits user repro confirmation before regression coverage is added.
