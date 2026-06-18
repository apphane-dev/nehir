# Projection Invalidation Refactor Plan

## Problem

Several UI and IPC projections are derived from core runtime state, but refreshes are currently triggered by scattered call sites. This creates a risk that a future state mutation forgets to refresh one or more consumers.

The clearest example is the workspace bar pipeline:

- Call sites manually call `WMController.requestWorkspaceBarRefresh()`.
- The method is named for the local workspace bar, but it also publishes IPC events for `.workspaceBar`, `.windowsChanged`, and `.layoutChanged`.
- `WorkspaceBarDataSource` derives its projection from multiple sources: workspaces, active workspace, managed windows, focus, scratchpad state, app info, settings, and Niri ordering.

This means correctness depends on remembering refresh calls everywhere those inputs can change.

## Similar smells

1. **Workspace bar / workspace projection refresh**
   - Manual calls to `requestWorkspaceBarRefresh()` are spread across controller, AX, layout, and scratchpad paths.
   - The method name is too narrow for what it does.

2. **Status bar refresh**
   - `refreshStatusBar()` is called from settings UI, session-state handling, and workspace-bar refresh flushing.
   - It is another derived projection with manual invalidation risk.

3. **Settings side effects in SwiftUI views**
   - UI views mutate settings and also call controller side effects such as `refreshStatusBar()`, `updateWorkspaceBarSettings()`, `updateNiriConfig(...)`, and layout setters.
   - External `settings.toml` edits require extra catch-up logic in `WMController`, which indicates that settings side effects are not centralized.

4. **Tabbed overlays and focus border**
   - Some updates flow through `RefreshExecutionEffects`, while others call managers directly.
   - These may not need to move immediately, but they should be reviewed after the projection invalidation layer exists.

## Goal

Introduce a central, coalesced invalidation pipeline for derived projections.

State owners should emit invalidations when source state changes. `WMController` should coalesce those invalidations and route them to consumers such as:

- local workspace bar
- status bar
- tabbed overlays
- focus border, where appropriate
- IPC subscription events

The goal is not to make UI observe every low-level dependency directly. The goal is to move invalidation ownership closer to the state mutations and keep consumer refreshes centralized.

## Non-goals

- Do not rewrite the layout refresh controller in one pass.
- Do not remove coalescing.
- Do not make `WorkspaceBarManager` deeply observe `WorkspaceManager`, `NiriLayoutEngine`, settings, and app info directly.
- Do not migrate focus border and tabbed overlays until the workspace/status projection pipeline is stable.

## Proposed model

Add a projection invalidation type:

```swift
enum ProjectionInvalidation: Hashable {
    case workspaceProjection
    case focusProjection
    case layoutProjection
    case displayProjection
    case settingsProjection
}
```

Optionally add reason metadata for debugging:

```swift
struct ProjectionInvalidationRequest: Hashable {
    var kind: ProjectionInvalidation
    var reason: String
}
```

`WorkspaceManager` and other state owners expose callbacks:

```swift
var onProjectionInvalidated: ((ProjectionInvalidationRequest) -> Void)?
```

`WMController` wires the callback to a coalesced scheduler:

```swift
workspaceManager.onProjectionInvalidated = { [weak self] invalidation in
    self?.requestProjectionRefresh(invalidation)
}
```

The scheduler batches invalidations and flushes once on a later main-actor turn, preserving current coalescing behavior.

## Target routing

A flush of accumulated invalidations should route as follows:

| Invalidation | Local consumers | IPC events |
| --- | --- | --- |
| `workspaceProjection` | workspace bar, status bar if enabled | `.workspaceBar`, `.windowsChanged`, `.layoutChanged` |
| `focusProjection` | status bar, focus border if needed | `.focus`, `.activeWorkspace` when active workspace changed |
| `layoutProjection` | workspace bar if ordering changed, tabbed overlays | `.layoutChanged`, `.windowsChanged` if window layout fields changed |
| `displayProjection` | workspace bar geometry, status bar if needed | `.focusedMonitor`, `.displayChanged`, `.layoutChanged` |
| `settingsProjection` | affected UI managers and layout config | depends on changed settings |

This table should be refined as the implementation discovers exact dependencies.

## Phase 1: Rename and extract current workspace-bar refresh

No behavior change.

- Rename `requestWorkspaceBarRefresh()` to a broader name, such as `requestWorkspaceProjectionRefresh()` or `requestProjectionRefresh(.workspaceProjection)`.
- Rename debug state accordingly if practical, or keep compatibility names temporarily.
- Keep current coalescing semantics: multiple requests before the next flush produce one execution.
- Keep IPC behavior unchanged: `.workspaceBar`, `.windowsChanged`, and `.layoutChanged` still publish from the same flush.

Validation:

