# Reveal Style + Viewport Scroll Lock: redesign of Reveal Partial

**Status:** completed / landed, 2026-07-02.

**Implementation branch:** `planned/20260702-reveal-style-scroll-lock-redesign`
(final reviewed branch head before landing: `833a880a`).

**Validation at completion:** `swift build`, `git diff --check`, and
`mise run test` passed (`1382` tests in `114` suites). Runtime acceptance was
confirmed before completion.

The historical plan below records the original design plus amendments made during
implementation and review. When an older task bullet conflicts with
[Actual implementation shipped](#actual-implementation-shipped), the shipped
behavior section is authoritative.

## Actual implementation shipped

The landed implementation shipped these final semantics and surfaces:

- `RevealPartial` was replaced with `RevealStyle` (`auto | closest | center`) and
  TOML key `revealStyle`.
- Existing `revealPartial` configs are handled by a soft migration instead of a
  hard break: `[niri].revealPartial` is detected, a timestamped backup is
  written, the old key is removed, and `revealStyle` is populated when the new
  key is absent. Mapping: `snapClosest → closest`, `snapCenter → center`,
  `default/off → auto`. The migration parser recognizes both double-quoted TOML
  basic strings and single-quoted TOML literal strings. Diagnostics report the
  soft migration instead of a duplicate unknown-key warning.
- `ViewportState.isScrollLocked` is a per-workspace runtime flag. It is toggled
  through the hotkey/action path, command palette, IPC, and the optional
  Workspace Bar scroll-lock button.
- Reveal calls are classified with `RevealTrigger`: `.automatic` respects scroll
  lock, while `.explicitNavigation` bypasses it. Direct user navigation (focus
  hotkeys, workspace-bar window clicks, explicit focus commands / IPC focus)
  still reveals while locked; background automatic reveals do not.
- FFM still never scrolls the viewport.
- A fully visible target is not treated as reveal work. However, the landed engine
  keeps the previously shipped filling-group / proportional-slack centering
  maintenance path; that centering is viewport-position maintenance, not a
  target reveal, and is not the mechanism users use to expose hidden content.
- `WorkspaceManager.applySessionPatch` preserves the live `isScrollLocked` value
  so stale relayout-plan patches cannot silently revert a lock toggle.
- The Workspace Bar button uses the workspace the bar is actually showing
  (`activeWorkspaceOrFirst(on:)`) for both display and toggle state.
- The Workspace Bar scroll-lock button has a global setting and per-monitor
  override, matching the rest of the Workspace Bar override model.
- Both Workspace Bar preview surfaces reflect the setting: the setup wizard
  Workspace Bar page and Settings → Workspace Bar preview render the scroll-lock
  button when enabled.

## Overview

Replace the `Reveal Partial` setting (`default | off | snapClosest | snapCenter`) with a
predictable two-part model:

1. **Reveal Style** (`auto | closest | center`) — controls only **how** an automatic
   reveal positions the viewport. It never controls **whether** a reveal happens.
2. **Viewport Scroll Lock** — a new per-workspace runtime toggle (action + hotkey +
   IPC command + optional workspace bar button) that suppresses *background
   automatic* reveal scrolling on that workspace. This replaces the only
   legitimate use of the old `Off` value with an explicit, visible, per-workspace
   mode. *(Amended post-plan: direct user navigation bypasses the lock — see
   [Post-plan amendments](#post-plan-amendments-2026-07-02).)*

**Whether** rules become fixed and non-configurable:

- FFM (focus-follows-mouse) never scrolls the viewport.
- A fully visible target does not run target-reveal behavior; shipped
  filling-group/proportional-slack centering may still maintain viewport
  positioning when the visible group already fills the viewport.
- Scroll lock on → no reveal for `.automatic` triggers; `.explicitNavigation`
  triggers bypass the lock (see the trigger model below).
- Otherwise every non-FFM reveal trigger reveals clipped and parked targets using
  the configured style.

The TOML key, enum, setting name, and docs are all replaced. Final implementation
adds a soft migration for the old key rather than silently treating it as an
unknown field.

## Problem statement (source-backed)

The existing docs (`docs/viewport-navigation-spec.md` §Reveal on Focus,
`docs/glossary.md` §reveal) are **not** the golden source — code and docs disagree in
several places, and neither describes a coherent model. This plan's "New behavior
contract" section is the new source of truth; the docs get rewritten from it.

### The headline bug (user-reported)

Setting Reveal Partial to `Off` breaks hotkey-based focus navigation: pressing
focus-left/right onto a clipped column moves focus but does **not** scroll the
column into view.

Mechanism: keyboard/command paths funnel through
`NiriLayoutEngine.ensureSelectionVisible` (`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173`),
which calls `scrollToReveal` (`NiriNavigation.swift:228`). In `scrollToReveal`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`), the
clipped branch consults the setting and returns without scrolling for `.off`
(`NiriLayoutEngine+ViewportCommands.swift:133-134`).

The blast radius is much larger than focus hotkeys. `ensureSelectionVisible` — and
therefore the `revealPartial` gate — is on the path of essentially every explicit
command and structural layout change:

- Focus navigation: `NiriNavigation.swift:95, 228, 294, 319, 406, 544, 574, 638, 668`
- Column ops (move/consume/expel): `NiriLayoutEngine+ColumnOps.swift:204, 633, 882, 906`
- Interactive move: `NiriLayoutEngine+InteractiveMove.swift:230, 297`
- Interactive resize: `NiriLayoutEngine+InteractiveResize.swift:263`
- Width cycling / sizing: `NiriLayoutEngine+Sizing.swift:292` directly, plus the
  `ensureSelectionVisibleForPendingWidth` wrapper (defined `:278`, called `:265, 686`)
- Window insert/remove: `NiriLayoutEngine+Windows.swift:319, 506`
- Pure-layout bridge: `NiriLayoutEngine+PureLayoutBridge.swift:69`
- Relayout passes: `NiriLayoutHandler.swift:807, 952, 1375, 1427, 2120`
- Window actions: `WindowActionHandler.swift:469`
- Workspace navigation: `WorkspaceNavigationHandler.swift:118`

So a setting documented as "controls what happens when focus moves to a clipped
column" actually gates "keep the selection visible" for ~20 unrelated code paths.
The setting conflates *whether* to scroll with *how* to scroll and applies both
answers everywhere.

### Full current-behavior matrix (verified against source)

Two engine entry points exist:

**`scrollToReveal` (`NiriLayoutEngine+ViewportCommands.swift:70`)** — command/layout path:

| Target visibility | Setting | Actual behavior |
|---|---|---|
| any | FFM | no scroll (`:79`) |
| fully visible | non-`default` | no scroll (`:103-105`) |
| fully visible | `.default`, viewport filled | may re-center a filling group up to `2*gap` (`:106-121`) — **scrolls a fully visible target** |
| fully visible | `.default`, viewport not filled | `defaultSnap()` — may scroll to closest-filling or center snap (`:124`) |
| parked | `.default` | `defaultSnap()` = closest-if-fills else center (`:126-127`) |
| parked | non-`default` | closest snap (`:128`) — parked behavior **is** configurable |
| clipped | `.default` | `defaultSnap()` (`:131-132`) |
| clipped | `.off` | no scroll (`:133-134`) — the reported bug |
| clipped | `.snapClosest` | closest snap (`:135-136`) |
| clipped | `.snapCenter` | center snap, fallback closest (`:137-140`) |

**`revealForFocusActivation` (`NiriLayoutEngine+ViewportCommands.swift:160`)** — AX
click/external-activation path (`Sources/Nehir/Core/Controller/AXEventHandler.swift:2539`):

| Target visibility | Actual behavior |
|---|---|
| fully visible | never scrolls (`:175-176`) |
| parked | fixed default snap (closest-if-fills else center), **ignores the setting** (`:177-198`) |
| clipped | delegates to `scrollToReveal` (`:199-209`) |

Documented divergences this plan resolves:

- Spec says "Fully visible → No scroll" for any source
  (`docs/viewport-navigation-spec.md:162`); code scrolls under `.default` on the
  command path. The settings caption repeats the false claim
  (`Sources/Nehir/UI/BehaviorSettingsTab.swift:59`).
- Spec/glossary say parked targets always use the closest snap, "No configuration"
  (`docs/viewport-navigation-spec.md:163,180`, `docs/glossary.md:162`); code uses
  `defaultSnap()` under `.default` and diverges *between the two paths* for
  non-default settings.
- `Off` is documented as clipped-only, but its practical effect is disabling
  reveal for all command paths (the headline bug).

### Secondary issues folded into this redesign

- Silent decode fallback: `RevealPartial(rawValue:) ?? .default`
  (`Sources/Nehir/Core/Config/SettingsStore.swift:528`); the canonical config stores a
  free-form `String` (`Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift:107,655,666`).
- Footgun default parameter `enableNiriLayout(revealPartial: RevealPartial = .default)`
  (`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:2029`) silently resets the
  user preference if a future caller omits the argument.
- Test suite asserts the old accidental behavior against parked targets and admits
  uncertainty ("Check the actual behavior", conditional `#expect`) —
  `Tests/NehirTests/ViewportSnapContextTests.swift:527-734`. A second test surface pins
  the old policy on the AX path:
  `Tests/NehirTests/AXEventHandlerTests.swift:1234`
  (`focusConfirmationHonorsRevealPartialPolicyIdenticallyForSettledSpringAndStatic`),
  and the canonical TOML fixture carries the old key:
  `Tests/NehirTests/Fixtures/canonical-settings.toml:59` (`revealPartial = "default"`).

## New behavior contract (golden source going forward)

### Reveal Style (global setting)

`RevealStyle: auto | closest | center` — default `auto`.

Controls **how** every automatic reveal positions the viewport. Applies uniformly:

- to clipped **and** parked targets (user decision: uniform style, no parked
  special-casing),
- to every trigger class (hotkey commands, click activation, external raise),
- on every workspace.

Definitions (all via the shared snap geometry in
`Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift` — `snapCandidates(for:in:)`
`:98`, `fillsViewport(at:in:)` `:143`):

- **`closest`** — the target column's snap candidate nearest to the current view
  start. Minimal scroll.
- **`center`** — the target column's center snap; fallback to closest when no
  center snap exists (columns ≤ 30% of viewport width get no center snap,
  `ViewportState+Geometry.swift:127`).
- **`auto`** — closest snap when the resulting viewport is filled by a contiguous
  group of fully visible columns within the `2 * gap` tolerance
  (current `defaultSnap()` heuristic, `NiriLayoutEngine+ViewportCommands.swift:90-98`);
  otherwise center (fallback closest).

### Whether rules (fixed, not configurable)

Every reveal call site classifies itself with a **`RevealTrigger`** (amended
post-plan; replaces an earlier `respectScrollLock: Bool` passthrough):

- **`.explicitNavigation`** — the user directly navigated to a target: focus
  hotkeys, workspace-bar window clicks, explicit focus commands / IPC focus.
- **`.automatic`** — everything else the layout does on its own behalf:
  relayout passes, structural ops (move/consume/expel, sizing, window
  insert/remove), and AX focus confirmations (clicking the window itself,
  cmd-tab / dock / external raises).

| Condition | Reveal? |
|---|---|
| FFM focus change | never |
| Target fully visible | no target reveal; filling-group/proportional-slack centering maintenance may still run |
| Workspace scroll lock ON + `.automatic` trigger | never |
| Workspace scroll lock ON + `.explicitNavigation` trigger | yes, using Reveal Style |
| Lock off, any non-FFM trigger, clipped or parked target | yes, using Reveal Style |

The lock decision lives in exactly one place — the gate inside the unified
`scrollToReveal` switching on the trigger — never at call sites.

Consequences:

- `revealForFocusActivation` loses its reason to exist: with "fully visible →
  never" and uniform parked handling, its behavior becomes identical to the
  unified `scrollToReveal`. It is deleted; the AX path calls the unified function.
- The old fully-visible re-centering behavior is retained only as
  viewport-position maintenance for filling groups / proportional slack. It is
  not treated as a target reveal and does not decide whether hidden content is
  exposed.
- The anchor-preserving rebase inside `ensureSelectionVisible`
  (`NiriNavigation.swift:206-225`) stays — it produces no visible motion and is
  required bookkeeping regardless of lock state.

### Viewport Scroll Lock (new)

Per-workspace runtime flag, default **off**, stored in `ViewportState`
(`Sources/Nehir/Core/Layout/Niri/ViewportState.swift:166` — alongside runtime fields
like `pendingFFMFocusToken` `:196`). Persisted with the workspace session patches the
same way other `ViewportState` fields already flow
(`AXEventHandler.swift:2422` reads via `workspaceManager.niriViewportState(for:)`,
`:2568` writes via `applySessionPatch`).

Semantics (amended post-plan — see
[Post-plan amendments](#post-plan-amendments-2026-07-02)):

- Suppresses **background automatic** reveals only: the unified `scrollToReveal`
  returns `false` when the workspace is locked *and* the trigger is `.automatic`.
- Does **not** suppress direct user navigation (`.explicitNavigation`): focus
  hotkeys, workspace-bar window clicks, and explicit focus commands / IPC focus
  still reveal while locked, and do not auto-unlock.
- Does **not** suppress explicit viewport manipulation: `scrollViewport(.left/.right)`
  commands, trackpad scroll gestures, and interactive drags keep working while
  locked, and do not auto-unlock.
- Deliberate consequence: while locked, clicking a clipped window's **workspace-bar
  icon** reveals it (`.explicitNavigation`), but clicking the **window itself** or
  cmd-tab/external-raising it does not (AX confirmation = `.automatic`). Focus may
  therefore land on a clipped/parked window while locked; that is the lock working
  as intended.
- Patch-application safety: live `isScrollLocked` is preserved when session
  patches built from older viewport snapshots are applied, so an in-flight
  relayout plan cannot revert a lock toggle.

Surfaces:

- **Action / hotkey**: new `HotkeyCommand` case + `ActionCatalog` entry
  (unassigned default binding, category `.layout`) + `CommandHandler` dispatch,
  following the `scrollViewportLeft` pattern
  (`Sources/Nehir/Core/Input/HotkeyCommand.swift:53`,
  `Sources/Nehir/Core/Input/ActionCatalog.swift:278-292`,
  `Sources/Nehir/Core/Controller/CommandHandler.swift:139-142`,
  `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift:119`).
- **IPC**: new command (e.g. `toggle-viewport-lock`) following the
  `scroll-viewport-left` pattern (`Sources/NehirIPC/IPCModels.swift:235` and the
  mapping sites at `:372, :472, :701, :985, :1176`;
  `Sources/NehirIPC/IPCAutomationManifest.swift:489`;
  `Sources/Nehir/IPC/IPCCommandRouter.swift:56`).
- **Workspace bar button** (optional, gated by a new settings toggle): follows the
  `CommandPaletteBarButton` pattern
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:1049`), with the settings
  toggle following `workspaceBarShowTraceButton`
  (`Sources/Nehir/Core/Config/SettingsStore.swift:179, 464, 553`). The button shows
  and toggles the lock state of the workspace the bar instance belongs to
  (locked: `lock.fill`, unlocked: hidden or `lock.open` — see Open decisions).

### Settings / config surface

- `RevealPartial` enum (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:10-28`)
  is replaced by `RevealStyle` (`auto | closest | center`, default `auto`).
- TOML key `revealPartial` is replaced by `revealStyle`. Final implementation
  ships a soft migration for existing configs: the old key is detected under
  `[niri]`, a timestamped backup is written, the old key is removed, and
  `revealStyle` is populated when it was not already present.
- Settings UI picker becomes "Reveal Style" with an accurate caption
  (`BehaviorSettingsTab.swift:50-60`); new caption states: the style controls
  where clipped/offscreen targets land; fully visible targets are not revealed,
  though viewport-position maintenance can still run; the scroll lock suppresses
  background automatic reveal scrolling.
- `enableNiriLayout` loses its defaulted parameter — `revealStyle` becomes a
  required argument (`NiriLayoutHandler.swift:2029`,
  `Sources/Nehir/Core/Controller/WMController.swift:408, 1122, 3483`).

## Context (from discovery)

- Engine policy + entry points: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`,
  `NiriLayoutEngine+ViewportCommands.swift`, `NiriNavigation.swift`
- Shared snap geometry: `Sources/Nehir/Core/Layout/Niri/ViewportState+Geometry.swift`
  (implementation contract per `docs/viewport-navigation-spec.md:129` still holds:
  no local snap formulas)
- AX activation path: `Sources/Nehir/Core/Controller/AXEventHandler.swift:2502-2567`
  (including trace fields naming `revealPartial` at `:2529`)
- Config plumbing: `SettingsStore.swift`, `SettingsExport.swift`,
  `CanonicalTOMLConfig.swift`, `WMController.swift:395-425, 3470-3495`,
  `NiriLayoutHandler.swift:2029-2096`
- Command/IPC plumbing patterns: `HotkeyCommand.swift`, `ActionCatalog.swift`,
  `CommandHandler.swift`, `HotkeyConfigMapping.swift`, `IPCModels.swift`,
  `IPCAutomationManifest.swift`, `IPCCommandRouter.swift`
- Workspace bar: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`,
  `WorkspaceBarDataSource.swift`, `WorkspaceBarManager.swift`
- Existing tests touching the area: `Tests/NehirTests/ViewportSnapContextTests.swift`
  (ScrollToRevealTests, `:527-727`), `Tests/NehirTests/SettingsStoreTests.swift`,
  `Tests/NehirTests/SettingsViewTests.swift`

## Development approach

- Verification model (user decision): **acceptance is manual user testing** against
  the checklist in Post-Completion. Automated tests are maintained only to the
  extent needed to keep `swift test` green — existing tests asserting the old
  matrix are rewritten to the new contract, not preserved.
- Complete each task fully before moving to the next; keep `swift build` and
  `swift test` green at every task boundary.
- Update this plan file when scope changes during implementation (➕ for new
  tasks, ⚠️ for blockers, `[x]` immediately on completion).
- No backward compatibility shims anywhere (explicit user decision).

## Implementation steps

> Historical note: the task breakdown below was written against the original
> contract. Implementation followed the amended trigger model
> (`RevealTrigger` instead of a lock check keyed only on `state.isScrollLocked`)
> — see [Post-plan amendments](#post-plan-amendments-2026-07-02). Where a task
> bullet and the amendments disagree, the amendments win.

### Task 1: Unify the engine reveal path around the new contract (atomic type rename)

The `RevealPartial` → `RevealStyle` type-and-case rename is compile-atomic: every
consumer of the type or its cases must change in this task or the build cannot be
green at the task boundary. Task 2 is limited to surfaces that are *not*
compile-coupled to the type (persistence key strings, signatures, UI copy).

**Files:**
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`
- Modify: `Sources/Nehir/Core/Layout/Niri/ViewportState.swift`
- Modify: `Sources/Nehir/Core/Controller/AXEventHandler.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift` (type/case references only)
- Modify: `Sources/Nehir/Core/Controller/WMController.swift` (type references only)
- Modify: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` (type references only)
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift` (type/case references only)
- Modify: `Tests/NehirTests/ViewportSnapContextTests.swift`
- Modify: `Tests/NehirTests/AXEventHandlerTests.swift`

- [x] replace `RevealPartial` with `RevealStyle` (`auto | closest | center`,
      `CaseIterable`, `Codable`, default `auto`) in `NiriLayoutEngine.swift:10-28`;
      rename the engine property (`:158`) and the `updateConfiguration(revealPartial:)`
      parameter label (`:376-388` — note: this is `updateConfiguration`, not an init)
- [x] update all compile-time consumers of the type/cases in the same change:
      `SettingsStore.swift:104-106, 449, 528` (type name, `.default` → `.auto`
      fallback), `WMController.swift:408, 413, 1122, 1133, 1141, 3483, 3487`,
      `NiriLayoutHandler.swift:2029, 2032, 2080, 2089`,
      `BehaviorSettingsTab.swift:50-56` (`RevealStyle.allCases`; caption text deferred
      to Task 2)
- [x] add `var isScrollLocked = false` to `ViewportState` (`ViewportState.swift:182` area)
- [x] rewrite `scrollToReveal` (`NiriLayoutEngine+ViewportCommands.swift:70-150`) to the
      new matrix: FFM → false; lock-gated automatic reveals; fully visible → no
      target reveal while preserving filling-group centering maintenance; clipped
      and parked → identical snap selection by style (`closest` /
      `center`-fallback-closest / `auto` = existing `defaultSnap()` heuristic)
- [x] delete `revealForFocusActivation` (`:152-210`); switch the AX call site
      (`AXEventHandler.swift:2539`) to the unified `scrollToReveal`
- [x] update AX trace fields that name the old setting
      (`AXEventHandler.swift:2529` `revealPartial=` → `revealStyle=` + `locked=`)
      and the comment at `:2450`
- [x] rewrite `ScrollToRevealTests` (`Tests/NehirTests/ViewportSnapContextTests.swift:527-734`)
      to pin the new matrix with clipped **and** parked targets per style, plus:
      fully-visible-never-scrolls, FFM-never-scrolls, locked-never-scrolls
- [x] rewrite or delete
      `focusConfirmationHonorsRevealPartialPolicyIdenticallyForSettledSpringAndStatic`
      (`Tests/NehirTests/AXEventHandlerTests.swift:1234`) against the unified path
- [x] `swift build && swift test` green

### Task 2: Persistence key, signatures, and UI copy

**Files:**
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: `Sources/Nehir/Core/Controller/WMController.swift`
- Modify: `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`
- Modify: `Sources/Nehir/UI/BehaviorSettingsTab.swift`
- Modify: `Tests/NehirTests/Fixtures/canonical-settings.toml`

- [x] rename the stored property and export field (`SettingsStore.swift:104-106, 449, 528`;
      `SettingsExport.swift:36, 131`) to `revealStyle`; replace the active
      `revealPartial` TOML key and add a soft migration for existing configs
- [x] update the fixture `Tests/NehirTests/Fixtures/canonical-settings.toml:59`
      (`revealPartial = "default"` → `revealStyle = "auto"`)
- [x] make `revealStyle` a required parameter of `enableNiriLayout`
      (`NiriLayoutHandler.swift:2029`, `WMController.swift:1122`) and thread it through
      the apply paths (`WMController.swift:408-417, 3483-3492`); keep `updateNiriConfig`
      optional-parameter semantics (`NiriLayoutHandler.swift:2077-2096`)
- [x] update the Behavior settings picker copy (`BehaviorSettingsTab.swift:50-60`):
      title "Reveal Style", per-option display names, caption matching the new contract
- [x] update `SettingsStoreTests` for the renamed key; grep the repo for remaining
      `revealPartial` / `RevealPartial` and remove them (`SettingsViewTests` has no
      reference to the old name — verified; re-check anyway during the grep)
- [x] `swift build && swift test` green

### Task 3: Scroll lock action, hotkey, and IPC command

**Files:**
- Modify: `Sources/Nehir/Core/Input/HotkeyCommand.swift`
- Modify: `Sources/Nehir/Core/Input/ActionCatalog.swift`
- Modify: `Sources/Nehir/Core/Config/HotkeyConfigMapping.swift`
- Modify: `Sources/Nehir/Core/Controller/CommandHandler.swift`
- Modify: (layout coordinator / controller surface reached from `CommandHandler`, e.g.
  the `layoutCoordinator.scrollViewport` peer — exact file resolved during
  implementation)
- Modify: `Sources/NehirIPC/IPCModels.swift`
- Modify: `Sources/NehirIPC/IPCAutomationManifest.swift`
- Modify: `Sources/Nehir/IPC/IPCCommandRouter.swift`

- [x] add `toggleViewportScrollLock` `HotkeyCommand` case (`HotkeyCommand.swift:53` area)
      and dispatch in `CommandHandler` (`CommandHandler.swift:139` area) toggling
      `ViewportState.isScrollLocked` for the currently focused workspace and
      requesting a workspace-bar refresh
- [x] add `ActionCatalog` entry (category `.layout`, unassigned binding, display name
      "Toggle Viewport Scroll Lock", keywords "lock", "pin", "freeze viewport" —
      `ActionCatalog.swift:278-292, 922, 996` patterns) and the
      `HotkeyConfigMapping` row (`HotkeyConfigMapping.swift:119` pattern)
- [x] add IPC command `toggle-viewport-lock` across `IPCModels.swift`
      (`:235, :372, :472, :701, :985, :1176` mapping sites),
      `IPCAutomationManifest.swift` (`:489` pattern), and route it in
      `IPCCommandRouter.swift` (`:56` pattern)
- [x] extend `IPCCommandRouterTests` with the new command routing case (keep suite green)
- [x] `swift build && swift test` green

### Task 4: Workspace bar lock button + settings toggle

**Files:**
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarDataSource.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsStore.swift`
- Modify: `Sources/Nehir/Core/Config/SettingsExport.swift`
- Modify: `Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift`
- Modify: (workspace bar settings tab hosting the existing bar toggles)

- [x] add `workspaceBarShowScrollLockButton` setting following the
      `workspaceBarShowTraceButton` plumbing (`SettingsStore.swift:179, 464, 553`,
      plus export/TOML fields), default off
- [x] expose the focused workspace's `isScrollLocked` through
      `WorkspaceBarDataSource` and render a `ScrollLockBarButton` following
      `CommandPaletteBarButton` (`WorkspaceBarView.swift:1049-1080`): SF Symbol
      reflects state, click toggles via the same controller path as the hotkey
- [x] ensure lock toggles refresh the bar (same refresh route the trace button uses)
- [x] update settings UI with the new toggle + caption
- [x] `swift build && swift test` green

### Task 5: Rewrite the spec and glossary from the new contract

**Files:**
- Modify: `docs/viewport-navigation-spec.md`
- Modify: `docs/glossary.md`

- [x] replace §Settings row and §Reveal on Focus (`viewport-navigation-spec.md:70, 156-183`)
      with the new contract: fixed whether-rules table, Reveal Style definitions,
      scroll-lock semantics; regenerate the worked use-cases (`:196-234`) for the
      three styles; delete the parked "No configuration" special case
- [x] update `docs/glossary.md` §reveal (`:157-166`) and the FFM entry (`:82`);
      add a "viewport scroll lock" entry
- [x] sweep both docs for remaining `revealPartial` / "Reveal Partial" references
      (`glossary.md:153`, `viewport-navigation-spec.md:91, 129`)

### Task 6: Verify acceptance criteria

- [x] grep repo-wide: zero remaining `revealPartial` / `RevealPartial` /
      `revealForFocusActivation` references
- [x] full suite: `swift test` green
- [x] walk the manual acceptance checklist below with the user; record outcomes here
- [x] move this plan to `completed/` on the plans branch once accepted

## Post-Completion — manual acceptance checklist (primary verification)

Layouts: use 3–4 columns sized so one is clipped and one parked (e.g. 40% + 40% +
40% + 40% on one monitor).

Whether-rules (style = any; workspace unlocked):
- Hotkey focus onto a clipped column scrolls it fully into view — **with every
  style, including after switching styles live in Settings** (this was the
  reported bug).
- Hotkey focus onto a parked column scrolls it into view; landing position matches
  the configured style, and is identical whether reached by hotkey or by clicking
  its dock/app icon (external raise).
- Focusing an already fully visible column does not reveal hidden content;
  filling-group/proportional-slack centering maintenance may still correct the
  viewport when applicable.
- FFM focus over a clipped column never scrolls.
- Move-column / resize / width-preset commands keep the selection visible.

Styles (clipped and parked targets, both directions):
- `closest`: minimal scroll; target ends flush at the near viewport edge.
- `center`: target ends centered; narrow (≤30% viewport) columns fall back to closest.
- `auto`: closest when the result is a filled viewport (e.g. 50%+50%), center
  otherwise (e.g. 65%+50%).

Scroll lock (amended semantics — lock blocks `.automatic` triggers only):
- Toggle via hotkey, command palette, IPC (`nehir` CLI), and bar button — all four
  agree on state; bar button reflects it.
- While locked, `.explicitNavigation` still reveals: focus hotkeys onto a clipped
  or parked column scroll it into view; clicking a window's workspace-bar icon
  scrolls it into view.
- While locked, `.automatic` does not reveal: clicking the window itself,
  cmd-tab / dock / external raises, relayout passes, and structural ops
  (move-column, consume/expel, width presets, interactive resize) leave the
  viewport put — verify move-column-offscreen specifically, and verify the
  bar-icon-click vs window-click asymmetry is the intended experience.
- Manual viewport movement unaffected: trackpad gestures and `scrollViewport`
  hotkeys work while locked and do not auto-unlock.
- Lock is per-workspace: locking workspace A does not affect workspace B.
- Unlocking does not itself scroll; the next reveal trigger behaves normally.
- Toggle the lock while a relayout is in flight (e.g. immediately after closing a
  window): the lock state must not silently revert (stale-patch preservation).

Config:
- `revealStyle = "closest"` in TOML round-trips through Settings export/import;
  an old config containing `revealPartial` is soft-migrated with a backup and
  mapped to the equivalent `revealStyle` value (`off`/`default` map to `auto`).

## Open decisions — resolutions

1. **Lock persistence across app restart** — shipped without a durable TOML
   setting. The flag remains runtime/session viewport state rather than a user
   configuration preference.
2. **Bar button when unlocked** — resolved as recommended: always visible when the
   settings toggle is on; `lock.open` at secondary opacity when unlocked,
   `lock.fill` + accent tint when locked.
3. **Naming** — resolved: `RevealStyle` / "Reveal Style", "Viewport Scroll Lock",
   and `RevealTrigger` (`.automatic` / `.explicitNavigation`).
4. **Whether structural ops should respect the lock** — resolved: yes; they
   classify as `.automatic` under the trigger model, so the single gate inside
   `scrollToReveal` covers them.

## Post-plan amendments (2026-07-02)

Decisions changed during implementation and code review. The contract sections
above already incorporate them; this section records what changed and why.

1. **Lock scope narrowed to background automatic reveals.** The original contract
   blocked *all* automatic reveals while locked, including focus hotkeys and
   bar clicks ("focus hotkeys move focus but the viewport stays put"). During
   acceptance testing, a locked workspace-bar click that focused an offscreen
   window without revealing it felt misleading. Amended model: direct user
   navigation (`.explicitNavigation` — focus hotkeys, bar window clicks, explicit
   focus commands / IPC focus) reveals while locked; only `.automatic` triggers
   are suppressed. The user's original `Off` complaint stays structurally solved:
   no configuration can ever stop explicit navigation from revealing.
2. **`RevealTrigger` replaces the `respectScrollLock: Bool` passthrough.** The
   first implementation threaded a defaulted boolean to ~10 call sites, which
   drifted (focus commands bypassed the lock while equally explicit move-column
   commands respected it, with no stated rule). Review flagged it; reworked to a
   required trigger enum classified at each call site with the lock decision made
   once inside `scrollToReveal`.
3. **AX focus confirmations are `.automatic`.** Clicking a clipped window directly
   or raising it via cmd-tab/dock does not reveal while locked, while the same
   window's bar icon does. Accepted asymmetry: the clicked window is already
   visible enough to click, and external raises are precisely the background
   disturbance the lock exists to stop. Called out in the acceptance checklist.
4. **Bar button setting is global + per-monitor override.** The review argued for
   global-only; kept the per-monitor override because every other workspace-bar
   toggle (labels, floating windows, grouping, hide-empty, trace button) is
   per-monitor overridable, and a global toggle was added so nobody is forced
   into per-monitor settings. Consistency beats minimalism here.
5. **Changeset level is `minor`.** New user-facing feature plus the
   `revealPartial` → `revealStyle` TOML rename without migration; project is
   pre-1.0, so the incompatible rename does not force `major`.
6. **Stale-patch lock preservation.** Review found `applySessionPatch` could write
   back a pre-toggle `isScrollLocked` from an in-flight relayout snapshot;
   fixed by preserving live lock state during patch application (now part of the
   contract above).

7. **Fully-visible centering carve-out restored.** Review and full-suite testing
   showed the removed re-centering branch was load-bearing for proportional-slack
   centering, always-center-single-column behavior, full-width round trips, and
   move-column viewport preservation. Final contract: this is
   viewport-position maintenance, not a reveal decision.
8. **Soft migration shipped.** The initial no-compatibility plan was revised to a
   user-safe migration: old `revealPartial` values are rewritten to `revealStyle`
   with a backup, unknown-key diagnostics are deduped, and TOML literal strings
   such as `revealPartial = 'snapCenter'` are recognized.
9. **Onboarding and settings previews updated.** The Workspace Bar setup wizard
   and Settings → Workspace Bar preview both show the scroll-lock button when
   the setting is enabled, so preview and control surfaces stay in sync.

Deferred follow-ups (accepted, not yet done):

- Rework the reveal-style engine tests whose expected-offset oracle mirrors the
  production snap-selection switch (tautological); gated on the project rule of
  confirming runtime behavior before rewriting tests.
- Extract a shared workspace-bar icon-button component
  (`ScrollLockBarButton` is the third copy of the same chrome).
