# Right-click actions in the action bar

**Status:** planned
**Source discovery:** `discovery/20260621-right-click-actions-action-bar.md`
**Prerequisite:** the token-parameterized window-action family is delivered in
Phase 1 of this plan (co-designed with
`discovery/20260621-fix-target-window-toggle-floating-scratchpad.md`, backlog **#8**).
The **workspace-label** "Move Workspace to Monitor ▸" submenu additionally
depends on `planned/20260619-nehir-62-move-workspace-to-monitor.md` landing first.

**Related:** `planned/20260621-backlog-brainstorm.md` (canonical list; #18 is this
idea, siblings #2 / #7 / #8 / #16 / #24),
`discovery/20260621-fix-target-window-toggle-floating-scratchpad.md` (#8 — same
target-window seam),
`discovery/20260621-workspace-number-modifier-click-move-window.md` (#2 — shares
a possible `NSViewRepresentable` bridge),
`discovery/20260621-multiple-scratchpad-assignments.md` (#7 — scratchpad
single-slot constraint),
`discovery/20260621-nehir-93-vertical-workspace-bar.md` (workspace-bar file/line
map),
`planned/20260619-nehir-62-move-workspace-to-monitor.md` (#16 / Nehir #62 — the
workspace-to-monitor move command).

All source/line references were re-verified against the main Nehir source tree on
2026-06-22. Re-verify before editing; line numbers drift.

## TL;DR

The **workspace bar** (`Sources/Nehir/UI/WorkspaceBar/`) is left-click only today:
every pill is a SwiftUI `Button(action:)` or `.onTapGesture`, right-click is a
no-op, and only the menu-bar **status bar** handles right-click — and there it
just shows the same `NSMenu` as left-click. This plan adds a **secondary,
contextual right-click surface** to three pill types — **window icons,
scratchpad pill, and workspace labels** — so a user can act on a specific window
or workspace *without first focusing it and without remembering a hotkey*.

The cheap part is the menu UI: attach SwiftUI `.contextMenu(menuItems:)` (already
proven in-tree on settings `List`s) to each in-scope pill, wired through the
existing closure-to-controller seam in `WorkspaceBarManager.createBarForMonitor`.

The real work — and the gating prerequisite — is a **token-parameterized
window-action family** in `WMController`. Today the per-window actions a menu
would surface (`toggleFocusedWindowFloating`, `assignFocusedWindowToScratchpad`)
resolve their target internally from the *focused* window via
`focusedManagedTokenForCommand()`, so calling them from a right-click would act
on the focused window, not the clicked one (the #8 defect). The Overview already
proves token-targeted actions in-tree (`OverviewController.closeWindow(_:)`,
`selectAndActivateWindow(_:)`, `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)`);
this plan extends that precedent to floating/scratchpad/close/move and lands it
once for #18, #8, and #2.

Ship a **minimal, consistent item set**: window icon → *Toggle Floating, Assign
to / Unassign from Scratchpad, Move to Workspace ▸, Close*; scratchpad pill →
*Toggle Visible, Unassign, Focus*; workspace label → *Focus, Move Workspace to
Monitor ▸*. **Defer** fullscreen / column / sizing items (the Niri layout path
is selection-driven via `state.selectedNodeId` and cannot target an arbitrary
floating token) and menus on the three trailing action buttons
(trace/diagnostics/palette).

## Discovery corrections / decisions

The discovery recommendation is right at the product level. Correct the following
while porting:

1. **`.contextMenu` is already used in-tree — the "unproven" framing is
   overstated.** The discovery states `.contextMenu(` appears "nowhere in
   `Sources/Nehir/UI/`". That is no longer true: it is used on three settings
   `List`s — `Sources/Nehir/UI/WorkspacesSettingsTab.swift:66`,
   `Sources/Nehir/UI/AppRulesView.swift:31` and `:187` — each a
   `Button(role: .destructive) { Delete }` item. This **de-risks** the SwiftUI
   `.contextMenu` approach as the primary mechanism: it is a familiar, in-tree
   pattern. The residual, still-valid concern is narrower — *none* of those uses
   are on a `nonactivatingPanel` + `becomesKeyOnlyIfNeeded` floating panel, so
   the Phase 2 spike must still confirm `.contextMenu` tracks/dismisses correctly
   on the workspace bar's panel. Treat `NSMenu.popUp(positioning:at:in:)`
   (proven on the status bar) as the fallback for that edge only, not the
   default.
2. **Line-number drift corrected** (citations below use the verified 2026-06-22
   values): `WorkspaceBarView` click callbacks are at `:101-106` (discovery said
   `:100-105`); mirrored on `WorkspaceBarContentView` at `:145-150` (was
   `:144-149`); `WorkspaceBarWindowItem.id: WindowToken` is at `:30` (was
   `:31`); `StatusBarMenuBuilder` is at `Sources/Nehir/UI/StatusBar/StatusBarMenu.swift:22`
   (was `:44`); `WMCommandTarget.Source` cases
   (`layoutSelection`/`confirmedManagedFocus`/`frontmostManagedFallback`) are at
   `:10-12` (was `:9-13`); the `SurfaceCoordinator` `.workspaceBar` registration
   is `kind: .workspaceBar` at `:283`, `hitTestPolicy: .interactive` at `:284`
   (was `:280-287`).
3. **Own the token-parameterized refactor in this plan rather than treating #8
   as a hard external prerequisite.** #8 has a discovery doc but no plan yet.
   To keep this plan worker-ready and end-to-end shippable, Phase 1 *delivers*
   the token-parameterized family (co-reviewed with #8's discovery). #8 then
   consumes the same family to fix the focused path; #2 consumes the move
   variant and (optionally) the bridge view.
4. **Close routes through `WindowActionHandler`, not a new private copy.** Lift
   the Overview's private `closeWindowFromOverview(handle:)` to internal access
   and add a token-based entry, rather than duplicating the AX-close logic.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Controller/WMController.swift`
   - Add `toggleWindowFloating(token: WindowToken) -> ExternalCommandResult`:
     extract the body of `toggleFocusedWindowFloating()` (`:3562`) — entry
     lookup, `nextOverride` computation, and the
     `applyManagedWindowOverride(_:for:entry:)` call (`:3631`) — into a variant
     that takes the token explicitly. Refactor `toggleFocusedWindowFloating()`
     (`:3562`) to resolve `focusedManagedTokenForCommand()` (`:1806`) then
     delegate, so the hotkey path is unchanged.
   - Add `assignWindowToScratchpad(token:)` and
     `unassignWindowFromScratchpad(token:)`: split
     `assignFocusedWindowToScratchpad()` (`:3582`) along its existing branch —
     the `isScratchpadToken(token)` branch (cleanup +
     `applyManagedWindowOverride(.forceTile, ...)`) becomes the *unassign*
     variant; the else branch (single-slot collision handling +
     `applyManagedWindowOverride(.forceFloat, ...)`) becomes the *assign*
     variant. The focused wrapper resolves the token then routes to the right
     one. Honor the single-slot constraint (#7): when
     `workspaceManager.scratchpadToken()` is already occupied, the menu item is
     disabled/relabelled, not silently no-op'd.
   - Add `closeWindowFromBar(token: WindowToken) -> ExternalCommandResult`: thin
     entry point that resolves `WindowToken` → `WindowHandle` (same lookup the
     bar's `focusWindowFromBar(token:)` at `:729` uses) and delegates to the
     lifted `WindowActionHandler` close.
   - Add `moveWindowFromBar(token:toWorkspaceId:)`: thin wrapper over
     `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)` (`:885`),
     resolving token → handle as above.
   - **Do not** add `toggleFullscreen(token:)` here (deferred — see Non-goals).
2. `Sources/Nehir/Core/Controller/WindowActionHandler.swift`
   - Lift `closeWindowFromOverview(handle:)` (`:141`, currently `private`) to
     `internal` access (e.g. rename/expose as `closeWindow(handle:)`), keeping
     the Overview call site (`:76`) working. Add a token-based convenience if it
     keeps `WMController.closeWindowFromBar` trivial.
3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - Add right-click closures alongside the six left-click ones on
     `WorkspaceBarView` (`:101-106`) and `WorkspaceBarContentView` (`:145-150`):
     `onToggleWindowFloating: (WindowToken) -> Void`,
     `onToggleScratchpadAssignment: (WindowToken) -> Void`,
     `onCloseWindow: (WindowToken) -> Void`,
     `onMoveWindowToWorkspace: (WindowToken, WorkspaceDescriptor.ID) -> Void`
     (the submenu resolves the target id before calling), plus per-scratchpad
     (`onUnassignScratchpad`, `onToggleScratchpadVisible`, `onFocusScratchpad`)
     and per-workspace-label (`onMoveWorkspaceToMonitor`) closures. Thread
     no-op stubs through `WorkspaceBarMeasurementView` so it still compiles.
   - Attach `.contextMenu(menuItems:)` (primary mechanism) to `WindowIconView`
     (`:548`), `ScratchpadPillView` (`:452`), and `WorkspaceLabelButton`
     (`:371`), backed by the new closures. v1 item set:
     - **Window icon** → *Toggle Floating; Assign to Scratchpad / Unassign from
       Scratchpad (toggle label by `isScratchpadToken`); Move to Workspace ▸
       (submenu of other workspace ids on this monitor); Close*. (No fullscreen
       in v1.)
     - **Scratchpad pill** → *Toggle Visible; Unassign from Scratchpad; Focus*.
     - **Workspace label** → *Focus (same as left-click); Move Workspace to
       Monitor ▸* (only when the Nehir #62 command has landed; otherwise omit
       this item).
   - Update the per-pill `.help(...)` tooltips (`:396`, `:510`, `:610`) to
     mention right-click, e.g. window icon: *"Focus <app>. Right-click for more
     actions."* The `WorkspaceBarWindowItem.id: WindowToken` (`:30`) is the
     handle the token-parameterized actions take.
4. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`
   - Wire the new right-click closures in `createBarForMonitor` (`:222-237`,
     closures at `:222`-`:237`) to the new `WMController` entry points, mirroring
     the existing `[weak controller]` capture pattern.
5. `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`
   - Add a one-line discoverability hint next to the bar toggles (e.g. "Tip:
     right-click a window icon, the scratchpad, or a workspace for more
     actions."), mirroring the recommendation in the #2 triage.
6. Tests under `Tests/NehirTests/` (see **Tests**).

### Non-goals

- Do **not** invent new close/move/float semantics — those belong to #8 and the
  existing action catalog. Every menu item must map to an action Nehir can
  already perform.
- Do **not** add menus to the three trailing **action buttons**
  (`TraceCaptureBarButton` `:699`, `DisplayDiagnosticsBarButton` `:760`,
  `CommandPaletteBarButton` `:792`) — they are single-purpose; a menu there only
  duplicates the left-click.
- Do **not** ship a *Toggle Fullscreen* / column / sizing item in v1. The Niri
  layout path resolves from the viewport *selection*
  (`state.selectedNodeId`, e.g. `NiriLayoutEngine+ColumnOps.swift:596`) and
  cannot point at a floating window; offering it for a tiled target means first
  making that window the selection (a focus side-effect that surprises users who
  right-clicked *without* focusing). Defer until #8 decides the
  layout-command-vs-focus policy.
- Do **not** make right-click also focus the target window in v1 (act on the
  token, leave focus alone) — revisit if users expect menu-as-focus.
- Do **not** add a settings gate (`workspaceBarRightClickActions`) in v1 — always
  on; the panel is Nehir's own surface so there is no app-level right-click
  passthrough to collide with. Add a toggle only if field testing shows
  interference.
- Do **not** make the menu the primary interaction. Nehir is keyboard-first; this
  is a secondary mouse affordance (see backlog #24 for the design-principles
  gut-check).

## Exact implementation plan

Phased and ordered; each phase is independently reviewable. Phases 1 and 2 can
proceed in parallel (controller work does not block the menu-mechanism spike).

### Phase 1 — Token-parameterized action family (prerequisite, shared with #8)

Owner: `WMController` + `WindowActionHandler`. This is the load-bearing refactor;
without it the menu acts on the focused window, not the right-clicked one.

1. In `WindowActionHandler.swift`, lift `closeWindowFromOverview(handle:)`
   (`:141`) from `private` to `internal`. Keep the Overview call site (`:76`)
   compiling. Optionally add `closeWindow(token:)` that resolves the handle the
   same way `focusWindowFromBar(token:)` does.
2. In `WMController.swift`:
   - Extract `toggleWindowFloating(token:)` from `toggleFocusedWindowFloating()`
     (`:3562`); make the focused wrapper (`:3562`) resolve
     `focusedManagedTokenForCommand()` (`:1806`) then delegate.
   - Split `assignFocusedWindowToScratchpad()` (`:3582`) into
     `assignWindowToScratchpad(token:)` and `unassignWindowFromScratchpad(token:)`
     along the existing `isScratchpadToken` / else branch boundary; make the
     focused wrapper (`:3582`) route to the correct one.
   - Add `closeWindowFromBar(token:)` and `moveWindowFromBar(token:toWorkspaceId:)`
     thin wrappers (token → handle resolution, then delegate to the lifted close
     and to `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)`
     (`:885`) respectively).
3. Keep all return types `ExternalCommandResult`; the menu uses `.notFound` to
   disable items (e.g. occupied scratchpad slot, suspended-for-native-fullscreen
   token — see `isManagedWindowSuspendedForNativeFullscreen`).

### Phase 2 — Menu-mechanism spike (de-risk before wiring)

On a single pill (window icon) confirm the mechanism before fanning out.

1. Primary: attach a stub `.contextMenu { Button("Spike") { ... } }` to
   `WindowIconView` (`:548`) and right-click it on a live bar.
2. Confirm: the menu appears at the cursor; it tracks mouse movement and
   dismisses on select/outside-click; it does **not** steal app activation from
   the user's frontmost app (the panel is `nonactivatingPanel` +
   `becomesKeyOnlyIfNeeded`, `WorkspaceBarManager.swift:471,483`); it renders
   above the `isFloatingPanel` (`:481`) panel.
3. If `.contextMenu` fails any check, fall back to
   `NSMenu.popUp(positioning:at:in:)` via an `NSViewRepresentable` overriding
   `rightMouseDown` — the exact technique already proven on the status bar
   (`StatusBarController.swift:88,100-101,114,117`). That same bridge view can
   later be shared with #2's modifier-click (its "Option C"). Record the decision
   in the commit message.

### Phase 3 — Wire right-click closures through the view stack

1. Add the right-click closures to `WorkspaceBarView` (`:101-106`) and
   `WorkspaceBarContentView` (`:145-150`), and no-op stubs on
   `WorkspaceBarMeasurementView`.
2. Thread them through `WindowIconView` (`:548`), `ScratchpadPillView` (`:452`),
   and `WorkspaceLabelButton` (`:371`); attach `.contextMenu` (or the bridge
   view from Phase 2) with the v1 item set from **Scope**.
3. Wire the closures in `WorkspaceBarManager.createBarForMonitor` (`:222-237`)
   to the Phase 1 controller entry points, using `[weak controller]` capture as
   the existing closures do.
4. Multi-window app pill: when `windowCount > 1` (left-click opens
   `WindowListSheet` `:830`), right-click acts on that app's focused window and
   adds a *"Windows…"* item that opens the existing sheet (Open question 6).

### Phase 4 — Discoverability

1. Update `.help(...)` tooltips (`:396`, `:510`, `:610`) to mention right-click.
2. Add the one-line hint in `WorkspaceBarSettingsTab.swift`.

### Phase 5 — Tests

See **Tests**.

## Tests

### `Tests/NehirTests/` — token-target semantics (Phase 1)

Mirror the existing
`toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
assertion style (cited in the #8 triage). Add (new file or extend
`WMControllerTests`):

1. `toggleWindowFloatingActsOnExplicitTokenNotFocus` — focus window A, pass
   window B's token to `toggleWindowFloating(token:)`; assert B's override
   flips and A's is untouched.
2. `assignWindowToScratchpadActsOnExplicitToken` — pass a non-scratchpad token;
   assert that token becomes the scratchpad; focused window unchanged.
3. `unassignWindowFromScratchpadActsOnExplicitToken` — pass the stored
   scratchpad token; assert cleanup + `.forceTile` on that token only.
4. `assignWindowToScratchpadReturnsNotFoundWhenSlotOccupied` — single-slot
   collision (#7) returns `.notFound` so the menu item disables.
5. `closeWindowFromBarTargetsExplicitToken` — the passed token's AX close path
   is invoked, not the focused window's.
6. `moveWindowFromBarTargetsExplicitToken` — the passed token is moved to the
   target workspace via `moveWindow(handle:toWorkspaceId:)`.
7. No-regression: existing focused-window action tests stay green after the
   refactor (focused wrappers delegate to the same bodies).

### `Tests/NehirTests/` — bar wiring (Phase 3)

1. `WorkspaceBarManagerTests` (or a new view test): the right-click closures are
   wired in `createBarForMonitor` and, when invoked, call the corresponding
   controller entry point with the correct `WindowToken` (use a spy/test-only
   controller). Favour mechanism B's testability if `.contextMenu` proves hard
   to drive programmatically.
2. Assert the v1 item set is attached to window icon / scratchpad / workspace
   label and **not** to the three trailing action buttons.

## Validation

```bash
swift build
swift test --filter WMControllerTests
swift test --filter WindowActionHandlerTests
swift test --filter WorkspaceBarManagerTests
swift test --filter WorkspaceNavigationHandlerTests
```

Manual validation:

1. Focus window A; right-click window B's icon → *Toggle Floating*; confirm B
   (not A) toggles. Repeat for *Assign/Unassign Scratchpad*, *Close*, *Move to
   Workspace ▸*.
2. Right-click the scratchpad pill → *Toggle Visible / Unassign / Focus* each
   behave on the stored scratchpad token.
3. Right-click a workspace label → *Focus* equals left-click; *Move Workspace to
   Monitor ▸* appears only if Nehir #62 has landed.
4. Right-click a trailing action button → no menu (single-purpose).
5. Confirm right-click does not activate Nehir as the frontmost app (keep typing
   in the previously-focused app after dismissing the menu).
6. Confirm tooltips / settings hint mention right-click.

Changeset (minor): "Add right-click context menus to the workspace bar (window
icons, scratchpad, workspace labels) backed by token-parameterized window
actions."

## Risks and mitigations

- **Target-window seam (central risk).** Right-click targets a specific token;
  the existing per-window actions target focus. This is the same seam as #8 and
  #2. **Mitigation:** Phase 1 lands the token-parameterized family as a shared
  prerequisite; the focused wrappers and the right-click path (and the Overview's
  existing `closeWindow`/`moveWindow(handle:)`) all call the same bodies.
  Co-review Phase 1 against `discovery/20260621-fix-target-window-toggle-floating-scratchpad.md`.
- **`.contextMenu` on a non-activating floating panel.** De-risked by in-tree use
  on settings `List`s (`WorkspacesSettingsTab.swift:66`, `AppRulesView.swift:31,187`)
  but those are normal windows, not `nonactivatingPanel` + `becomesKeyOnlyIfNeeded`
  (`WorkspaceBarManager.swift:471,483`). **Mitigation:** Phase 2 spike on one
  pill; fall back to `NSMenu.popUp` (proven on the status bar,
  `StatusBarController.swift:114`) if it steals activation or renders wrong.
- **Layout actions cannot target an arbitrary token.** `toggleFullscreen`,
  column ops, sizing resolve from the Niri viewport selection
  (`state.selectedNodeId`) and cannot point at a floating window. **Mitigation:**
  ship a minimal item set; defer fullscreen/column until #8 sets the
  layout-command-vs-focus policy.
- **Scratchpad single-slot constraint (#7).** `assignWindowToScratchpad(token:)`
  must not silently no-op when `scratchpadToken()` is occupied. **Mitigation:**
  return `.notFound`; the menu disables or relabels the item ("Replace
  scratchpad").
- **Multi-window app pill ambiguity.** Left-click opens `WindowListSheet`
  (`:830`) when `windowCount > 1`. **Mitigation:** right-click acts on that app's
  focused window and offers *"Windows…"* to open the existing sheet (Open
  question 6).
- **Close semantics inherit app behavior.** `closeWindowFromOverview` presses the
  AX close button (`WindowActionHandler.swift:141`); apps with unsaved changes or
  close-to-tray may intercept. **Mitigation:** the item is labelled *Close*
  (matching the Overview), not "Force close".
- **Scope creep.** Tempting to menu-ify the trailing buttons or add fullscreen.
  **Mitigation:** explicitly scoped to three pill types and the minimal item set.
- **Discoverability.** No visible affordance (same as #2). **Mitigation:**
  Phase 4 tooltips + settings hint.
- **Design-philosophy fit.** Nehir is keyboard-first; right-click is a mouse
  power-user affordance (backlog #24's gut-check). Not a blocker — the status
  bar already exposes a mouse menu — but worth a maintainer nod.

## Follow-ups (out of scope)

- `toggleFullscreen(token:)` / column / sizing menu items — once #8 decides the
  layout-command-vs-focus policy and the token-targeted layout work lands.
- Menus on the three trailing action buttons (deliberately excluded).
- A `workspaceBarRightClickActions` settings gate, only if field testing shows
  interference.
- Share the `NSViewRepresentable` bridge view with #2's modifier-click move if
  Phase 2 falls back to `NSMenu.popUp`.
- Let #8 consume the Phase 1 token family to fix the focused-window defect, and
  #2 consume `moveWindowFromBar` / the shared bridge.
