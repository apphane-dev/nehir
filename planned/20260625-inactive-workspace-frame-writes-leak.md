# Inactive-workspace layout frame writes leak windows back onscreen — Plan

A workspace-1 Helium window was visible while workspace 5 was active and empty.
Clicking that Helium window activated workspace 1, confirming the window had not
been reassigned to workspace 5; it had been physically leaked onscreen while its
model still belonged to an inactive workspace.

All source references were verified against the main Nehir source tree at
`8887adcb` on 2026-06-25 (`git log -1 --format='%h %s'` → `8887adcb Fixup
changeset reporter contribution mention`). Line numbers will drift; function
names are included so the code remains findable.

---

## TL;DR

- **Symptom.** Workspace 5 is visible with `columns=0`, but a Helium browser
  window assigned to workspace 1 remains visible at `live=(1032,0 1008x1282)`.
- **Root cause.** The layout diff executor treats every frame write in a
  `WorkspaceLayoutPlan` as an active/visible job. It calls
  `AXManager.markWindowActive` and `unsuppressFrameWrites` for those frame jobs
  before applying them. If the plan belongs to an inactive workspace, this
  removes the window from `inactiveWorkspaceWindowIds`, bypassing
  `AXManager.applyFramesParallel`'s `skip-inactive` guard. The visible frame is
  written, but the model still says `hiddenState.workspaceInactive == true`.
- **Why it sticks.** `hideInactiveWorkspaces` later sees the existing hidden
  state and `hideWorkspace` assumes the window is already parked, so it skips the
  corrective hide and only emits `workspaceInactiveVisibleDrift`.
- **Fix direction.** Inactive workspace layout plans must not mark frame-change
  jobs active or unsuppress them unless the change is an explicit reveal/restore
  for a workspace that is currently active. Preserve the inactive-window
  suppression set so frame writes for inactive workspaces remain `skip-inactive`,
  and let `hideInactiveWorkspaces` own offscreen parking.

---

## Runtime evidence to preserve

Single display `ID(displayId: 1)`, frame `(0.0, 0.0, 2056.0, 1329.0)`, visible
frame `(0.0, 0.0, 2056.0, 1290.0)`, `displaySpacesMode=enabled`,
`focusFollowsMouse=false`.

Workspace ids involved:

- workspace 1: `F80B4AC3-6ED2-45FD-A73C-9643F50882A5`
- workspace 5: `5FCBDE5C-7B33-46B8-AD64-86E996C713EA`

### Workspace 5 starts empty

At capture start, workspace 5 was already present but had no windows:

```text
workspace=5 id=5FCBDE5C-7B33-46B8-AD64-86E996C713EA visible=false columns=0
selectedNode=nil preferredFocus=nil
workspace=5 id=5FCBDE5C-7B33-46B8-AD64-86E996C713EA no-columns
```

Helium windows belonged to workspace 1, including:

```text
WindowToken(pid: 32351, windowId: 21476) workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  bundleId=net.imput.helium
WindowToken(pid: 32351, windowId: 21278) workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  bundleId=net.imput.helium
```

### A Slack window briefly moves to workspace 5, then moves back

Workspace 5 becomes non-empty only because Slack `22373` is moved there:

```text
2026-06-25T14:14:57Z event=workspace_assigned token=WindowToken(pid: 23613, windowId: 22373)
  from=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  to=5FCBDE5C-7B33-46B8-AD64-86E996C713EA
  plan=desired=workspace=5FCBDE5C-7B33-46B8-AD64-86E996C713EA,mode=tiling,rescue=true
```

Then it is moved back to workspace 1:

```text
2026-06-25T14:15:06Z event=workspace_assigned token=WindowToken(pid: 23613, windowId: 22373)
  from=5FCBDE5C-7B33-46B8-AD64-86E996C713EA
  to=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  plan=desired=workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5,mode=tiling,rescue=true
```

After that, workspace 5 is the visible workspace but has no columns:

```text
interactionWorkspace=5FCBDE5C-7B33-46B8-AD64-86E996C713EA
workspace=5 id=5FCBDE5C-7B33-46B8-AD64-86E996C713EA visible=true columns=0
selectedNode=nil preferredFocus=nil
workspace=5 id=5FCBDE5C-7B33-46B8-AD64-86E996C713EA no-columns
```