- Existing workspace bar tests should pass.
- Tests asserting coalescing should still pass.
- IPC subscription tests should still pass, including the case where local bars are disabled but IPC subscribers exist.

## Phase 2: Move workspace projection invalidation into state owners

Add `WorkspaceManager` invalidations around central mutators that affect workspace-bar/workspace IPC projections.

Initial candidates:

- window add/remove/rekey
- workspace assignment changes
- active workspace changes
- interaction monitor changes
- managed focus changes
- scratchpad token changes
- hidden state changes
- mode changes between tiling/floating
- monitor/workspace topology changes

Important: prefer central mutators over outer call sites. For example, invalidating in `WorkspaceManager.addWindow(...)` and `removeWindow(...)` is safer than relying on each controller path that calls them.

Validation:

- Add tests that mutate `WorkspaceManager` through representative APIs and assert the controller receives one coalesced projection refresh.
- Keep old manual calls temporarily where needed; remove only after coverage proves the owner-level invalidation is sufficient.

## Phase 3: Fold status bar into projection invalidation

Treat status bar as a projection consumer, not a separately remembered refresh.

- Route workspace/focus/settings invalidations to status bar refresh when enabled.
- Remove direct `refreshStatusBar()` calls from SwiftUI settings where possible.
- Ensure active workspace and focused app changes still update the status bar.

Validation:

- Status bar tests should cover workspace changes, focused-app changes, and settings changes.

## Phase 4: Centralize settings side effects

Move settings side effects out of SwiftUI views where practical.

Desired direction:

- UI mutates `SettingsStore` only.
- A centralized settings-change handler maps changed settings to invalidations and subsystem updates.

Examples:

- status bar settings -> status projection invalidation
- workspace bar settings -> workspace bar reconfigure / workspace projection invalidation
- Niri settings -> layout config update / relayout invalidation
- border settings -> border config update
- mouse warp settings -> mouse warp policy sync

This should remove the need for UI and external config reload paths to duplicate side-effect logic.

Validation:

- Toggle settings through UI and via external settings reload.
- Both paths should produce the same subsystem updates.

## Phase 5: Review tabbed overlays and focus bar (assessment complete)

After workspace/status/settings invalidation is stable, review remaining direct calls.

Assessment conclusion: **all remaining direct calls are justified and should be kept.**

Tabbed overlay calls (`updateTabbedColumnOverlays`):
- 3 direct calls with `forceOrdering: true` in AXEventHandler (rekey, app activation) and
  LayoutRefreshController (visibility side effects) require immediate ordering updates.
- All other calls already flow through `RefreshExecutionEffects.updateTabbedOverlays` in
  layout execution plans.

Focus border calls (`focusBorderController.*`):
- `updateFrameHint`, `focusChanged`, `clear`, `hide`, `rekeyFocusedTarget`, `suppressManagedTarget`
  are frame-precise, synchronous operations tied to specific event handling points.
- Coalescing these would break visual responsiveness and ordering guarantees.
- Visibility-related border refresh already flows through
  `RefreshExecutionEffects.refreshFocusedBorderForVisibilityState`.

Remaining `requestWorkspaceProjectionRefresh()` calls in LayoutRefreshController:
- All fire as execution plan effects after layout/visibility completion.
- These cover state changes through the reconcile/action-plan pathway that bypasses
  direct WorkspaceManager mutators (where owner invalidations are wired).
- Not redundant with owner invalidations.

`.layoutProjection` and `.displayProjection` remain as tracked-but-unrouted cases
for future use.

Potential outcomes:

- Keep event-specific direct updates where they require immediate frame hints or precise focus targets.
- Move broad “ordering changed” / “visibility changed” updates into projection/layout invalidations.
- Avoid forcing everything into the new pipeline if direct calls are clearer and safer.

## Rollout strategy

Use small PRs with no-behavior-change steps first.

Recommended order:

1. Rename/extract current workspace-bar refresh pipeline.
2. Add projection invalidation types and debug counters.
3. Wire `WorkspaceManager` invalidations while keeping existing manual calls.
4. Add tests for owner-level invalidation and coalescing.
5. Remove redundant manual workspace-bar refresh calls.
6. Migrate status bar.
7. Centralize settings side effects.
8. Reassess tabbed overlays and focus border.

## Risks

- Over-broad invalidations may cause extra refresh work.
- Under-broad invalidations may preserve the original missed-refresh problem.
- Moving settings side effects too quickly could break external config reload behavior.
- Focus border may require immediate updates and should not be blindly coalesced.

## Success criteria

- Workspace projection changes are invalidated from central state mutations, not scattered UI/controller call sites.
- Local workspace bar and IPC workspace events remain coalesced.
- Status bar updates use the same invalidation model.
- UI settings views contain fewer direct controller side-effect calls.
- External settings reload and UI setting changes share the same behavior path.
- Tests cover coalescing and representative state mutations.
