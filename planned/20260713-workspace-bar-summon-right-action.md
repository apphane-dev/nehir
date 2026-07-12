# Add Summon Right to workspace-bar window context menus

**Status:** planned  
**Verified against:** `main` at `6d6b23ee` on 2026-07-13

## Overview

Add a **Summon Right** item to the right-click menu for each tiled, floating,
or sticky `WindowIconView` in the workspace bar. The clicked window must be
summoned into the active workspace on the display that owns the bar and
inserted immediately right of that workspace's anchor, matching
**Shift-Enter → Summon Right** in the command palette. The separate scratchpad
pill is not part of this change.

This is another UI entry point into the existing command, not a new movement
algorithm. Both surfaces must share the same destination/anchor resolver and
must ultimately call the explicit
`WindowActionHandler.summonWindowRight(handle:anchorToken:anchorWorkspaceId:)`
path.

## Source-backed current state

- `WorkspaceBarView` already accepts token-parameterized callbacks for its
  window-icon actions (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift:159-174`).
  `WorkspaceBarWindowActions` bundles those callbacks (`:237-249`),
  `WorkspaceItemView.scopedWindowActions` copies them while scoping the move
  targets to the source workspace (`:507-522`), and `WindowIconView` builds the
  actual context menu (`:1102-1154`). Every existing item passes `window.id`, so
  the menu acts on the clicked icon's token rather than ambient focus.
- `WorkspaceBarManager.createBarForMonitor` constructs one bar per concrete
  `Monitor` and wires its callbacks to token-based `WMController` entry points
  (`Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift:220-282`). The
  closure therefore already has the owning `monitor.id` needed to choose the
  destination display deterministically.
- The command palette captures its summon anchor when the palette opens
  (`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:337-356`).
  `resolveSummonAnchor` (`:446-488`) chooses the active workspace on the
  palette's monitor, uses confirmed managed focus only when it belongs to that
  workspace, falls back to preferred workspace-focus memory, and deliberately
  returns a workspace-only anchor (`token == nil`) for an empty workspace or
  unmanaged focus. Existing tests pin those cases and the multi-monitor rule
  (`Tests/NehirTests/CommandPaletteControllerTests.swift:564-710`).
- Palette Shift-Enter does not implement movement itself: it dispatches the
  selected `WindowHandle` plus the captured token/workspace anchor through
  `WMController.summonCommandPaletteWindowRight`
  (`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:1002-1045`,
  `Sources/Nehir/Core/Controller/WMController.swift:3636-3646`).
- The load-bearing implementation is the explicit three-argument overload in
  `WindowActionHandler` (`Sources/Nehir/Core/Controller/WindowActionHandler.swift:411-465`).
  It validates the target and anchor, rejects summoning the anchor itself, then
  performs the Niri insertion. Its convenience one-argument overload
  (`:393-409`) requires a confirmed managed focus and therefore cannot preserve
  palette behavior for empty workspaces or unmanaged focus.
- Core coverage already proves right-of-anchor insertion and workspace-only
  insertion (`Tests/NehirTests/WindowActionHandlerTests.swift:141-240`). The
  workspace-bar right-click suite documents that SwiftUI `.contextMenu`
  gestures are not driven synthetically; tests instead pin snapshot tokens and
  the controller callbacks wrapped by the menu
  (`Tests/NehirTests/WorkspaceBarRightClickWiringTests.swift:10-23,50-108`).

## Required behavior

1. Right-clicking a tiled, floating, or sticky workspace-bar window icon shows
   **Summon Right**; the separate scratchpad pill does not.
2. Choosing it targets the exact represented `WindowToken`, not the focused
   window. For a grouped app icon, this preserves today's context-menu contract:
   it targets the representative `WorkspaceBarWindowItem.id`. Per-member Summon
   Right remains out of scope; **Windows…** continues to provide focus-only
   member selection.
3. The destination is the active workspace on the display that owns the bar,
   even when the interaction monitor or current managed focus is on another
   display.
4. Anchor selection is identical to the command palette:
   - confirmed managed focus when it belongs to the destination workspace;
   - otherwise that workspace's preferred-focus token, if still valid;
   - otherwise no token, causing insertion as the new rightmost column.
5. The action works from empty destination workspaces and while unmanaged UI is
   focused. An unknown/stale clicked token returns `.notFound` without moving a
   different window.
6. Selecting the current anchor remains a safe no-op, matching command-palette
   behavior and the existing core `targetIsAnchor` rejection; the bar adapter
   returns `.notFound` and leaves managed/layout state unchanged.

## Solution design

### Shared summon target policy

Extract the palette-named `CommandPaletteSummonAnchor` and
`CommandPaletteController.resolveSummonAnchor` policy into a UI-neutral core
model/resolver, for example:

- `SummonRightAnchor { token: WindowToken?, workspaceId: WorkspaceDescriptor.ID }`
- `WMController.summonRightAnchor(on monitorId: Monitor.ID?) -> SummonRightAnchor?`

The resolver must preserve the current palette fallback exactly: use
`activeWorkspaceOrFirst(on:)` when the supplied monitor maps to a workspace;
fall back to `interactionWorkspace()` only when it does not; validate both
confirmed and remembered tokens against the chosen workspace before returning.
The palette still captures the result once in `show`, so opening/closing and
session-stability semantics do not change. The bar resolves at action time
using its owning monitor because it has no modal session to snapshot.

### Shared command execution

Add a token-based controller adapter such as:

```swift
func summonWindowRightFromBar(
    token: WindowToken,
    on monitorId: Monitor.ID
) -> ExternalCommandResult
```

It resolves the clicked token to its existing `WindowHandle`, asks the shared
resolver for the destination anchor, and delegates to the same explicit
`WindowActionHandler.summonWindowRight(handle:anchorToken:anchorWorkspaceId:)`
overload used by the palette. Map successful execution to `.executed` and any
missing token, missing destination, invalid anchor, or core rejection to
`.notFound`, consistent with the other workspace-bar adapters.

Do not call `summonWindowRight(handle:)`: that convenience overload rejects the
workspace-only-anchor cases this feature must support.

## Files to change

- Create: `Sources/Nehir/Core/Controller/SummonRightAnchor.swift`
  - UI-neutral anchor value and shared resolver (or an equivalently focused
    name/location next to the controller policy).
- Modify: `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift`
  - replace the palette-local anchor type/resolver with the shared policy;
    retain capture-at-show and existing dispatch behavior.
- Modify: `Sources/Nehir/Core/Diagnostics/SummonTraceFormatting.swift`
  - format the shared anchor type instead of the palette-specific type.
- Modify: `Sources/Nehir/Core/Controller/WMController.swift`
  - add the token + monitor workspace-bar adapter; keep the palette adapter on
    the same explicit handler path (renaming it to a surface-neutral execution
    helper is acceptable if both callers use it).
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarView.swift`
  - thread `onSummonWindowRight: (WindowToken) -> Void` through
    `WorkspaceBarView`, its measurement no-op, `WorkspaceBarContentView`,
    `WorkspaceBarWindowActions`, and `scopedWindowActions`; add a
    **Summon Right** button to the window-icon context menu before the divider
    and destructive **Close** item.
- Modify: `Sources/Nehir/UI/WorkspaceBar/WorkspaceBarManager.swift`
  - wire the callback to `summonWindowRightFromBar(token:on: monitor.id)`.
- Modify: `Tests/NehirTests/CommandPaletteControllerTests.swift`
  - update names/call sites for the extracted resolver without weakening the
    existing empty-workspace, preferred-focus, and pointer-monitor assertions.
- Create: `Tests/NehirTests/WorkspaceBarSummonRightTests.swift`
  - focused per-behavior coverage for the new adapter and shared semantics.

No `WorkspaceBarDataSource` change is required: snapshots already expose the
exact source token, and the manager already owns the destination monitor.

## Do-not-touch fences

- Do not add a new `HotkeyCommand`, command-palette command item, IPC/CLI route,
  or layout-engine operation. This feature reuses the existing Summon Right
  command path.
- Do not duplicate anchor selection in workspace-bar UI code. There must be one
  resolver used by both palette and bar.
- Do not change Niri insertion, cross-monitor admission, refresh, focus, or
  animation behavior in `WindowActionHandler`; existing Summon Right owns it.
- Do not change workspace-bar grouping or add per-member actions to the
  **Windows…** sheet in this task.
- Do not alter unrelated workspace-pill, scratchpad, move-to-workspace, or
  context-menu actions.
- Do not modify any frozen test monolith listed in `docs/TESTING.md`, including
  `RefreshRoutingTests.swift`. Test hooks may observe, but must not change a
  Nehir-owned decision.

## Implementation steps

### Task 1 — Extract and share anchor resolution

- [ ] Add the UI-neutral anchor model and monitor-aware resolver.
- [ ] Move the existing resolver body rather than reimplementing it; preserve
      monitor selection, interaction-workspace fallback, remembered-focus
      fallback, token validation, and workspace-only anchors.
- [ ] Update the palette and `SummonTraceFormatting` to use the shared type.
- [ ] Update existing palette tests only for the moved API; all assertions must
      remain equivalent.
- [ ] Fast gate: `mise run build`, then
      `swift test --filter CommandPaletteControllerTests`.

### Task 2 — Add the token-based workspace-bar adapter

- [ ] Add `summonWindowRightFromBar(token:on:)` (or equivalent) to
      `WMController`.
- [ ] Resolve only the passed token; never consult a command-target/focused-
      window resolver for the source window.
- [ ] Resolve the destination from the supplied bar monitor and call the exact
      explicit `WindowActionHandler.summonWindowRight` overload used by the
      palette.
- [ ] Return `.notFound` on stale source token, absent destination, or rejected
      execution.
- [ ] Fast gate: `mise run build`.

### Task 3 — Wire the context-menu item

- [ ] Thread the token callback through every workspace-bar initializer/action
      bundle, including `WorkspaceBarMeasurementView`'s no-op closure and
      `WorkspaceItemView.scopedWindowActions`.
- [ ] Add a **Summon Right** menu item in the non-destructive action group,
      passing `window.id`.
- [ ] In `WorkspaceBarManager`, capture the bar's concrete `monitor.id` and call
      the new adapter.
- [ ] Keep grouped-icon targeting and all existing menu ordering/disable rules
      otherwise unchanged.
- [ ] Fast gate: `mise run build` and `mise run test:compile`.

### Task 4 — Focused tests and acceptance

Create `Tests/NehirTests/WorkspaceBarSummonRightTests.swift` with synthetic
Swift Testing coverage:

- [ ] clicked token B is summoned while token A is focused, proving the source
      is explicit-token rather than focus-targeted;
- [ ] on two monitors, invoking the adapter for the secondary bar targets the
      secondary active workspace even when interaction focus is primary;
- [ ] a valid destination anchor inserts the clicked window immediately right
      of that anchor;
- [ ] an empty destination workspace produces a nil-token anchor and admits the
      clicked window as the rightmost/new column;
- [ ] unmanaged focus with valid workspace focus memory uses the remembered
      anchor;
- [ ] stale/unknown clicked tokens and unavailable destinations return
      `.notFound` and leave managed state unchanged;
- [ ] choosing the anchor itself returns `.notFound` and leaves managed/layout
      state unchanged.

Reuse existing synthetic Niri/window fixtures and the production resolver. Do
not add decision-changing `ForTests` branches. Existing
`WindowActionHandlerTests` remain the lower-level insertion contract; do not
copy their implementation-level assertions unnecessarily.

Fast gate: `swift test --filter WorkspaceBarSummonRightTests` plus
`swift test --filter WorkspaceBarRightClickWiringTests`.

### Task 5 — Manual verification and final gate

- [ ] Single monitor: focus window A, right-click window B's bar icon, choose
      **Summon Right**, and confirm B appears immediately right of A.
- [ ] Empty workspace: activate an empty workspace, use a visible foreign
      workspace icon's menu to summon a window, and confirm it becomes the new
      rightmost column.
- [ ] Two monitors: interact on the primary display, invoke **Summon Right**
      from the secondary display's bar, and confirm the window lands in the
      secondary display's active workspace.
- [ ] Grouped icon: confirm the action targets the same representative window
      as the icon's other token-based context-menu actions.
- [ ] Run the full gate once at the end: `mise run check`.
- [ ] Add a minor changeset:
      `mise run changeset minor "Summon windows to the right from workspace bar context menus"`.

## Risks and mitigations

- **Resolver drift:** duplicating the palette's monitor/focus fallback would
  eventually make the two UI surfaces disagree. Mitigation: extract one shared
  resolver before wiring the bar.
- **Wrong source window:** ambient focus can differ from the right-clicked icon.
  Mitigation: carry `WindowToken` end-to-end and test B while A is focused.
- **Wrong display:** interaction monitor may differ from the bar used.
  Mitigation: capture the creating bar's `monitor.id`, not pointer position or
  global interaction state.
- **Empty/unmanaged destination regression:** the convenience handler overload
  requires confirmed focus. Mitigation: call only the explicit anchor overload
  and retain the palette's workspace-only-anchor tests.
- **Grouped icons:** a group represents multiple windows but existing actions
  target its representative token. Mitigation: preserve that established
  contract and state it in release/manual acceptance; per-member menus are a
  separate feature.

## Housekeeping and commit message shape

- [ ] After implementation merges, update this document with deviations and
      move it from `planned/` to `completed/` on the plans branch.
- Use plain-English commit subjects, not Conventional Commits. Suggested source
  commit: `Add Summon Right to workspace bar window menus`.
- Reference only Nehir issue numbers as bare `#nnn`; do not cite an unrelated
  upstream ticket.
