# New-Window Placement Tracing — Discovery (Step 1 of 2)

Reported issue: **a newly created window is placed on the main monitor even
though the currently active monitor is the secondary one.**

This is **step 1** of a two-step discovery. It scopes a *tracing
improvement only* — adding the create-focus trace to the runtime trace dump so
the placement decision can be diagnosed from a single capture. The actual
root-cause investigation and fix direction live in the companion
**step 2**: `20260615-new-window-placement-investigation.md`.

The bug was confirmed reproducible from an existing runtime trace capture
(2026-06-15, ~5.4 s window, nehir v0.5.0). All findings from that trace are
inlined into step 2 so neither step depends on that file surviving.

All file references should be re-verified before implementing; line numbers drift.

---

## TL;DR

- The placement pipeline already emits a **decisive** trace event,
  `create_placement_resolved`, that records every input that *could* have driven
  the decision (pending/focused/native/frame/interaction workspace + monitor)
  next to the workspace that was actually chosen.
- That event lives in `AXEventHandler.createFocusTrace`, which is **not** written
  to the runtime trace dump. The dump only carries viewport / resize / mouse
  traces (`WMController.swift:2655`–`2696`). So today a runtime capture can prove
  the result was wrong but **cannot** say which input won.
- Fix: expose `createFocusTrace` (currently only via
  `niriCreateFocusTraceSnapshotForTests()`, `AXEventHandler.swift:514`) to
  non-test code and add a `## Niri create focus trace` section to the dump
  writer. Low risk, ~15 lines. This is the prerequisite for step 2.
- Bonus (optional, cheap): also snapshot the captured
  `WindowCreatePlacementContext` fields into the dump, since they are exactly the
  inputs the investigator needs and are otherwise ephemeral.

---

## Why this is step 1 (a blocker for diagnosis)

Window placement for a brand-new tiling window funnels through
`WMController.resolveWorkspacePlacement` (`WMController.swift:1008`) →
`createPlacementTarget` (`:1205`). With `preferManagedFocusPlacement == true`
(the new-window tiling case), `createPlacementTarget` tries inputs in a **strict
priority order** and returns the first that resolves:

1. `activeFocusRequestWorkspaceId/MonitorId` (snapshot at create time)
2. `focusedWorkspaceId/MonitorId` (confirmed managed focus at create time)
3. `nativeSpaceMonitorId` (the macOS Space the window was born on)
4. `frameMonitorId` (window frame center)
5. fast AX-frame monitor (multi-monitor only)
6. `interactionMonitorId`
7. `fallbackWorkspaceId` (live `interactionWorkspace().id`)

The snapshot is captured in `AXEventHandler.captureCreatePlacementContext`
(`:3356`) at `handleCGSWindowCreated` (`:420`).

Because seven inputs feed one decision and only the **result** is visible in the
dump, the inlined trace (see step 2) can narrow the cause to a small number of
hypotheses but cannot disambiguate them. The disambiguating signal —
`create_placement_resolved` — already exists, it just never reaches the file.

### The event that already has the answer

`recordCreatePlacementTrace` (`AXEventHandler.swift:2472`) emits a
`NiriCreateFocusTraceEvent.createPlacementResolved` whose description
(`:97`–`108`) is:

```
create_placement_resolved token=… workspace=<resolved>
  pending_workspace=… pending_monitor=…
  focused_workspace=… focused_monitor=…
  native_monitor=… frame_monitor=… interaction_monitor=…
```

`workspace=` is the resolved placement; whichever of the five input pairs equals
it is the winning input. That single line closes the investigation.

---

## Proposed change

### 1. Expose the create-focus trace to non-test code

`AXEventHandler.swift:514`:

```swift
func niriCreateFocusTraceSnapshotForTests() -> [NiriCreateFocusTraceEvent] {
    createFocusTrace
}
```

Rename to a non-`…ForTests` accessor (e.g. `createFocusTraceSnapshot()`) or add a
parallel internal accessor. Keep the existing test entry point stable (tests at
`Tests/NehirTests/AXEventHandlerTests.swift` call it from ~15 sites and
`WMControllerFocusTests` / `MouseEventHandlerTests` indirectly).

### 2. Add the section to the runtime trace dump

`WMController.swift:2655`–`2696` builds the dump body from an array of sections.
Mirror the existing viewport/resize/mouse blocks:

```swift
let createFocusTraceDump = axEventHandler.createFocusTraceSnapshot().isEmpty
    ? "create focus trace empty"
    : axEventHandler.createFocusTraceSnapshot().map(\.description).joined(separator: "\n")
```

and insert, between the viewport trace and the resize trace (or just after
`## Tracing logs`):

```
## Niri create focus trace
<createFocusTraceDump>
```

`WMController` already holds `axEventHandler`, so no new wiring is needed.

### 3. (Optional, recommended) Snapshot the placement context too

`WindowCreatePlacementContext` (`AXEventHandler.swift:80`) holds exactly the
inputs step 2 needs (`nativeSpaceMonitorId`,
`activeFocusRequestWorkspaceId/MonitorId`, `focusedWorkspaceId/MonitorId`,
`interactionMonitorId`). It is keyed by window id and pruned by a TTL
(`createPlacementContextTTL`). A one-line debug dump of the live map at capture
*start* and *end* (similar to `-- Managed Windows --`) would preserve the inputs
even if `create_placement_resolved` rotated out of the 128-event ring buffer
(`createFocusTraceLimit`, `:291`).

---

## Acceptance for step 1

- A runtime trace capture taken during the repro contains a
  `## Niri create focus trace` section with at least one
  `create_placement_resolved token=<the new window> workspace=<id> …` line.
- Existing tests still compile and pass (the rename/generalization is the only
  surface change).
- No behavioral change to placement — this is observability only.

Once step 1 lands, step 2 (`20260615-new-window-placement-investigation.md`)
becomes directly actionable: read one line to confirm the hypothesis.