### Helium is still assigned to workspace 1 but physically visible

While workspace 5 is active, Nehir repeatedly detects the workspace-1 Helium
window `21476` in the visible monitor instead of parked offscreen:

```text
workspaceInactiveVisibleDrift trigger=hideWorkspace.skipAlreadyHidden
  token=WindowToken(pid: 32351, windowId: 21476)
  workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  interactionWorkspace=5FCBDE5C-7B33-46B8-AD64-86E996C713EA
  windowId=21476 hiddenReason=workspaceInactive side=right
  live=(1032,0 1008x1282) expectedPark=(2056,0) dx=1023.5 dy=0.0
  lastApplied=(1032,0 1008x1282) replacement=(16,47 1008x1282)
```

The key details are:

- `workspace` is workspace 1, not workspace 5.
- `interactionWorkspace` is workspace 5.
- `hiddenReason=workspaceInactive` says the model believes it is hidden because
  its workspace is inactive.
- `live=(1032,0 1008x1282)` is onscreen.
- `expectedPark=(2056,0)` is the physical offscreen park position.
- `lastApplied=(1032,0 1008x1282)` shows Nehir itself most recently applied the
  visible frame.

### The later click activates workspace 1

At the start of the click capture, workspace 5 is active and unmanaged/nonmanaged
focus is in effect:

```text
interactionWorkspace=5FCBDE5C-7B33-46B8-AD64-86E996C713EA
wmCommandTarget=nil layoutSelection=nil observedManagedFocus=nil nonManaged=true
windows total=6 tiled=6 floating=0 hidden=6
```

Helium `21476` is still modelled on workspace 1 but has a visible live frame:

```text
WindowToken(pid: 32351, windowId: 21476)
  workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
  hidden=workspaceInactive
  liveAXFrame={{1032.0, 0.0}, {1008.0, 1282.0}}
  bundleId=net.imput.helium
```

The click occurs at `(1375.4,1171.3)`, which is inside the leaked Helium frame
`x=1032...2040`, `y=0...1282`:

```text
2026-06-25T14:18:30Z mouseDown loc=(1375.4,1171.3) button=left
2026-06-25T14:18:30Z mouseUp loc=(1375.4,1171.3) button=left
```

That produces native app activation and focus confirmation for Helium `21476` on
workspace 1:

```text
2026-06-25T14:18:30Z event=focus_lease_changed owner=native_app_switch
  reason=workspaceDidActivateApplication
2026-06-25T14:18:30Z event=managed_focus_confirmed token=WindowToken(pid: 32351, windowId: 21476)
  workspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
```

End state confirms the switch:

```text
interactionWorkspace=F80B4AC3-6ED2-45FD-A73C-9643F50882A5
wmCommandTarget=WindowToken(pid: 32351, windowId: 21476)
layoutSelection=WindowToken(pid: 32351, windowId: 21476)
workspace=1 id=F80B4AC3-6ED2-45FD-A73C-9643F50882A5 visible=true columns=6
workspace=5 id=5FCBDE5C-7B33-46B8-AD64-86E996C713EA visible=false columns=0
```

---

## Source mapping

### The intended guard exists in `AXManager`

`AXManager.updateInactiveWorkspaceWindows` populates
`inactiveWorkspaceWindowIds` from the active workspace set. `applyFramesParallel`
then refuses visible frame writes for those ids:

```swift
// Sources/Nehir/Core/AX/AXManager.swift
func updateInactiveWorkspaceWindows(... activeWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
    inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
    for (wsId, windowId) in allEntries {
        if !activeWorkspaceIds.contains(wsId) {
            inactiveWorkspaceWindowIds.insert(windowId)
        }
    }
}

private func enqueueFrameApplications(...) {
    for (pid, windowId, frame) in frames {
        if inactiveWorkspaceWindowIds.contains(windowId) {
            recordFrameApplyTrace("skip-inactive id=\(windowId) ...")
            continue
        }
        ...
    }
}
```

This is the right invariant: inactive workspace windows should not get ordinary
onscreen layout frames.

