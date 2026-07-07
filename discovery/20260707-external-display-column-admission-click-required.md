# External display moves require click before column admission

## Summary

A runtime capture shows the external-display move path can leave windows in a managed-replacement / metadata churn state instead of admitting them through the normal column-layout path. The windows eventually become tiled on the external display, but the only explicit `window_admitted` events during the active problem window occur immediately after a `workspaceDidActivateApplication` native app switch, matching the observed workaround: manually clicking a window gets it accepted into the column layout.

The likely fault line is the managed-replacement deferral path: structurally anchored replacement candidates are delayed into a `(pid, workspaceId)` burst for 150 ms, while focus-driven admission is allowed to synthesize a focused create context and call `trackPreparedCreate(..., admissionContext: .focusedAdmission)` once the user clicks the window.

Related high-confidence clusters: [`LC-1`](20260708-cross-discovery-relevance-clusters.md#lc-1--lifecycleadmission-desync-false-removals-partial-enumeration-and-replacement-bursts) for replacement/admission desync and [`XD-1`](20260708-cross-discovery-relevance-clusters.md#xd-1--cross-display-moves-reveal-at-the-wrong-time-size-or-workspace-identity) for display/workspace transition ordering.

## Captured topology and starting state

The capture started with two displays:

- Built-in Retina Display: `displayId=1`, `frame=(0.0, 0.0, 2056.0, 1329.0)`, `visibleFrame=(0.0, 0.0, 2056.0, 1290.0)`.
- DELL P2423D external display: `displayId=2`, `frame=(-222.0, 1329.0, 2560.0, 1440.0)`, `visibleFrame=(-222.0, 1329.0, 2560.0, 1410.0)`.

At capture start Nehir had no managed windows:

```text
WorkspaceManager: monitors=2 workspaces=7 visibleWorkspaces=2
windows total=0 tiled=0 floating=0 hidden=0
interaction current=ID(displayId: 1) previous=nil
```

But WindowServer already exposed five normal application windows as visible unmanaged windows:

```text
Helium windowId=10428 frame={{-1010.0, 71.0}, {1011.0, 1251.0}}
Agterm windowId=14885 frame={{-971.0, 71.0}, {972.0, 1251.0}}
Code - Insiders windowId=1573 frame={{2055.0, 71.0}, {1011.0, 1251.0}}
Telegram windowId=351 frame={{1031.0, 71.0}, {1011.0, 1251.0}}
Helium windowId=215 frame={{14.0, 71.0}, {1011.0, 1251.0}}
```

## What happened

### 1. Windows were physically placed on the external display before admission fully settled

During the move, external workspace `8EB5A181-D937-4AFF-8F07-9506630B56E1` acquired columns whose live frames were on `displayId=2` (`y≈1336`, inside the DELL visible frame):

```text
workspace=6 id=8EB5A181-D937-4AFF-8F07-9506630B56E1 reason=window_removal_seed_check
columns=3 activeColumnIndex=2
c0 w215 cur=-208,1336,840,1371 target=-208,1336,840,1371 replacement=295,-1374,1526,1371
c1 w14885 cur=638,1336,840,1371 target=638,1336,840,1371 replacement=1141,-1372,840,1371
c2 w351 selected cur=1484,1336,840,1371 target=1484,1336,840,1371 replacement=nil
```

The live/target frames are on the external display, but replacement metadata for `w215` and `w14885` still contains stale/offscreen coordinates (`y=-1374`, `y=-1372`). This is the first sign that the physical frame move and the managed replacement/admission state are diverging.

### 2. The event stream was dominated by replacement metadata churn, not admissions

In the captured event stream, event counts were:

```text
211 managed_replacement_metadata_changed
 19 managed_focus_confirmed
 13 managed_focus_requested
  9 hidden_state_changed
  2 window_admitted
  2 focus_lease_changed
```

The replacement churn repeatedly stated the desired end state for the external workspace but did not correspond to admission events:

```text
event=managed_replacement_metadata_changed token=WindowToken(pid: 67387, windowId: 14885)
workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 monitor=displayId:2
plan=desired=workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1,mode=tiling
```

The same churn repeated for `WindowToken(pid: 28651, windowId: 215)`. While this was happening, those windows also bounced through hidden/offscreen state:

```text
w215 hidden=true  plan=phase=offscreen
w215 hidden=true  plan=phase=offscreen
w215 hidden=false plan=phase=tiled
...
w14885 hidden=true  plan=phase=offscreen
w14885 hidden=true  plan=phase=offscreen
w14885 hidden=false plan=phase=tiled
```

### 3. The only explicit admissions happened immediately after manual/native focus

The decisive transition is a native app switch:

```text
event=focus_lease_changed owner=native_app_switch reason=workspaceDidActivateApplication
interaction=ID(displayId: 2)/prev=ID(displayId: 1)
plan=focus=focused=WindowToken(pid: 28651, windowId: 215),pending=nil,lease=native_app_switch
```

Immediately after that, Telegram (`WindowToken(pid: 55316, windowId: 351)`) was admitted twice by focus-related paths:

```text
event=window_admitted token=WindowToken(pid: 55316, windowId: 351)
workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 mode=tiling context=focused_admission
plan=phase=tiled desired=workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1,mode=tiling

event=window_admitted token=WindowToken(pid: 55316, windowId: 351)
workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 mode=tiling context=pid_reevaluation
plan=phase=tiled desired=workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1,mode=tiling
```

This matches the user-visible behavior: clicking/focusing the window supplied the missing signal that got the window accepted into the external display's column layout.

### 4. End state confirms delayed partial recovery, plus one hidden leftover

At capture end, the external workspace had three tiled visible windows on `displayId=2`:

```text
w215   workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 phase=tiled liveAXFrame={{-208.0, 1336.0}, {840.0, 1371.0}}
w351   workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 phase=tiled liveAXFrame={{638.0, 1336.0}, {840.0, 1371.0}}
w14885 workspace=8EB5A181-D937-4AFF-8F07-9506630B56E1 phase=tiled liveAXFrame={{1484.0, 1336.0}, {840.0, 1371.0}}
```

However, VS Code Insiders remained hidden in another workspace on the external display:

```text
w1573 workspace=5F4EDAD1-D277-49C6-B86B-EA95ABAE66E1 phase=hidden hidden=workspaceInactive
liveAXFrame={{2337.0, 1329.0}, {1011.0, 1251.0}}
replacementFrame={{2337.0, -1251.0}, {1011.0, 1251.0}}
```

That is consistent with the same failure mode: windows can land physically on the external display but not be cleanly admitted into the intended visible column layout unless another admission trigger occurs.

## Source-backed analysis

### Replacement metadata changes are reconcile events, not admissions

`WorkspaceManager.setManagedReplacementMetadata` records `.managedReplacementMetadataChanged` whenever replacement metadata changes for an existing entry. Frame updates go through `updateManagedReplacementFrame`, which mutates `metadata.frame` and then calls `setManagedReplacementMetadata`.

- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2912-2932`
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2935-2945`

The reducer then rebuilds observed/desired state but only notes `managed_replacement_metadata_changed`; it does not itself admit a window:

- `Sources/Nehir/Core/Reconcile/StateReducer.swift:137-149`

The event summary for this path is exactly the high-volume trace event:

- `Sources/Nehir/Core/Reconcile/WMEvent.swift:220-221`

### Structural replacement candidates are intentionally delayed

The managed replacement create path delays candidates when replacement correlation applies and either a burst is already pending or the candidate has a structural replacement workspace match:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:4272-4282`

The create is then appended to `pendingManagedReplacementBursts` keyed by `(pid, workspaceId)` rather than immediately tracked/admitted:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:4289-4301`

Normal app windows qualify for structural replacement correlation when metadata has role, subrole, and a structural anchor:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:4824-4831`

The grace delay is only 150 ms:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:510`
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:5037-5041`

But the flush task is cancelled and recreated whenever `resetExistingDeadline` is true, and only after the sleep completes does `flushManagedReplacementBurst` replay creates or complete a rekey:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:5044-5060`
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:5063-5078`

This makes the delay path sensitive to bursts of create/destroy and metadata churn during display/workspace migration. In the failing capture, the metadata churn lasted long enough that the user-visible workaround was to click the windows.

### Focused admission is the escape hatch that works after a click

`NSWorkspace.didActivateApplicationNotification` is wired to `handleAppActivation(... source: .workspaceDidActivateApplication)`, which is the native app switch/focus signal seen in the trace:

- `Sources/Nehir/Core/Controller/ServiceLifecycleManager.swift:344-357`

`handleAppActivation` treats `workspaceDidActivateApplication` as genuine user intent and records recent app activation, unlike ordinary focused-window churn:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2384-2391`
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2399-2425`

The focused admission path synthesizes a create placement context with trace context `focused_admission`, then either delays it through managed replacement or directly admits it via `trackPreparedCreate(candidate, admissionContext: .focusedAdmission)`:

- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2831-2860`
- `Sources/Nehir/Core/Controller/AXEventHandler.swift:2883-2888`

The event enum documents `focused_admission` as admission through `admitFocusedWindowBeforeNonManagedFallback` and `pid_reevaluation` as admission through a whole-pid AX windows query:

- `Sources/Nehir/Core/Reconcile/WMEvent.swift:24-41`

The trace's only `window_admitted` events are exactly those contexts and occur immediately after `workspaceDidActivateApplication`, so the working path is focus-driven, not the original external-display migration path.

## Hypothesis

During external-display workspace migration, structurally correlated replacement windows are held in the managed-replacement burst path while frame writes and replacement metadata updates continue. The system knows the desired target (`workspace=8EB5A181...`, `mode=tiling`, `monitor=displayId:2`) but does not consistently convert that desired state into column admission until a focus/native app-switch path re-enters admission.

This produces the observed UX:

1. Windows physically appear or partially move to the external display.
2. They churn through replacement metadata and hidden/offscreen/tiled states.
3. A user click produces `workspaceDidActivateApplication`.
4. Focused admission / pid reevaluation admits the clicked window into the column layout.

## Fix direction

Investigate the managed-replacement delay path during monitor/workspace migration:

- If a candidate already has a concrete target workspace on the currently active external monitor and desired mode is `.tiling`, consider replaying/admitting it after the first layout-stable frame instead of waiting for a native focus activation.
- Avoid letting replacement frame churn alone keep a window in an unresolved replacement/admission state.
- Add instrumentation around `enqueueManagedReplacementCreate`, `scheduleManagedReplacementFlush`, `flushManagedReplacementBurst`, and `trackPreparedCreate` to correlate burst lifecycle with `window_admitted` in display-migration scenarios.
- Specifically validate windows with normal structural metadata (`role=AXWindow`, `subrole=AXStandardWindow`) that move from built-in display coordinates to an external-display workspace.

No tests were changed for this discovery. Per runtime-debug workflow, add regression coverage only after a candidate fix is validated in the real repro.
