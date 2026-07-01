# Workspace bar: show other displays' workspaces in the Move to Workspace submenu

**Status:** implemented on the `workspacebar-displays` branch (working tree,
uncommitted at the time of writing). Build and the existing workspace-bar test
suites are green. Still pending, per the repo's confirm-first rule for runtime
GUI bugs: (1) user confirmation in a real multi-display repro, (2) the
release-note changeset (`patch`), and (3) a regression test asserting the
projection spans all monitors and the grouping helper splits by display.
**Source:** user report — "right click action in workspacebar is missing target
workspaces to move window from other displays"; investigated and fixed
2026-07-02. No Nehir ticket was filed at the time of writing; add one if a
tracking issue is desired.

Source line numbers below reflect the post-change working tree on
`workspacebar-displays` on 2026-07-02. Re-verify before editing; line numbers
drift.

## TL;DR

Right-clicking a window icon in the workspace bar offers a *Move to Workspace ▸*
submenu. That submenu was populated from `snapshot.items`, which only contains
the workspaces shown on **this monitor's** bar, so workspaces assigned to other
displays were never offered. The fix adds an all-monitors target list to the bar
projection and renders the submenu grouped by display (nested one level per
monitor) when more than one display is present, flat otherwise. The
controller-side move path already crossed displays, so no controller change was
needed.

## Root cause

- The submenu target list came from `WorkspaceBarContentView.windowMoveTargets`,
  previously `snapshot.items.map { WorkspaceBarWindowMoveTarget(id: $0.id,
  name: $0.name) }`.
- `snapshot.items` is `WorkspaceBarDataSource.workspaceItems(for: monitor:)`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift:80`), which reads
  `workspaceManager.workspaces(on: monitor.id)` — a **per-monitor** set.
- Therefore workspaces realized on other displays never reached the submenu, even
  though `WMController.moveWindowFromBar(token:toWorkspaceId:)`
  (`Sources/Nehir/Core/Controller/WMController.swift:848`) resolves the target by
  workspace id regardless of source monitor and already moves windows between
  displays.

## The change (three files)

1. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`
   - New `moveTargetItems(workspaceManager:settings:)` (`:362`): iterates
     `workspaceManager.monitors` → `workspaces(on:)` for each, dedupes by
     workspace id, and tags each target with `monitor.name`. Scoped to realized
     (monitor-assigned) workspaces so the targets match what the user sees across
     all bars.
   - `workspaceBarProjection(...)` passes `moveTargets:
     moveTargetItems(workspaceManager:settings:)` into the projection.
2. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - New `WorkspaceBarProjection.moveTargets` field (`:32`); new
     `WorkspaceBarSnapshot.moveTargets` convenience accessor.
   - `WorkspaceBarWindowMoveTarget` (`:186`) gains `monitorName: String?` (the
     init keeps an `nil` default so existing call sites/tests compile unchanged).
   - New `WorkspaceBarWindowMoveTargetGroup` + `workspaceBarMoveTargets(...)`
     (`:232`): groups targets by monitor, preserving first-seen monitor order and
     dropping empty groups (e.g. after a workspace is excluded).
   - New `WindowIconView.moveToWorkspaceMenuItems` `@ViewBuilder` (`:975`):
     nests one `Menu` per monitor when more than one display is present, flat
     otherwise (single-monitor parity with the previous behavior).
   - `WorkspaceBarContentView.windowMoveTargets` now returns `snapshot.moveTargets`
     (`:308`) instead of re-deriving from `snapshot.items`.
3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`
   - The fallback `WorkspaceBarProjection(items: [], sticky: nil, scratchpad: nil,
     moveTargets: [])` includes the new field.

### Side fix

Move targets used to be derived from `items`, which honors `hideEmptyWorkspaces`.
The new `moveTargetItems` does **not** filter empties, so an empty workspace is
now a valid move target. This was a latent gap (you previously could not move a
window to an empty workspace when `hideEmptyWorkspaces` was on).

### Behavior preserved

The window's own workspace is still excluded per icon via
`workspaceBarMoveTargetsExcludingCurrentWorkspace(...)` (unchanged). The
`scratchpadSlotOccupied` disable flag and the sticky-pill (unscoped) path are
unchanged.

## Tests

Existing suites green after the change:

```
swift test --filter "WorkspaceBarRightClickWiringTests|WorkspaceBarDataSourceTests|WorkspaceBarManagerTests"
```

All 27 tests pass, including `moveTargetsExcludeCurrentWorkspace` (the exclusion
helper is unchanged; the `WorkspaceBarWindowMoveTarget(id:name:)` call site in
that test still compiles thanks to the defaulted `monitorName`).

**Pending regression test** (to add after user confirmation): assert that with a
two-monitor fixture the projection's `moveTargets` contains workspaces from both
monitors (tagged with each monitor's name) and that
`workspaceBarMoveTargetGroups(...)` splits them into one group per monitor while
`workspaceBarMoveTargetsExcludingCurrentWorkspace(...)` still removes the window's
own workspace. Reuse `makeTwoMonitorLayoutPlanTestController()`.

## Validation

```bash
swift build
swift test --filter "WorkspaceBarRightClickWiringTests|WorkspaceBarDataSourceTests|WorkspaceBarManagerTests"
```

Manual:

1. Two or more displays, each with workspaces (e.g. display 1: `1`,`2`; display 2:
   `3`,`4`).
2. Right-click a window icon on display 1's bar → *Move to Workspace ▸* lists the
   other display as a nested submenu whose children are its workspaces.
3. Select a workspace on display 2 → the window moves to that display's workspace
   and relayouts immediately.
4. Single-monitor parity: the submenu is a flat list (no nesting).

Changeset (patch; confirm release policy): "Show other displays' workspaces in
the workspace bar Move to Workspace submenu, grouped by display."

## Risks and mitigations

- **IPC stability.** `IPCWorkspaceBarQueryResult` only reads `projection.items`
  and `projection.scratchpad`; adding `moveTargets` to the in-process projection
  does not change the IPC model or its Codable shape. Verified against the IPC
  router on 2026-07-02. Mitigation: none needed; no IPC test asserts on
  `moveTargets`.
- **Snapshot diff churn.** `WorkspaceBarProjection`/`WorkspaceBarSnapshot` are
  `Equatable`; `moveTargets` participates in equality, so a target-set change
  triggers a re-render. This is correct (a workspace added/removed on another
  display should refresh the submenu).
- **Monitor ordering.** Groups follow `workspaceManager.monitors` order; the
  current bar's monitor is not guaranteed to be first. Acceptable — grouping by
  monitor name is unambiguous. If users want the current display first, thread
  the current monitor name as a follow-up.
- **Density.** A flat list could grow long with many monitors; grouping into
  per-display submenus bounds each level to that display's workspaces.

## Follow-ups (out of scope)

- **Per-display "show other displays' workspaces" toggle** — makes other
  displays' workspaces first-class pills (visible at all times) so the existing
  shift+click pill action moves the focused window across displays without
  opening the submenu. Tracked in
  `planned/20260702-workspace-bar-show-other-displays-workspaces-toggle.md`.
  Keep both: this submenu performs a per-window (token) move; the toggle +
  shift+click performs a focused-window move.
- **Current-display-first ordering** in the submenu grouping (thread the current
  monitor name).
