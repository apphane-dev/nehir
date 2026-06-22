# Modifier + click on a workspace number to move the active window/column

**Status:** planned
**Source discovery:** `discovery/20260621-workspace-number-modifier-click-move-window.md`
**Origin:** backlog brainstorm idea **#2** (`planned/20260621-backlog-brainstorm.md`, *Workspaces / window management*)

All file/line references were re-verified against the main Nehir source tree on
2026-06-22. Re-verify before editing; line numbers drift.

## TL;DR

Today a click on a workspace pill always **focuses** that workspace — the mouse
analogue of `Opt+Cmd+N`. Nehir already ships, end-to-end, a "move focused
**window** to workspace N" command (`Opt+Shift+N` → `HotkeyCommand.moveToWorkspace(_)`
→ `WorkspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID:)`), including
the target-viewport reveal landed in
`completed/20260619-moved-window-inactive-target-viewport.md`. The only thing
missing is *invoking it from a pill click instead of a key press*.

The click seam already exists: every pill routes to one callback,
`onFocusWorkspace: (WorkspaceBarItem) -> Void`, wired at
`WorkspaceBarManager.swift:222-224`, which today unconditionally calls
`controller.focusWorkspaceFromBar(id: item.id)`. **Shift is already Nehir's
"move" differentiator** (`ActionCatalog.swift` digit bindings: `Opt+Cmd` = focus,
`Opt+Shift` = move window), so **`Shift+click` = move focused window** is the
exact mouse analogue of `Opt+Shift+N`.

This plan delivers **v1 = Shift+click on a workspace pill moves the focused
window to that workspace**. It is a ~15-line, fully-additive change: branch the
existing callback on the held modifier, add one delegating controller method,
add a testable modifier→intent resolver, and update one tooltip. It reuses 100%
of the existing move pipeline (entry point, target-viewport reveal,
`focusFollowsWindowToMonitor` policy). The **column** variant
(`moveFocusedColumnFromBar`) is explicitly deferred — see "Discovery corrections
/ decisions" for why it does **not** inherit the same behaviors for free.

## Discovery corrections / decisions

The discovery's product verdict (🟢 pursue; v1 = Shift+click moves the focused
window) stands. Correct these source-level details while implementing:

1. **`WMController` target-token line drift.** `managedCommandTargetToken()` is
   at `Sources/Nehir/Core/Controller/WMController.swift:1798` (discovery said
   `:1792`); `managedLayoutCommandTargetToken()` is at `:1802` (discovery said
   `:1796`). These are the "active window" / "active column" resolvers used by
   the move entry points.

2. **The column-move path does NOT inherit the target-viewport reveal or the
   focus-follows policy (bounds the deferred column variant).** The discovery
   claims "Both entry points already call `prepareMovedWindowTargetViewport(...)`
   (`WorkspaceNavigationHandler.swift:844` and `:869`)" and "They also honor
   `settings.focusFollowsWindowToMonitor`." Verified against source, this is only
   true for the **window** path:
   - `WorkspaceNavigationHandler.swift:844` and `:869` are **both inside**
     `moveFocusedWindow(toRawWorkspaceID:)` (`:814`) — `:844` in the
     `focusFollowsWindowToMonitor == true` branch, `:869` in the `else` branch.
     The window path calls `prepareMovedWindowTargetViewport(token:workspaceId:)`
     in **both** branches and branches on the setting. ✓
   - `moveColumnToWorkspace(rawWorkspaceID:)` (`:745`) calls **neither**. It uses
     `saveNiriViewportState` + `applySessionTransfer` + `recoverSourceFocusAfterMove`
     and resolves focus on the **source** workspace
     (`resolveAndSetWorkspaceFocusToken(for: wsId)` where `wsId` is the source),
     and never reads `focusFollowsWindowToMonitor`.
   - **Impact on v1: none** — v1 is window-move only and inherits both behaviors
     exactly as the discovery claims. The correction only bounds the deferred
     column variant: a future `moveFocusedColumnFromBar` would *not* get the
     target-viewport reveal or the focus-follows toggle for free, and would need
     its own viewport/focus decision if/when pursued.

