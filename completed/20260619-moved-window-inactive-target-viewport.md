# Moved window returns to inactive workspace offscreen — completed

**Status:** completed — shipped on `main` in `bf622041` ("Reveal moved windows in target workspace viewports").
**Source discovery:** migrated from the same-dated discovery note after the fix merged.

All source file references were verified against the main Nehir source tree on 2026-06-19.

## Completion evidence

`origin/main` contains `bf622041`, which implements target-viewport reveal for moved windows and adds focused `WorkspaceNavigationHandlerTests` coverage. Verified while updating this plan branch on 2026-06-19 via `git log origin/main` and `git show --stat bf622041`.

---

## TL;DR

Moving a window from workspace 2 back to workspace 1 can leave the moved window selected but offscreen/right-parked in workspace 1. The trace points to an independent viewport/session bug, not a regression of the four recent P1–P4 changes.

The move command updates the target workspace selection (`targetState.selectedNodeId = window.id`) inside the Niri engine, but the non-follow-focus command paths do **not** reveal that selected node in the target workspace viewport. The reveal exists only in the `focusFollowsWindowToMonitor` branches.

**Implemented fix:** centralize "prepare target viewport for a moved window" in `WorkspaceNavigationHandler`, run it for every successful cross-workspace window move, and apply a target workspace `WorkspaceSessionPatch` even when focus does not follow. The helper sets `selectedNodeId`, calls `ensureSelectionVisible`, and remembers the moved token for the target workspace.

---

## Self-contained runtime evidence

Topology and setup:

- Single monitor: `displayId=1`, frame `(0,0 2056x1329)`.
- Window of interest: `WindowToken(pid: 62326, windowId: 9812)` (`net.imput.helium`).
- Workspace ids:
  - ws1: `475137E5-40F4-4095-B9A7-A088741FFC7E`
  - ws2: `9067B16A-4775-4208-8C99-7DCDF53FB664`

Move sequence:

```text
06:54:54 workspace_assigned token=WindowToken(pid: 62326, windowId: 9812)
         from=475137E5-40F4-4095-B9A7-A088741FFC7E
         to=9067B16A-4775-4208-8C99-7DCDF53FB664

06:54:56 focus_confirmed token=WindowToken(pid: 62326, windowId: 9812)
         workspace=9067B16A-4775-4208-8C99-7DCDF53FB664
```

While on ws2, the moved window was a single-column layout and was visible:

```text
workspace=2 ... columns=1 activeColumnIndex=0 currentViewStart=-408.0 targetViewStart=-408.0
layout=c0[x=0.0,cached=1224.0]{w9812:selected{cur=416,0,1224,1267,target=416,0,1224,1267,live=416,0,1224,1267,hidden:nil}}
```

The user then moved the same window back to ws1:

```text
06:54:59 workspace_assigned token=WindowToken(pid: 62326, windowId: 9812)
         from=9067B16A-4775-4208-8C99-7DCDF53FB664
         to=475137E5-40F4-4095-B9A7-A088741FFC7E

06:55:00 window_admitted token=WindowToken(pid: 62326, windowId: 9812)
         workspace=475137E5-40F4-4095-B9A7-A088741FFC7E mode=tiling plan=phase=tiled
```

Immediately after the return move, ws2 remained the active/interaction workspace, and the moved window was in ws1 but hidden to the right:

```text
interactionWorkspace=9067B16A-4775-4208-8C99-7DCDF53FB664
focused=WindowToken(pid: 62326, windowId: 9812)

WindowToken(pid: 62326, windowId: 9812)
  workspace=475137E5-40F4-4095-B9A7-A088741FFC7E
  mode=tiling phase=tiled hidden=layoutTransient(right)
  liveAXFrame={{2055.0, 0.0}, {1224.0, 1267.0}}
  replacementFrame={{2055.0, 62.0}, {1224.0, 1267.0}}
```

The target workspace layout had four columns, with the moved window selected in the far-right column (`c3`) while the stored viewport still pointed near the old left-side view:

```text
workspace=1 ... visible=false columns=4 activeColumnIndex=0 currentViewStart=-262.0 targetViewStart=-262.0
layout=
  c0[x=0.0]{w7040{cur=270,0,1516,1267,...}}
  c1[x=1524.0]{w11616{cur=1794,0,1516,1267,...}}
  c2[x=3048.0]{w11618{cur=2056,0,1516,1267,...hidden:right}}
  c3[x=4572.0]{w9812:selected{cur=2056,0,1516,1267,target=2056,0,1516,1267,live=2055,0,1224,1267,hidden:right}}
```

That is the bug: `w9812` is the selected node in ws1, but ws1's viewport (`currentViewStart=-262`, `targetViewStart=-262`, `activeColumnIndex=0`) does not reveal column `c3` at `x=4572`; the window remains parked at the right edge.