### Refresh execution builds that inactive set before layout

`LayoutRefreshController.executeRefreshExecutionPlan` rebuilds the inactive set
before `executeLayoutPlans` so newly inactive windows are protected during layout
application:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift
if let visibility = plan.effects.visibility {
    rebuildInactiveWorkspaceWindowSet(activeWorkspaceIds: visibility.activeWorkspaceIds)
}

executeLayoutPlans(plan.workspacePlans)
```

So when workspace 5 is active, workspace-1 windows should be in
`inactiveWorkspaceWindowIds` before their workspace-1 layout plan executes.

### The diff executor defeats the guard

The diff executor gathers every frame change into `visibleFrameJobs`, then marks
all of them active and unsuppresses them before calling `applyFramesParallel`:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift
let visibleFrameJobs = (frameUpdates + resizeMinimumProbeFrameUpdates + revealFrameUpdates)
    .map { (pid: $0.pid, windowId: $0.windowId) }
...
for job in visibleJobs + visibleFrameJobs where seenActiveWindowIds.insert(job.windowId).inserted {
    activeFrameJobs.append(job)
}
if !activeFrameJobs.isEmpty {
    for job in activeFrameJobs {
        controller.axManager.markWindowActive(job.windowId)
    }
    controller.axManager.unsuppressFrameWrites(activeFrameJobs)
}

if !frameUpdates.isEmpty {
    controller.axManager.applyFramesParallel(frameUpdates)
}
```

`markWindowActive` is just:

```swift
func markWindowActive(_ windowId: Int) {
    inactiveWorkspaceWindowIds.remove(windowId)
}
```

Therefore any frame change in an inactive workspace plan removes that window from
`inactiveWorkspaceWindowIds` immediately before the guarded write. That explains
why the later trace has `lastApplied=(1032,0 1008x1282)` for Helium `21476`
instead of `skip-inactive`.

### The later hide pass assumes hidden-state means already parked