3. **`NSEvent.modifierFlags` precedent (Step 2, Option A) is mis-cited.** The
   discovery cites `Sources/Nehir/UI/KeyRecorderView.swift` and
   `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift` as precedent for
   reading `NSEvent.modifierFlags` synchronously. They are not — both use
   `NSEvent.addLocalMonitorForEvents(...)` (the local-monitor pattern, i.e. the
   discovery's own Option B): `KeyRecorderView.swift:107`,
   `InteractiveMoveDemo.swift:743`. The actual in-tree precedent for a
   synchronous `NSEvent.modifierFlags` read is
   `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift:86`
   (`MouseEventHandler.cgEventFlags(from: NSEvent.modifierFlags)`). The Option B
   monitor the discovery cites at `OverviewController.swift:739` is at `:24`.

4. **`WorkspaceManager` lives under `Core/Workspace/`, not `Core/Controller/`.**
   The resolver used by the new controller method —
   `WorkspaceManager.descriptor(for:)` (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2302`,
   returns `WorkspaceDescriptor?` whose `.name` is the raw workspace name at
   `:14`) and `workspaceId(for:createIfMissing:)` (`:2306`) — is at that path.

5. **Decision — resolve the target by workspace `id` (consistent with the
   existing bar seam), not by threading `item.rawName`.** The existing
   `focusWorkspaceFromBar(id:)` takes a `WorkspaceDescriptor.ID`, so the new move
   sibling takes the same `id` and resolves the raw name internally via
   `descriptor(for:)?.name`. `WorkspaceBarItem.rawName`
   (`WorkspaceBarDataSource.swift:127`) carries the same string; passing it
   straight through is an equivalent alternative, but the id-based form keeps all
   bar actions uniform and lets the controller validate the workspace exists.

6. **Decision — make the modifier branch hermetically testable** (resolves the
   discovery's Step 2 A-vs-B testability tension). Instead of polling
   `NSEvent.modifierFlags` directly inside the closure (hard to assert in tests)
   or installing a long-lived `.flagsChanged` monitor (Option B), extract a pure
   `WorkspaceBarClickIntent.resolve(modifiers:)` enum and inject the flag source
   via a `clickIntentFlagProvider` on the manager defaulting to
   `{ NSEvent.modifierFlags }`. The resolver is unit-tested with no `NSEvent`;
   the wiring is tested by injecting `.shift` / `[]`.

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Controller/WMController.swift`
   - Add `func moveFocusedWindowFromBar(toWorkspaceId id: WorkspaceDescriptor.ID)`
     next to `focusWorkspaceFromBar(id:)` (`:725`). It resolves the raw workspace
     name via `workspaceManager.descriptor(for: id)?.name` and delegates to
     `workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID:)`. Early-
     returns (no-op) when the descriptor is missing — matching the silent no-op
     of the existing bar focus path.
2. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`
   - Add a top-level `enum WorkspaceBarClickIntent { case focus, moveWindow }`
     with `static func resolve(modifiers: NSEvent.ModifierFlags) -> WorkspaceBarClickIntent`
     (`modifiers.contains(.shift) ? .moveWindow : .focus`). (No `.moveColumn`
     case in v1 — column move is deferred per correction #2.)
   - Add `var clickIntentFlagProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }`
     (injectable for tests; default is the global poll proven at
     `MultitouchGestureSource.swift:86`).
   - Replace the body of the `onFocusWorkspace` closure in
     `createBarForMonitor` (`:222-224`) so it resolves the intent from
     `clickIntentFlagProvider()` and dispatches: `.focus` →
     `controller.focusWorkspaceFromBar(id: item.id)` (unchanged), `.moveWindow`
     → `controller.moveFocusedWindowFromBar(toWorkspaceId: item.id)` (new).
     Capture `[weak self, weak controller]` so the provider is reachable; fall
     back to `NSEvent.modifierFlags` if `self` is gone.
3. `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
   - Discoverability (required, not optional): change the tooltip on
     `WorkspaceLabelButton` (`.help(...)` at `:388`) from
     `"Focus workspace \(item.name)"` to e.g.
     `"Focus workspace \(item.name) — Shift-click to move the focused window here"`.
     No other view change — the SwiftUI body, the `onFocusWorkspace` callback
     shape, and the non-activating panel behavior are untouched.
4. (Optional, recommended) `Sources/Nehir/UI/WorkspaceBarSettingsTab.swift`
   - One-line hint next to the bar toggles, mirroring the tooltip wording. Skip
     if the settings tab has no natural home for it; the tooltip alone satisfies
     the minimum discoverability bar.

### Non-goals

- Do **not** implement `moveFocusedColumnFromBar` / a second modifier in this
  task. The column path does not inherit the target-viewport reveal or the
  focus-follows policy (correction #2); revisit as a separate follow-up with its
  own viewport/focus decision.
- Do **not** change `WorkspaceBarView`'s callback signature, the pill subviews,
  or the panel (`nonactivatingPanel` / `becomesKeyOnlyIfNeeded` at
  `WorkspaceBarManager.swift:471,483` stay as-is). The feature is a callback-body
  change only.
- Do **not** apply modifier behavior to the per-window icons
  (`onFocusWindow`), the scratchpad pill (`onActivateScratchpad`), or the three
  trailing action buttons. Scoped to the workspace label/pill background only
  (discovery Open decision C).
- Do **not** add new move/transfer logic, a settings kill-switch, or a
  `.contextMenu`/`NSViewRepresentable` (discovery Step 1 Option C). v1 is the
  global-flag poll + pure resolver.
- Do **not** change keyboard bindings, `HotkeyCommand`, `CommandHandler`, or
  `WorkspaceNavigationHandler`. This plan only adds a *caller* of the existing
  `moveFocusedWindow(toRawWorkspaceID:)`.

## Exact implementation plan

Phased and ordered; each phase is independently testable before the next.

### Phase 1 — Controller seam (the real logic)

In `Sources/Nehir/Core/Controller/WMController.swift`, next to
`focusWorkspaceFromBar(id:)` (`:725`):

```swift
/// Shift+click on a workspace pill moves the focused managed window to that
/// workspace. Mirrors `focusWorkspaceFromBar(id:)` and reuses the existing
/// `moveFocusedWindow(toRawWorkspaceID:)` pipeline (target-viewport reveal +
/// `focusFollowsWindowToMonitor`). Silent no-op if the workspace is unknown or
/// no managed window is focused (same early-return behavior as the hotkey path).
func moveFocusedWindowFromBar(toWorkspaceId id: WorkspaceDescriptor.ID) {
    guard let rawID = workspaceManager.descriptor(for: id)?.name else { return }
    workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawID)
}
```

Notes:
- `descriptor(for:)` returns `WorkspaceDescriptor?` (`WorkspaceManager.swift:2302`);
  `.name` (`:14`) is the raw workspace name (`"3"` or a custom name) — the exact
  form `moveFocusedWindow(toRawWorkspaceID:)` (`:814`) feeds into
  `workspaceManager.workspaceId(for:createIfMissing:)` (`:2306`).
- "Active window" is resolved inside `moveFocusedWindow` via
  `managedCommandTargetToken()` (`WMController.swift:1798`) — the *same* object
  the `Opt+Shift+N` hotkey targets. No new target resolution.
- The method inherits `prepareMovedWindowTargetViewport` (both branches at
  `WorkspaceNavigationHandler.swift:844`/`:869`) and the
  `settings.focusFollowsWindowToMonitor` branch for free.

Land Phase 1 + its tests (below) and ship-green before Phase 2.

### Phase 2 — Pure modifier→intent resolver + flag injection

In `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`:

```swift
/// Which bar action a workspace-pill click should perform, given held modifiers.
enum WorkspaceBarClickIntent {
    case focus
    case moveWindow

    static func resolve(modifiers: NSEvent.ModifierFlags) -> WorkspaceBarClickIntent {
        modifiers.contains(.shift) ? .moveWindow : .focus
    }
}
```

and on `WorkspaceBarManager`:

```swift
/// Defaults to the global modifier-flag poll (proven at
/// `MultitouchGestureSource.swift:86`). Injectable so the click-wiring dispatch
/// is hermetically testable without synthesizing an `NSEvent`.
var clickIntentFlagProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
```

Land the resolver + its unit tests before Phase 3.

### Phase 3 — Branch the click callback

In `createBarForMonitor` (`WorkspaceBarManager.swift:222-224`), replace the
closure body:

```swift
onFocusWorkspace: { [weak self, weak controller] item in
    guard let controller else { return }
    let flags = self?.clickIntentFlagProvider() ?? NSEvent.modifierFlags
    switch WorkspaceBarClickIntent.resolve(modifiers: flags) {
    case .focus:
        controller.focusWorkspaceFromBar(id: item.id)
    case .moveWindow:
        controller.moveFocusedWindowFromBar(toWorkspaceId: item.id)
    }
},
```

The plain-click path is byte-for-byte unchanged (`controller.focusWorkspaceFromBar(id: item.id)`).
`Shift+click` now routes to the Phase 1 method. No SwiftUI view edits.

### Phase 4 — Discoverability

- Update `.help(...)` on `WorkspaceLabelButton` (`WorkspaceBarView.swift:388`) to
  mention Shift-click (wording in Scope §3).
- (Optional) One-line hint in `WorkspaceBarSettingsTab.swift`.

## Tests

### `Tests/NehirTests/WorkspaceNavigationHandlerTests.swift` (Phase 1 — controller seam)

Mirror the shape of the existing
`moveFocusedWindowWithoutFollowRevealsInactiveTargetViewport` (`:116`), which
uses `makeWorkspaceNavigationTestController()`,
`addWorkspaceNavigationTestWindow(on:workspaceId:windowId:)`,
`assertMovedWindowRevealedInTargetViewport(controller:workspaceId:token:)`, and
`waitForLayoutPlanRefreshWork(on:)`:

1. **`moveFocusedWindowFromBarMovesFocusedWindowToClickedWorkspace`** — focused
   managed window on workspace 2, click-target workspace 1; call
   `controller.moveFocusedWindowFromBar(toWorkspaceId: ws1.id)`; assert the
   window left the source, joined the target, and is revealed in the target
   viewport (`assertMovedWindowRevealedInTargetViewport`). This proves the new
   entry point reaches the full pipeline.
2. **`moveFocusedWindowFromBarNoopsWhenNoManagedFocus`** — no managed window
   focused; call the method against any workspace id; assert workspace
   membership is unchanged and no crash (mirrors the hotkey early-return).
3. **`moveFocusedWindowFromBarResolvesCustomNamedWorkspace`** — a workspace with
   a non-numeric name; assert `descriptor(for:)?.name` resolves through
   `moveFocusedWindow(toRawWorkspaceID:)` and the window lands on that workspace.

(If `WMController` bar-action tests already have a home, add these there;
otherwise they fit naturally next to the navigation-handler move tests since
they exercise the same fixture helpers.)

### `Tests/NehirTests/WorkspaceBarManagerTests.swift` (Phases 2 & 3 — resolver + wiring)

4. **`clickIntentResolveMapsShiftToMoveWindow`** —
   `WorkspaceBarClickIntent.resolve(modifiers: .shift) == .moveWindow`;
   `.init(rawValue: 0)` (no modifiers) == `.focus`; `.option` alone == `.focus`
   (no `.moveColumn` in v1).
5. **`onFocusWorkspaceDispatchesMoveOnShift`** — with a controller double/spy,
   set `manager.clickIntentFlagProvider = { .shift }`, drive the
   `onFocusWorkspace` closure with an item, assert
   `moveFocusedWindowFromBar(toWorkspaceId:)` is reached (and
   `focusWorkspaceFromBar` is not).
6. **`onFocusWorkspaceDispatchesFocusByDefault`** —
   `clickIntentFlagProvider = { [] }`; assert `focusWorkspaceFromBar(id:)` is
   reached (plain-click path unchanged) and `moveFocusedWindowFromBar` is not.
   Reset `clickIntentFlagProvider` in `defer` to avoid leaking state across tests.

The SwiftUI tooltip change (Phase 4) is verified by inspection/manual smoke; no
view test is required (consistent with how the existing pill tooltips are
tested — they are not).

## Validation

```bash
swift build
swift test --filter WorkspaceNavigationHandlerTests
swift test --filter WorkspaceBarManagerTests
mise run format          # swiftformat .
mise run lint            # swiftlint lint
```

Re-run the targeted filters after each phase. For a full local gate before
hand-off: `mise run check` (format:check + lint + build + test) — note the
`test` task runs `--no-parallel` with a special `IPCServerTests`-first ordering,
so prefer the targeted `swift test --filter ...` filters during development.

Manual validation (single monitor, ≥2 workspaces, a managed window focused on
workspace 1):

1. Shift+click workspace 2's pill → the focused window moves to workspace 2 and
   is revealed there (focus follows per `focusFollowsWindowToMonitor`); workspace
   1 recovers focus on its remaining window.
2. Plain click workspace 3 → focuses workspace 3 (unchanged behavior).
3. Shift+click with no managed window focused → silent no-op, no crash, no focus
   change.
4. Hover a pill → tooltip reads the new Shift-click wording.
5. Regression: `Opt+Shift+N` still moves the focused window (the shared pipeline
   is untouched).

Changeset (minor; additive input affordance, no schema/binding change):
"Shift+click a workspace pill to move the focused window there (mouse analogue
of Opt+Shift+N)."

## Risks and mitigations

- **"Active window" may be empty.** With nothing managed focused,
  `managedCommandTargetToken()` (`WMController.swift:1798`) returns nil and
  `moveFocusedWindow(toRawWorkspaceID:)` early-returns silently — so a
  Shift+click that does nothing is consistent with the hotkey path today.
  Mitigation: keep the silent no-op (matches existing behavior); the tooltip
  wording is the only user-facing signal. Do **not** fall back to focusing the
  workspace on Shift+click — that would make Shift+click do something
  surprising and modifier-dependent.
- **Modifier-flag race on the global poll.** `NSEvent.modifierFlags` is read
  synchronously inside the action, which fires on mouse-up on the main thread.
  Acceptable for human input (the same assumption `MultitouchGestureSource.swift:86`
  makes). The pure resolver + injectable provider mean the *logic* is tested
  with no race surface; only the flag read itself is untestable, and it is a
  single line.
- **Column move is *not* a free follow-up (correction #2).** Anyone picking up
  the column variant must NOT assume `prepareMovedWindowTargetViewport` or
  `focusFollowsWindowToMonitor` apply — `moveColumnToWorkspace(rawWorkspaceID:)`
  (`WorkspaceNavigationHandler.swift:745`) does neither. Mitigation: this plan
  ships window-move only and documents the gap; a column follow-up is a separate
  task with its own viewport/focus decision.
- **Width preservation.** `moveWindowToWorkspace` width behavior is the subject
  of `discovery/20260616-omniwm-295-niri-window-width-preservation.md`. Reusing
  the existing entry point means the click path inherits today's behavior — no
  new risk, but the Shift+click-into-empty-workspace case should be smoke-tested
  for expected width.
- **Modifier collisions / muscle memory.** Shift is benign everywhere and is
  already Nehir's "move" modifier. Scope v1 to Shift-only; do not bind Option or
  Command (system alternate-click semantics in other apps).
- **Scope creep onto sibling pills.** The bar also renders per-window icons, a
  scratchpad pill, and action buttons with their own callbacks. Mitigation:
  branch only the workspace `onFocusWorkspace` callback; leave `onFocusWindow` /
  `onActivateScratchpad` untouched (those overlap with backlog #8, see
  `discovery/20260621-right-click-actions-action-bar.md`).

## Follow-ups (out of scope)

- **Column variant** — `moveFocusedColumnFromBar(toWorkspaceId:)` + a second
  modifier (e.g. `Shift+Cmd+click`), delegating to
  `moveColumnToWorkspace(rawWorkspaceID:)`. Requires its own decision on
  target-viewport reveal and focus-follows, because the column path
  (correction #2) does not inherit either today. Track separately; do not bundle.
- **Right-click context menu on pills** (backlog #18,
  `discovery/20260621-right-click-actions-action-bar.md`) — a sibling mouse
  affordance that would share the `WorkspaceBarClickIntent`/token-target seam.
  Its `NSViewRepresentable`-with-`rightMouseDown` option is the discovery's
  Step 2 Option C; if it lands, the resolver and the bridging view can be
  co-designed.
- **Token-parameterized action family** (backlog #8) — the shared refactor that
  #18 and this idea both consume if per-window-icon modifier actions are ever
  wanted. Out of scope here because v1 targets the workspace pill (id-based),
  not a specific window token.
- **Settings kill-switch** — a toggle to disable Shift-to-move (e.g. for users
  who remapped Shift). Unnecessary for v1 (additive, never changes plain click);
  revisit only if requested.