---

## Regression check against the four recent P1–P4 changes

Verdict: **independent issue**.

- **P1 `294b253a` — two full-rescan misses before eviction.** Only changes the full-rescan `removeMissing(... requiredConsecutiveMisses: 2)` call. This trace is a workspace move/transition; the moved window is not evicted and is later admitted in ws1.
- **P2 `0ac70a5d` — coalesce same-kind refreshes.** The relevant `workspaceTransition` refreshes executed (`requested=4`, `executed=4`). There is no evidence of a dropped transition; the target session simply lacked reveal state.
- **P3 `7e9f44a9` — monitor orientation IPC.** Single-monitor trace with no monitor orientation or IPC path involvement.
- **P4 `0162aab4` — suppress frame-change relayout after recent frame-write failure.** The recent frame-write failure in the final state is for window `7040` (`failure=cancelled`), not moved window `9812`. The `9812` writes around the move confirm/park normally. Suppressing frame-change relayout after a different window's failure cannot explain the target workspace viewport staying at `activeColumnIndex=0`.

---

## Code path analysis

### The Niri move updates target selection but does not reveal it

`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:13-56` moves the node between workspace roots. It sets:

```swift
sourceState.selectedNodeId = fallbackSelection

targetState.selectedNodeId = window.id
```

It does **not** call `ensureSelectionVisible` for the target workspace. That is reasonable for a pure engine primitive only if callers finish the viewport policy.

### Some callers finish target reveal only when focus follows

`Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:771-858` handles `moveFocusedWindow(toRawWorkspaceID:)`.

- In the `focusFollowsWindowToMonitor` branch, it computes `targetState`, sets `selectedNodeId`, calls `engine.ensureSelectionVisible(...)`, and applies a session patch for the target workspace (`:801-822`).
- In the non-follow branch, it only recovers source focus and commits the transition (`:832-857`). It does not apply any target viewport patch.

`moveWindowToWorkspaceOnMonitor(rawWorkspaceID:monitorDirection:)` has the same split:

- Follow branch reveals target (`WorkspaceNavigationHandler.swift:930-956`).
- Non-follow branch recovers source focus only (`:959-979`).

`moveWindowToAdjacentWorkspace(direction:)` is even narrower: after `transferWindowFromSourceEngine`, it does `applySessionPatch(workspaceId: targetWorkspace.id, rememberedFocusToken: token)` but does not pass the mutated target viewport state or call reveal (`WorkspaceNavigationHandler.swift:596-630`).

### Why this matches the runtime evidence

The trace's final ws1 state has `w9812:selected` in the far-right column, meaning the engine/session selection reached the target workspace. But `activeColumnIndex=0` and `targetViewStart=-262.0` did not move toward the selected column. That is exactly what happens when `targetState.selectedNodeId` is updated without also running `ensureSelectionVisible` and applying the resulting viewport state.

---

## Relationship to existing discovery / plans

Relevant existing docs:

- [`20260618-stale-session-selection-revision-guard.md`](20260618-stale-session-selection-revision-guard.md) / [`20260615-omniwm-390-workspace-restore-and-stale-selection.md`](20260615-omniwm-390-workspace-restore-and-stale-selection.md) — related session/selection safety work. Not the same root cause: M6 protects against stale async patches overwriting newer live selection, while this bug is a direct command-time target viewport patch that is missing entirely. If M6 lands first, this fix should make its direct target patch fresh/unrevisioned or freshly stamped.
- [`20260616-omniwm-295-niri-window-width-preservation.md`](20260616-omniwm-295-niri-window-width-preservation.md) — same single-window cross-workspace transfer path (`moveWindowToWorkspace` / `WorkspaceNavigationHandler`), but about preserving target column width rather than revealing target viewport. Implementation should coordinate so one helper does not regress the other.
- [`../completed/20260612-viewport-navigation-redesign.md`](../completed/20260612-viewport-navigation-redesign.md) — defines the current `ensureSelectionVisible` / reveal policy. This bug should reuse that reveal path rather than inventing offset math.
- [`20260616-workspace-inactive-stale-live-frame.md`](20260616-workspace-inactive-stale-live-frame.md) and [`20260616-stale-live-frame-on-stably-hidden-column.md`](20260616-stale-live-frame-on-stably-hidden-column.md) — same visible symptom family (wrong-parked / hidden window state), but different mechanism. Those are park/write stale-live-frame issues; this one is target workspace viewport not being updated before parking inactive/offscreen windows.

Not directly relevant:

- [`20260619-nehir-62-move-workspace-to-next-monitor.md`](20260619-nehir-62-move-workspace-to-next-monitor.md) / [`../planned/20260619-nehir-62-move-workspace-to-monitor.md`](../planned/20260619-nehir-62-move-workspace-to-monitor.md) — workspace-to-monitor command plumbing, not single-window target viewport reveal.

