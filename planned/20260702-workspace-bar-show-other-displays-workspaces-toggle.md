# Workspace bar: per-display toggle to show other displays' workspaces as pills

**Status:** planned. Design discussed 2026-07-02; not started. Depends on nothing
— the controller-side focus/move plumbing it relies on already exists and is
monitor-aware (see Key findings). Sibling to
`completed/20260702-workspace-bar-move-to-workspace-other-displays.md`, which
addresses the same "move a window to another display" goal via the right-click
submenu; this plan addresses it via always-visible pills + the existing
shift+click pill action.
**Source:** design discussion 2026-07-02. No Nehir ticket filed at the time of
writing.

Source line numbers below were verified against the main Nehir source tree on
2026-07-02. Re-verify before editing; line numbers drift.

## TL;DR

Add an opt-in, per-display workspace-bar setting that also renders the workspaces
shown on **other** displays as pills in this display's bar. Combined with the
existing shift+click pill action (which moves the focused window to the clicked
workspace), this gives a one-step "move the focused window to another display"
gesture without opening the right-click submenu. The hard-looking part —
switching another display to a workspace, and moving a window across displays —
is already implemented and monitor-aware, so this is mostly a projection +
rendering change gated by a toggle.

## Motivation

- Discoverability: other displays' workspaces are visible at a glance instead of
  buried in a right-click submenu.
- Consistency: the workspace pill already supports shift+click to move the
  focused window (`WorkspaceBarManager.handleWorkspacePillClick` →
  `WMController.moveFocusedWindowFromBar`,
  `Sources/Nehir/Core/Controller/WMController.swift:821`); exposing foreign
  workspaces as pills reuses that gesture for cross-display moves.
- Per-display opt-in keeps the bar minimal for users who do not want it.

## Key findings (de-risking)

The controller paths a foreign pill would invoke already resolve the correct
monitor and already cross displays:

- **Plain click** → `WMController.focusWorkspaceFromBar(id:)`
  (`Sources/Nehir/Core/Controller/WMController.swift:812`) →
  `WindowActionHandler.focusWorkspaceFromBar(id:suppressMouseWarp:)`
  (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:591`) →
  `WorkspaceManager.focusWorkspace(id:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2481`), which resolves
  the workspace's **home monitor** via `monitorForWorkspace(...)` and calls
  `setActiveWorkspace(_:on:)` on that monitor. The bar path passes
  `suppressMouseWarp: true`, so clicking a foreign pill switches the other
  display **without yanking the cursor**. (Keyboard focus may still move to the
  other screen — see Risks.)
- **Shift+click** → `WorkspaceBarManager.handleWorkspacePillClick`
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:631`) →
  `.moveWindow` → `WMController.moveFocusedWindowFromBar` → the existing move
  pipeline with target-viewport reveal + focus-follows-window-to-monitor. This
  already moves the focused window across displays (the sibling plan's fix
  exercises the same path).

So no new interaction logic is required; the work is projection + rendering +
toggle.

## Open design decisions (confirm before implementing)

1. **Plain-click behavior on a foreign pill.** Recommended: switch its home
   display (works today, cursor stays put). Alternative: no-op, shift+click only.
   Caveat: switching the home display moves keyboard focus to the other screen,
   which can surprise users — the opt-in toggle mitigates this.
2. **Foreign "active" visual.** A foreign workspace that is active on *its own*
   display must not look like *this* display's active workspace (which gets the
   bold accent ring). Recommended: a distinct, subtler treatment (e.g. a small
   dot) so "active over there" is distinguishable from "where I am".
3. **`hideEmptyWorkspaces` interaction.** Recommended: foreign empty workspaces
   are hidden when `hideEmptyWorkspaces` is on (consistent with local items).

The defaults below assume: switch-home-display, subtle-dot distinction, respect
`hideEmptyWorkspaces`.

## Scope

### Files to add/change

1. **Toggle plumbing (mirror `hideEmptyWorkspaces` exactly).** Add a
   `showWorkspacesFromOtherDisplays: Bool?` override and a resolved
   `showWorkspacesFromOtherDisplays: Bool` (default `false`):
   - `Sources/Nehir/Core/Config/MonitorBarSettings.swift` (override property,
     init param, `CodingKeys`, `init(from:)`, `encode(to:)`; `hideEmptyWorkspaces`
     at `:20`/`:40`/`:59`/`:74`/`:88`/`:112`/`:131`/`:149` is the template).
   - `Sources/Nehir/Core/Config/SettingsStore.swift`
     (`resolvedBarSettings` resolution at `:811`).
   - `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift` (schema field
     `:165`, coding-keys list `:178`, export `:326`, import mapping `:419`,
     decode `:738`, encode `:772`).
   - `Sources/Nehir/Core/Config/MonitorOverrideFileStore.swift` (TOML write
     `:134`, TOML read `:219`).
   - `Sources/Nehir/Core/Config/SettingsFilePersistence.swift` (export/import, if
     the new field needs explicit mapping).
   - `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarProjectionOptions.swift` (add the
     flag; `hideEmptyWorkspaces` at `:11`/`:19` is the template) and
     `ResolvedBarSettings.projectionOptions`.
2. **Projection.** `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`:
   `workspaceItems(for:options:...)` (`:80`) currently reads only
   `workspaces(on: monitor.id)`. When the toggle is on, append other monitors'
   realized workspaces (skip the current monitor, which is already included),
   respecting `hideEmptyWorkspaces`.
