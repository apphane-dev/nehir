# Workspace bar: show other displays' workspaces in the Move to Workspace submenu

**Status:** implemented and committed on the `workspacebar-displays` branch.
Build and the existing workspace-bar test suites are green. The `patch`
changeset exists. Still pending, per the repo's confirm-first rule for runtime
GUI bugs: (1) user confirmation in a real multi-display repro and (2) a
regression test asserting the projection spans all monitors.
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
projection and renders those targets as a single flat submenu (no extra display
nesting). The controller-side move path already crossed displays, so no
controller change was needed.

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
   - New `moveTargetItems(workspaceManager:settings:)`: iterates
     `workspaceManager.monitors` → `workspaces(on:)` for each and dedupes by
     workspace id. Scoped to realized (monitor-assigned) workspaces so the
     targets match what the user sees across all bars.
   - `workspaceBarProjection(...)` passes `moveTargets:
     moveTargetItems(workspaceManager:settings:)` into the projection.
2. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - New `WorkspaceBarProjection.moveTargets` field; new
     `WorkspaceBarSnapshot.moveTargets` convenience accessor.
   - `WorkspaceBarWindowMoveTarget` remains a simple `(id, name)` value so the
     menu stays flat and direct.
   - `WindowIconView` renders `actions.moveTargets` directly inside the existing
     *Move to Workspace ▸* submenu; no display-grouping level is inserted.
   - `WorkspaceBarContentView.windowMoveTargets` now returns
     `snapshot.moveTargets` instead of re-deriving from `snapshot.items`.
3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`
   - The fallback `WorkspaceBarProjection(items: [], sticky: nil, scratchpad: nil,
     isViewportScrollLocked: false, moveTargets: [])` includes the new field
     alongside upstream's scroll-lock field.

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

```bash
swift build
swift test --filter "WorkspaceBarRightClickWiringTests|WorkspaceBarDataSourceTests|WorkspaceBarManagerTests"
```

All 27 filtered tests pass, including `moveTargetsExcludeCurrentWorkspace` (the
exclusion helper is unchanged; `WorkspaceBarWindowMoveTarget(id:name:)` remains
the target shape).

**Pending regression test** (to add after user confirmation): assert that with a
two-monitor fixture the projection's `moveTargets` contains workspaces from both
monitors, and that `workspaceBarMoveTargetsExcludingCurrentWorkspace(...)` still
removes the window's own workspace. Reuse
`makeTwoMonitorLayoutPlanTestController()`.

## Validation

Manual:

1. Two or more displays, each with workspaces (e.g. display 1: `1`,`2`; display 2:
   `3`,`4`).
2. Right-click a window icon on display 1's bar → *Move to Workspace ▸* lists all
   realized workspace targets in one flat submenu, including display 2's
   workspaces.
3. Select a workspace on display 2 → the window moves to that display's workspace
   and relayouts immediately.

Changeset (patch): "Show other displays' workspaces in the workspace bar Move to
Workspace submenu."

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
- **Target ordering.** Targets follow `workspaceManager.monitors` order, with
  workspaces sorted per monitor. This preserves a stable all-workspaces list
  without adding a nested display level.
- **Density.** A flat list can grow long with many monitors, but it avoids the
  extra hover/click level and matches the original single-monitor menu shape.

## Follow-ups (out of scope)

- **Per-display "show other displays' workspaces" toggle** — makes other
  displays' workspaces first-class pills (visible at all times) so the existing
  shift+click pill action moves the focused window across displays without
  opening the submenu. Tracked in
  `planned/20260702-workspace-bar-show-other-displays-workspaces-toggle.md`.
  Keep both: this submenu performs a per-window (token) move; the toggle +
  shift+click performs a focused-window move.
- Optional inline display labels for cross-display targets, if a flat list lacks
  enough display context in practice.