---

## Proposed fix

Add a helper to `WorkspaceNavigationHandler`, e.g.:

```swift
private func prepareMovedWindowTargetViewport(
    token: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    reveal: Bool = true
) {
    guard let controller else { return }

    var targetState = controller.workspaceManager.niriViewportState(for: workspaceId)
    if let engine = controller.niriEngine,
       let movedNode = engine.findNode(for: token),
       let monitor = controller.workspaceManager.monitor(for: workspaceId)
    {
        targetState.selectedNodeId = movedNode.id
        if reveal {
            let gap = controller.gapSize(for: monitor)
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            engine.ensureSelectionVisible(
                node: movedNode,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &targetState,
                workingFrame: workingFrame,
                gaps: gap
            )
        }
    }

    applySessionPatch(
        workspaceId: workspaceId,
        viewportState: targetState,
        rememberedFocusToken: token
    )
}
```

Then call it after every successful single-window cross-workspace move, before `commitWorkspaceTransition`:

1. `moveWindowToAdjacentWorkspace(direction:)` — replace the existing target `rememberedFocusToken`-only patch with `prepareMovedWindowTargetViewport(token:workspaceId:)`.
2. `moveFocusedWindow(toRawWorkspaceID:)` — call it in both branches; remove the duplicated follow-branch reveal block or make the helper reusable there.
3. `moveWindow(handle:toWorkspaceId:)` — audit this direct handle path too; it should use the same helper if it can move into an inactive workspace.
4. `moveWindowToWorkspaceOnMonitor(rawWorkspaceID:monitorDirection:)` — call it in both branches; remove duplicated follow-branch reveal block.

Recommendation: always reveal the moved window in the **target workspace's stored viewport**, even when focus does not follow. This matches user expectation: if the user later switches to that workspace, the window they just moved there is visible. It also matches the existing `focusFollowsWindowToMonitor` behavior and only extends it to inactive targets.

Do **not** put this inside `NiriLayoutEngine.moveWindowToWorkspace` unless all callers can supply monitor geometry/motion policy; the engine currently has no controller settings or monitor insets. A controller-level helper is the smallest nehir-shaped fix.

---

## Suggested tests

Do not add tests until the runtime fix is confirmed in the real repro, per repo guidance. Once confirmed, add focused regression tests:

1. `WorkspaceNavigationHandlerTests.moveFocusedWindowWithoutFollowRevealsTargetViewport`
   - Arrange two workspaces on one monitor.
   - Put several columns in ws1 so a returned/moved window lands to the right.
   - Disable `focusFollowsWindowToMonitor`.
   - Move a focused window to another workspace, then back to ws1.
   - Assert target ws1 viewport state selects the moved node and `current/targetViewStart` (or equivalent visibility predicate) reveals that node/column.

2. `WorkspaceNavigationHandlerTests.moveWindowToAdjacentWorkspacePersistsTargetViewport`
   - Exercise the adjacent-workspace command path specifically.
   - Assert `rememberedFocusToken == moved token` and target viewport reveals the moved node.

3. `WorkspaceNavigationHandlerTests.moveWindowToWorkspaceOnMonitorWithoutFollowRevealsTargetViewport`
   - Covers the monitor-direction variant and ensures no branch keeps the old follow-only behavior.

Prefer asserting via engine visibility helpers if available rather than exact offsets; exact offsets are sensitive to gap/working-frame details.

---

## Validation

After implementing and after the user confirms the real repro is fixed:

```bash
swift build
swift test --filter WorkspaceNavigationHandlerTests
swift test --filter NiriLayoutEngineTests
```

Runtime validation checklist:

1. Start with ws1 containing multiple columns; ws2 empty or with one moved window.
2. Move a window from ws1 to ws2 with focus following disabled.
3. Move the same window back to ws1 while ws2 remains active.
4. Switch to ws1.
5. Expected: the moved window is visible/selected, not right-parked/offscreen; ws1 viewport points at the moved column.

---

## Risks / open questions

- **Should inactive target reveal be optional?** Recommendation: no; moving a window to a workspace is an explicit placement action, and the current follow-focus branch already reveals. Making non-follow match follow reduces surprise.
- **Column move commands.** This discovery focuses on single-window moves. Column moves may have the same asymmetry; audit `moveColumnToWorkspace*` separately before broadening the helper.
- **Interaction with stale session revision guard (M6).** If M6 lands first, target viewport patches should either be synchronous/unrevisioned or stamped fresh. This fix should not create stale async relayout patches; it is a direct command-time session patch.
- **Exact offset assertions are brittle.** Use visibility/reveal predicates in tests where possible.
