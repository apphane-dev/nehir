# Nehir #62 — Move workspace to next/previous monitor (workspace variant)

**Status:** planned (workspace variant only; column variant is a follow-up)
**Source discovery:** `discovery/20260619-nehir-62-move-workspace-to-next-monitor.md`
**GitHub issue:** #62

All file/line references re-verified against
the main Nehir source tree on 2026-06-19. Re-verify
before editing; line numbers drift.

## TL;DR

Nehir has a two-way `swapWorkspaceWithMonitor(.left/.right/.up/.down)` and a
cyclic `focusMonitorNext`/`focusMonitorPrevious`, but **no one-way "move the
current workspace to the next/previous monitor with wrap-around"** command. The
reporter (i3/Aerospace user) expects `Cmd+P`-style cyclic workspace moves.

This task delivers the **workspace variant only** (`moveWorkspaceToMonitor(.next/.previous)`),
which is independently shippable and satisfies the primary request. The
**column variant** (`moveColumnToMonitor`) touches the niri engine's column
model and is a separate follow-up task.

Foundation primitives are present and verified:
`WorkspaceManager.moveWorkspaceToMonitor(_:to:)` (`:3094`),
`focusMonitor(previous:)`/`swapWorkspaceWithMonitor(direction:)` in
`IPCCommandRouter`, and the cyclic `nextMonitor(from:)` ring.

## Scope (workspace variant)

Seven seam points (all verified in the discovery doc; re-verify line numbers):
1. `Sources/Nehir/Core/Input/HotkeyCommand.swift` — add
   `case moveWorkspaceToMonitor(MonitorCyclicDirection)` + the
   `MonitorCyclicDirection { next; previous }` enum.
2. `Sources/Nehir/Core/Input/ActionCatalog.swift` — title strings + default
   bindings (`Ctrl+Cmd+→` / `Ctrl+Cmd+←`; NOT `Cmd+P` — that's macOS Print).
3. `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift` — add
   `moveWorkspaceToMonitor(direction:)` next to `swapCurrentWorkspaceWithMonitor`.
4. `Sources/Nehir/Core/Controller/CommandHandler.swift` — dispatch case.
5. `Sources/Nehir/IPC/IPCCommandRouter.swift` — scriptable case (so it's IPC too).
6. `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift` — TOML keys
   (`moveWorkspaceToMonitorNext` / `…Previous`); verify load→export round-trip.
7. `Sources/Nehir/UI/HotkeySettingsView.swift` — surface the binding.

### Non-goals

- Do **not** implement `moveColumnToMonitor` here (follow-up task).
- Do **not** change `swapWorkspaceWithMonitor` (legitimate two-way feature; keep).
- Do **not** use `Cmd+P`/`Cmd+Shift+P` as defaults (macOS Print conflict).
- Do **not** rename the existing swap's in-app label in this task (separate UX task).

## Semantics (from discovery)

`moveWorkspaceToMonitor(.next)`:

1. `currentMonitorId` via `interactionMonitorId(for:)`, `currentWsId` via
   `interactionWorkspace()?.id` (mirror `swapCurrentWorkspaceWithMonitor`).
2. `target = workspaceManager.nextMonitor(from: currentMonitorId)` (**cyclic ring**,
   not spatial `adjacentMonitor`).
3. Save viewport: `saveNiriViewportState(for: currentWsId)`.
4. Move one-way: `assignWorkspaceToMonitor(currentWsId, monitorId: target.id)` +
   `setActiveWorkspace(currentWsId, on: target.id)`; on the source monitor
   activate its previous/next workspace (via `previousVisibleWorkspaceId`, as
   `swapWorkspaces` tracks) so the source isn't left blank.
5. `setInteractionMonitor(target.id)` so focus follows the moved workspace.
6. Commit: `syncMonitorsToNiriEngine()` + `commitWorkspaceTransition(
   affectedWorkspaceIds:[...], reason:.workspaceTransition)` + restore focus via
   `resolveAndSetWorkspaceFocusToken(for: currentWsId)`.

Wrap-around is automatic: `nextMonitor` returns `sorted[(idx+1) % count]`, so
`.next` from the right-most monitor lands on the left-most.

`.previous` mirrors via `previousMonitor(from:)`.

## Tests

- Unit: `nextMonitor`/`previousMonitor` cyclic wrap on 2- and 3-monitor rings
  (assert last→first on `.next`, first→last on `.previous`).
- `WorkspaceNavigationHandlerTests.moveWorkspaceToMonitorNextReassignsAndFollowsFocus`
  — 2-monitor fixture: ws A on monitor 1 → appears on monitor 2, focus follows,
  monitor 1 shows its other workspace, viewport state preserved.
- No-regression: existing `swapWorkspaceWithMonitor` + `focusMonitorNext` tests
  stay green.

## Validation

```bash
swift build
swift test --filter WorkspaceNavigationHandlerTests
swift test --filter HotkeyConfigMapping      # or the config round-trip suite
swift test --filter IPCCommandRouterTests
# Manual (2-/3-monitor): .next wraps right-most → left-most; moved ws becomes
# visible + focus-follows; source monitor backfilled, not blank; layout/scroll preserved.
```

Changeset (minor): "Add a Move Workspace to Next/Previous Monitor command with
cyclic wrap-around (i3/Aerospace-style)."

## Risks

- **Source-monitor backfill policy** — confirm `previousVisibleWorkspaceId` is
  populated in the monitor session so the source isn't blank; if not, fall back
  to the monitor's next workspace. Decide and document.
- **Focus-follows correctness** — `setInteractionMonitor` + focus restore must
  not race `commitWorkspaceTransition`; mirror swap's commit ordering exactly.
- **Default hotkey collisions** — `Ctrl+Cmd+→/←` must be checked against the
  existing `focusMonitorNext`/`focusMonitorLast` defaults.
- **IPC schema round-trip** — TOML keys must survive load→export
  (`HotkeyConfigMapping`); add a round-trip test.

## Follow-up (separate task, NOT this one)

`moveColumnToMonitor(.next/.previous)` — column-level transfer via the niri
engine's column model (enumerate focused column's nodes, per-token
`transferWindowFromSourceEngine` + `reassignManagedWindow`). Sequence after this
workspace variant lands and is verified.