After layout plans, `hideInactiveWorkspaces` rebuilds the inactive set again and
then calls `hideWorkspace` for inactive snapshots. But `hideWorkspace` skips any
entry that already has a hidden state:

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift
if let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) {
    traceWorkspaceInactiveVisibleDriftIfNeeded(... trigger: "hideWorkspace.skipAlreadyHidden")
    continue
}
hideWindow(entry, monitor: monitor, side: preferredSide, reason: .workspaceInactive, ...)
```

This skip is only safe if hidden state implies the live window is still parked.
Here it does not: the diff executor wrote the visible frame while leaving
`hiddenState.workspaceInactive == true`, so the hide pass only logs drift and
skips the corrective `hideWindow`.

---

## Root cause

There are two partially conflicting ownership models for inactive workspace
windows:

1. `AXManager.inactiveWorkspaceWindowIds` says ordinary layout frame writes to
   inactive workspaces must be skipped.
2. `LayoutDiffExecutor.execute` says every frame write in a layout diff is
   visible/active and should be unsuppressed + removed from the inactive set.

The second rule is too broad. A frame write in an inactive workspace plan is not
proof that the window should be active; it is only the layout engine computing
where that window would be if the workspace were visible. Applying that target
onscreen causes exactly this leak.

The existing `workspaceInactiveVisibleDrift` instrumentation was designed for
this family and pinpoints the stuck state, but it is diagnostic-only. It does not
repair because `hideWorkspace` exits on hidden state.

---

## Implementation plan

### 1. Teach the diff executor whether its plan workspace is active

Inside `LayoutDiffExecutor.execute`, compute whether `plan.workspaceId` is the
current active workspace on the plan monitor, for example:

```swift
let isPlanWorkspaceActive = controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == plan.workspaceId
```

Use the already resolved `monitor` in that method.

### 2. Do not activate ordinary frame jobs for inactive workspace plans

Split frame jobs into:

- **active/reveal jobs**: `visibleJobs` and `revealFrameUpdates`, plus ordinary
  `frameUpdates` only when `isPlanWorkspaceActive == true`.
- **inactive ordinary jobs**: `frameUpdates` and resize-minimum probe updates for
  inactive workspace plans.

Only active/reveal jobs may call:

- `AXManager.markWindowActive`
- `AXManager.unsuppressFrameWrites`

For inactive ordinary jobs, leave `inactiveWorkspaceWindowIds` intact so
`applyFramesParallel` records `skip-inactive` and does not move the window
onscreen. This preserves the pre-layout inactive set built by
`executeRefreshExecutionPlan`.

### 3. Be conservative with hidden-state clears

Do not let `.show` entries from an inactive workspace plan clear
`hiddenState.workspaceInactive`. A `.show` diff means "visible inside this
workspace layout," not "visible on the active monitor" when the workspace is
inactive.

If the current code can clear hidden state from `shownEntries` in an inactive
plan, gate that clearing behind `isPlanWorkspaceActive` or an explicit
workspace-inactive reveal transaction.

### 4. Keep `hideInactiveWorkspaces` as the owner of inactive parking

After layout execution, `hideInactiveWorkspaces` already:

- re-anchors global sticky windows,
- rebuilds `inactiveWorkspaceWindowIds`,
- cancels inactive-window frame jobs,
- calls `hideWorkspace` for inactive workspace snapshots.

The fix should not duplicate that ownership. It should simply stop the diff
executor from undoing the inactive classification before `hideInactiveWorkspaces`
can enforce it.

### 5. Optional hardening: repair drift instead of only logging it

After the primary fix, consider hardening `hideWorkspace`:

- If `hiddenState.workspaceInactive == true` but `workspaceInactiveVisibleDriftLine`
  would report a visible drift, call `hideWindow(... reason: .workspaceInactive)`
  instead of only logging and continuing.
- Keep this as a second-line repair, not the main fix, because the main bug is
  the visible frame write that should never happen.

---

## Test plan

Add tests near `LayoutRefreshControllerTests` / `RefreshRoutingTests` that model
an inactive workspace receiving a layout frame change while it already has a
workspace-inactive hidden state.

### Regression test: inactive plan must not unsuppress or apply visible frames

Setup:

1. Single monitor with workspace 1 and workspace 5.
2. Workspace 5 active.
3. Helium-like window `21476` belongs to workspace 1.
4. Mark it `hiddenState.workspaceInactive == true` and add it to
   `inactiveWorkspaceWindowIds` via the visibility effect active set `{workspace5}`.
5. Build/execute a workspace-1 layout plan containing a frame change to an
   onscreen target such as `(1032,0 1008x1282)`.

Expect:

- `AXManager.applyFramesParallel` skips the frame because the window remains
  inactive (`skip-inactive` or equivalent test hook result).
- The window remains in the inactive set until `hideInactiveWorkspaces` handles
  it.
- `workspaceManager.hiddenState(for: token)?.workspaceInactive == true` remains
  intact.
- No `lastAppliedFrame` is recorded for the onscreen frame.

### Regression test: active workspace reveals still work

Setup the same window but make workspace 1 active. Execute the workspace-1 plan
with a restore/show frame.

Expect:

- The frame is applied.
- `hiddenState` is cleared through the existing reveal/restore path.
- The window is marked active and unsuppressed.

### Regression test: existing drift repair hook, if implemented

If optional hardening is added, seed a hidden workspace-inactive entry whose live
frame intersects the active monitor and whose expected park differs by more than
2 pt.

Expect:

- `hideWorkspace` re-applies workspace-inactive parking instead of only tracing
  `hideWorkspace.skipAlreadyHidden`.

---

## Acceptance criteria

- Reproducing the captured sequence no longer leaves Helium `21476` visible while
  workspace 5 is active and empty.
- A workspace-1 frame change emitted while workspace 5 is active cannot remove
  the window from `inactiveWorkspaceWindowIds` merely because it has a frame
  change.
- The capture would show `skip-inactive id=21476 target={{1032.0, 0.0}, ...}`
  or no attempted visible frame write, rather than `lastApplied=(1032,0
  1008x1282)` followed by `workspaceInactiveVisibleDrift`.
- Clicking an actually hidden workspace-1 Helium window is impossible from
  workspace 5 because it is offscreen; no native activation bounce to workspace 1
  occurs.