3. **Item model.** `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`:
   `WorkspaceBarItem` (`:11`) gains `isForeign: Bool`, `homeMonitorName: String?`,
   and `isActiveOnHomeDisplay: Bool` (distinct from the existing `isFocused`,
   which means active *on this monitor`). `Equatable` must include them.
4. **Rendering.** Render foreign workspaces after the local ones, behind a
   divider, with a monitor tag/suffix and the distinct active treatment. Their
   pills reuse the existing `onFocusWorkspace` / `onMoveFocusedWindowToWorkspace`
   closures (already monitor-aware — no new closures).
5. **Settings UI.** `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`: add the
   toggle (global default + per-monitor override surface), mirroring the
   `hideEmptyWorkspaces` control.

### Non-goals

- Do **not** implement "Move Workspace to Monitor" (Nehir #62,
  `planned/20260619-nehir-62-move-workspace-to-monitor.md`); foreign pills only
  *switch* the home display and *move a window to* it, they do not relocate the
  workspace onto this display.
- Do **not** change the right-click *Move to Workspace ▸* submenu (sibling plan);
  the two coexist (submenu = per-window token move; pills + shift+click =
  focused-window move).
- Do **not** change focus-follows / mouse-warp policy beyond what the existing
  `suppressMouseWarp` bar path already does.

## Exact implementation plan

Phased and ordered; each phase is independently buildable.

### Phase 1 — Toggle plumbing (no behavior change)

1. Add the override + resolved flag across the six config files, mirroring
   `hideEmptyWorkspaces`. Default `false`.
2. Thread it into `WorkspaceBarProjectionOptions`.

**Gate:** `swift build` green; a unit test asserting the resolved default is
`false` and an override wins.

### Phase 2 — Projection + item model (no visible change while toggle is off)

1. Extend `WorkspaceBarItem` with `isForeign` / `homeMonitorName` /
   `isActiveOnHomeDisplay`; update all call sites and `Equatable`.
2. In `workspaceItems`, when the toggle is on, append other monitors' realized
   workspaces (deduped, `hideEmptyWorkspaces`-aware), marked foreign and tagged
   with their home monitor name and home-active state.

**Gate:** `swift build` green; existing projection tests unchanged (toggle off);
a new test asserting foreign workspaces appear only when the toggle is on.

### Phase 3 — Rendering (visible change)

1. Render foreign items after local items behind a divider, with a monitor tag
   and the distinct active treatment (open decision #2).
2. Confirm plain click and shift+click route through the existing closures and
   behave per open decision #1.

**Gate:** manual multi-display validation; a snapshot/wiring test confirming
foreign pills expose their tokens and route to the existing handlers.

### Phase 4 — Settings UI

1. Add the toggle to `WorkspaceBarSettingsTab` (global + per-monitor override).

**Gate:** `swift build` green; manual toggle on/off changes the bar immediately.

## Tests

- Config: resolved default `false`; monitor override wins; TOML round-trips the
  override (mirror the `hideEmptyWorkspaces` config tests).
- Projection (`WorkspaceBarDataSourceTests`): with the toggle on and a
  two-monitor fixture, the projection for monitor A includes monitor B's
  workspaces marked `isForeign` with the correct `homeMonitorName` and
  `isActiveOnHomeDisplay`; with the toggle off, behavior is unchanged.
- Wiring: foreign pills expose their workspace id and route plain-click to
  `focusWorkspaceFromBar` and shift+click to `moveFocusedWindowFromBar` (same
  contract as local pills).

Reuse `makeTwoMonitorLayoutPlanTestController()`.

## Validation

```bash
swift build
swift test --filter "WorkspaceBarDataSourceTests|WorkspaceBarManagerTests|Config.*"
swift test
```

Manual:

1. Two displays, each with workspaces; enable the toggle on display 1's bar.
2. Display 1's bar shows its own workspaces, then a divider, then display 2's
   workspaces (tagged with display 2's name).
3. Shift+click a display 2 workspace pill on display 1's bar → the focused
   window moves to display 2.
4. Plain-click a display 2 workspace pill → display 2 switches to it (cursor
   stays on display 1).
5. Toggle off → display 1's bar reverts to its own workspaces only.

Changeset (minor): "Add a per-display workspace-bar toggle to show other
displays' workspaces as pills."

## Risks and mitigations

- **Cross-display focus surprise.** Plain-clicking a foreign pill switches the
  other display and may move keyboard focus off the screen the user is looking
  at. Mitigation: opt-in toggle (off by default); documented behavior; the
  subtle-dot distinction signals which pills are foreign.
- **Visual ambiguity.** Without a clear distinction, foreign "active" pills could
  be mistaken for this display's active workspace. Mitigation: distinct active
  treatment (open decision #2) + divider + monitor tag.
- **Density.** Many displays × many workspaces crowds the bar. Mitigation: opt-in;
  `hideEmptyWorkspaces` respected; per-monitor toggle lets users enable it only
  where wanted.
- **`WorkspaceBarItem` equality churn.** New fields join `Equatable`, so
  home-monitor/hom-active changes refresh the bar. This is correct.
- **Orphaned/disconnected monitors.** Only realized (monitor-assigned) workspaces
  are projected (`workspaceManager.monitors` → `workspaces(on:)`), matching the
  sibling plan's `moveTargetItems` approach, so disconnected workspaces never
  appear.

## Follow-ups (out of scope)

- **Current-display-first ordering** of foreign pill groups.
- **Plain-click affordance** (e.g. tooltip "Switches display 2 to this
  workspace") if cross-display focus proves confusing.
- Coordinate with Nehir #62 ("Move Workspace to Monitor") — once that lands,
  a foreign pill could gain a "pull this workspace onto this display" action.
