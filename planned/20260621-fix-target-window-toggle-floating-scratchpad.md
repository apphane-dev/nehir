# Fix target window for toggle floating / scratchpad commands

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned (core symptom partially addressed on `main`). Update
2026-07-01: `faa45c37` ("Prefer layout selection over same-pid floating sibling
for commands") shipped a narrow reorder of `managedCommandTarget()` so a concrete
layout selection now wins over an *unfocused* same-pid floating sibling — this
fixes the headline symptom (a move/focus command hitting a visible PiP-style
floating sibling instead of the tiled window). It is **not** this plan's proposed
change: the frontmost-floating branch, the `focusedManagedTokenForCommand()` alias
collapse, the documented `commandTarget()` contract, and the ARCHITECTURE.md /
IPC-CLI.md contract notes are all still un-done. Re-verify the remaining scope
below against the reordered cascade before implementing.
**Source discovery:** `discovery/20260621-fix-target-window-toggle-floating-scratchpad.md`
**Upstream reference:** Nehir backlog brainstorm idea **#8** ("Fix target window
for commands like toggle floating / scratchpad, etc."); sibling idea **#7**
("Multiple scratchpad window assignments"), to be co-triaged but not duplicated
here; commit `e5188e42` ("Fix focused-window commands to prioritize floating
windows over tiled windows", fixing #12), whose contract this plan revises.

Source references were refreshed against main `7a025b78` on 2026-07-07. `WMController` still contains the command-target cascade (`managedCommandTarget(forFrontmostToken:requireFloating:)`, `samePidFloatingCommandTarget`, and `focusedManagedTokenForCommand()`, currently around `Sources/Nehir/Core/Controller/WMController.swift:1896-2063`), so the remaining behavior is not shipped.

## TL;DR

Nehir has **three independent notions of "the target window"** and the command
layer is not consistent about which one it consults. With a floating window
focused, `toggle floating` acts on the floating window (good), but `move left`,
`set column width`, `toggle fullscreen`, `cycle size`, `consume/expel` silently
act on the tiled window underneath (surprising). Separately, the
`managedCommandTarget()` cascade has a *frontmost-floating* branch that can make
a command literally named `…FocusedWindow…` target a window that is **not** the
confirmed focused one.

This plan does **not** rewrite the resolver. It (1) collapses the two names for
the same policy into one documented `commandTarget()`, (2) drops the
frontmost-floating branch so the target always equals confirmed managed focus
(or, when none, the layout selection / frontmost fallback), (3) makes the
layout-command "acts on the tiled selection" behavior intentional and
documented, and (4) leaves the scratchpad-*toggle* focus question to backlog
#7. Net change: ~50–100 lines plus tests. The fix for #12 (focused floating
window is the move-to-workspace target) is preserved because the *confirmed*
floating focus still wins.

## Discovery corrections / decisions

The discovery's product recommendation is correct; the following source
corrections were needed (line numbers drift between the discovery's `56573ba2`
and current main `7a025b78`, plus two structural fixes):

1. **`confirmedManagedFocusToken` path.** The discovery cited
   `WorkspaceManager.swift:1059` under `Sources/Nehir/Core/Controller/`. The
   actual location is
   `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1065` (different
   subdirectory). `isNonManagedFocusActive` is at `:1089`; `scratchpadToken()`
   at `:1101`.
2. **Cascade + helper lines.** `managedCommandTarget()` is at
   `Sources/Nehir/Core/Controller/WMController.swift:1741-1796` (discovery said
   `:1735-1791`). Token helpers: `managedCommandTargetToken()` `:1798`,
   `managedLayoutCommandTargetToken()` `:1802-1804`,
   `focusedManagedTokenForCommand()` `:1806-1808` (the alias this plan
   collapses), `layoutSelectionCommandTarget()` `:1724-1740`,
   `focusedOrFrontmostWindowTokenForAutomation(...)` `:1705-1718`.
3. **Caller lines.** `toggleFocusedWindowFloating()` `WMController.swift:3562`
   (discovery `:3531`); `assignFocusedWindowToScratchpad()` `:3582` (discovery
   `:3551`); `toggleScratchpadWindow()` `:3668` (discovery `:3637`);
   `scratchpadTarget(on:)` `:1874` (discovery `:1868`). In
   `CommandHandler.swift`: `toggleNativeFullscreenForFocused()` starts `:242`,
   reads `managedCommandTargetToken()` at `:254` (discovery said `:248-251`);
   the `case .toggleFocusedWindowFloating` / `.assignFocusedWindowToScratchpad`
   / `.toggleScratchpadWindow` dispatch is at `:186-190` (discovery `:188-192`).
4. **IPC lines.** In `IPCCommandRouter.swift` the `moveFocusedWindow(using:)`
   token capture is at `:337` (discovery said `:311`); there are two further
   captures at `:424` (`moveFocusedWindow(to:)`) and `:445`
   (`moveFocusedWindow(...workspace:)`). The `toggleFocusedWindowFloating` /
   `assignFocusedWindowToScratchpad` / `toggleScratchpad` IPC wrappers are at
   `:368` / `:372` / `:376` (unchanged).
5. **NiriLayoutHandler lines.** `withNiriOperationContext` is at `:2042` and
   reads `state.selectedNodeId` at `:2048` (discovery said `:2041`/`:2047`);
   `withNiriWorkspaceContext` at `:2261` and `:2284` (discovery `:2260`,
   `:2283`). Command methods: `focusNeighbor :1223`, `focusPrevious :1309`
   (**real drift** — discovery said `:1336`), `moveWindow :2086`,
   `moveColumn :2124`, `toggleFullscreen :1558`, `cycleSize :1573`,
   `setColumnWidth :1740`, `consumeOrExpelWindow :2188`,
   `consumeWindowIntoColumn :2208`, `expelWindowFromColumn :2226`.
6. **Test lines.** In `Tests/NehirTests/IPCCommandRouterTests.swift`:
   `toggleFocusedWindowFloatingReturnsControllerCommandResult` `:610`,
   `toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
   `:629` (asserts `controller.managedCommandTarget()?.token == floatingToken`
   at `:644`), `moveFocusedWindowTracksFrontmostFloatingCommandTarget` `:650`
   (discovery said `:657`). The files `WMControllerFocusTests.swift` and
   `WMControllerScratchpadTests.swift` exist as cited.
7. **Docs.** The "Focus management" section is at `docs/ARCHITECTURE.md:566`,
   with the three notions listed at `:568`/`:569`/`:571` (discovery said ~`:566`
   — accurate). The IPC floating contract note is at `docs/IPC-CLI.md:346`.
8. **Decision adopted from discovery Open Questions:** one `commandTarget()`
   policy function with two *documented* behaviors (Q1); layout commands no-op
   silently when floating focus is active, made intentional + documented —
   option (a) (Q2); **drop** the frontmost-floating branch (Q3); defer the
   scratchpad-toggle question to #7 (Q4); collapse the
   `focusedManagedTokenForCommand()` alias into the policy name (Q5).

## Scope

### Files to add/change

1. `Sources/Nehir/Core/Controller/WMController.swift`
   - **Rename/consolidate.** Make `managedCommandTarget()` the single documented
     policy entry point. Add a doc-comment that states the contract: *"Returns
     the window a command named 'focused window' acts on. It is the confirmed
     managed focus when one exists; otherwise the Niri layout selection;
     otherwise the OS frontmost managed window."* Collapse the private alias
     `focusedManagedTokenForCommand()` (`:1806-1808`) into
     `managedCommandTargetToken()` (`:1798`) and delete the alias; update the
     two internal callers (`toggleFocusedWindowFloating` `:3563`,
     `assignFocusedWindowToScratchpad` `:3583`) to call
     `managedCommandTargetToken()` directly.
   - **Drop the frontmost-floating branch.** In `managedCommandTarget()`
     (`:1741-1796`), remove the second `if` block (`:1759-1772` — the
     `frontmostToken` + `.floating` check). After this change the cascade is:
     (1) confirmed focus and `.floating` → `.confirmedManagedFocus`;
     (2) `layoutSelectionCommandTarget()` → `.layoutSelection`;
     (3) confirmed focus (any mode) → `.confirmedManagedFocus`;
     (4) frontmost managed window (any mode) → `.frontmostManagedFallback`.
     The `.frontmostManagedFallback` *source value* stays (it is still reached
     at step 4); only the floating-preference *at step 2* is removed. The
     `frontmostPid`/`frontmostToken` computation (`:1752-1756`) moves below the
     removed block so it is only evaluated when step 4 needs it.
2. `Sources/Nehir/Core/Controller/WMCommandTarget.swift`
   - Add a doc-comment to `Source` (`:9-13`) documenting each case and noting
     that `.frontmostManagedFallback` is now reached **only** when there is no
     confirmed managed focus and no layout selection — i.e. the command target
     always equals the confirmed focused window when one exists. No new cases.
3. `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift`
   - Make the layout-command no-op-on-floating-focus intentional and observable.
     In `withNiriOperationContext` (`:2042`) just before the
     `guard let currentId = state.selectedNodeId` block (`:2048`), add an
     early-return guard: if the confirmed managed focus is a `.floating` window,
     record a compact runtime trace event
     (`layoutCommand.skipped reason=focusedFloating command=<name>`) and return
     without running the operation. Do **not** redirect to the tiled selection
     and do **not** surface UI (option (a) + documentation). Apply the same
     guard to both `withNiriWorkspaceContext` overloads (`:2261`, `:2284`).
   - The guard reads `controller.workspaceManager.confirmedManagedFocusToken`
     and the entry's `.mode`; if the token is nil or the entry is `.tiling`,
     behavior is unchanged.
4. `Sources/Nehir/Core/Controller/CommandHandler.swift`
   - No structural change: `toggleNativeFullscreenForFocused` (`:242`) and the
     dispatch cases (`:186-190`) already reach `managedCommandTargetToken()` /
     the WMController methods, so they inherit the policy for free. Add an
     inline comment at `:254` pointing at the `managedCommandTarget()` contract.
5. `Sources/Nehir/IPC/IPCCommandRouter.swift`
   - No structural change: the three IPC wrappers (`:368`/`:372`/`:376`) delegate
     to `CommandHandler`. The `moveFocusedWindow(using:)` capture at `:337`
     (and `:424`, `:445`) already reads `managedCommandTargetToken()`; it
     inherits the new policy. Add an inline comment noting the contract.
6. `docs/ARCHITECTURE.md`
   - In the "Focus management" section (`:566`), add a paragraph after the three
     target notions (`:571`) documenting the two command behaviors:
     (a) "focused-window" commands (`toggle floating`, `assign to scratchpad`,
     native-fullscreen toggle, IPC `moveFocusedWindow`/`moveColumnToWorkspace`)
     consult `managedCommandTarget()` and always act on the confirmed managed
     focus when one exists;
     (b) layout commands (`move`, `focusNeighbor`, `toggleFullscreen`,
     `cycleSize`, `setColumnWidth`, `consume/expel`) act on the Niri viewport
     selection and intentionally no-op when the confirmed focus is floating,
     because floating windows are not part of the column tree.
7. `docs/IPC-CLI.md`
   - Revise the note at `:346` to state the new contract: focused-window
     commands target the **confirmed managed focus** (floating or tiled); when
     no managed window is focused they fall back to the layout selection then
     the OS frontmost managed window. The previous "prioritize floating over
     tiled" wording is replaced.

### Non-goals

- Do **not** make floating windows participate in the Niri column tree.
- Do **not** silently reroute layout commands (`move`/`resize`/`fullscreen`/
  `consume`/`expel`) onto floating focus — they stay viewport-selection-based
  and no-op (intentionally) when focus is floating.
- Do **not** change `toggleScratchpadWindow()` (`WMController.swift:3668`), which
  reads the stored `scratchpadToken()` and is intentionally focus-independent.
  Its focus semantics are backlog #7's decision.
- Do **not** change `focusedOrFrontmostWindowTokenForAutomation(...)`
  (`WMController.swift:1705-1718`, Resolver C) — it serves a different
  (automation/`WindowActionHandler`) surface with its own non-managed-focus
  flag; leave it.
- Do **not** add a new `Source` case (e.g. `.focusedFloating`) unless
  observability work later demands it.
- Do **not** change `moveColumnToWorkspace`/`moveColumnToAdjacentWorkspace`
  routing (already on `managedLayoutCommandTargetToken()`, `:1802`).

## Exact implementation plan

Phased and ordered; each phase is independently buildable.

### Phase 1 — Rename/collapse the alias (no behavior change)

1. In `WMController.swift`, delete `focusedManagedTokenForCommand()`
   (`:1806-1808`).
2. Update `toggleFocusedWindowFloating()` (`:3563`) and
   `assignFocusedWindowToScratchpad()` (`:3583`) to call
   `managedCommandTargetToken()` directly.
3. `grep` for any remaining `focusedManagedTokenForCommand` references
   repo-wide and remove them.

**Gate:** `swift build` + existing tests green. No semantic change; this phase
exists to make Phase 3's contract read as a single concept.

### Phase 2 — Document the contract (no behavior change)

1. Add the doc-comment to `managedCommandTarget()` (`:1741`) stating the
   confirmed-focus-first contract.
2. Add doc-comments to `WMCommandTarget.Source` (`:9-13`).
3. Add the ARCHITECTURE.md (`:571+`) and IPC-CLI.md (`:346`) prose.

**Gate:** docs render; `swift build` green.

### Phase 3 — Drop the frontmost-floating branch (behavior change)

1. In `managedCommandTarget()` (`:1741-1796`), remove the second `if` block
   (frontmost-floating). Hoist the `frontmostPid`/`frontmostToken`
   computation down so it is only evaluated by the final fallback.
2. Verify the remaining four steps still return the correct `Source` and that
   `layoutSelectionCommandTarget()` (`:1724`) is consulted before the
   generic-confirmed-focus fallback (so a tiled viewport selection is preferred
   over a stale confirmed token when the confirmed token is tiled — this
   matches today's ordering and preserves #12's tiled case).
3. Update `moveFocusedWindowTracksFrontmostFloatingCommandTarget`
   (`IPCCommandRouterTests.swift:650`): under the new policy, a *frontmost*
   floating window with a *confirmed tiled* focus no longer wins. Either
   rename the test to assert the new behavior (target == confirmed tiled
   focus) or split it into two tests — see Tests.

**Gate:** `swift test --filter IPCCommandRouterTests` +
`WMControllerFocusTests` green with the revised assertions.

### Phase 4 — Intentional layout-command no-op (behavior change)

1. In `NiriLayoutHandler.withNiriOperationContext` (`:2042`) add the
   confirmed-floating early-return guard before `:2048`.
2. Mirror the guard in both `withNiriWorkspaceContext` overloads (`:2261`,
   `:2284`).
3. Record a compact `layoutCommand.skipped reason=focusedFloating command=…`
   runtime trace event (use the existing `recordRuntimeInsertionTrace`-style
   helper used elsewhere in the handler; confirm the exact symbol when
   implementing). No user-visible affordance in this phase.

**Gate:** new `NiriLayoutHandlerTests` cases (below) green; existing layout
tests unchanged.

## Tests

### `Tests/NehirTests/IPCCommandRouterTests.swift` (update + add)

1. **Keep** `toggleFocusedWindowFloatingReturnsControllerCommandResult` (`:610`)
   unchanged.
2. **Keep** `toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`
   (`:629`) — its premise (confirmed floating focus wins over the tiled Niri
   selection) is **preserved** by the new policy; re-verify the assertion at
   `:644` still holds.
3. **Revise** `moveFocusedWindowTracksFrontmostFloatingCommandTarget` (`:650`):
   under the new policy, when confirmed focus is tiled `T` but the OS
   frontmost managed window is floating `F`, the target is `T` (the confirmed
   focus), not `F`. Rename to
   `moveFocusedWindowFollowsConfirmedFocusOverFrontmostFloating` and assert
   `managedCommandTarget()?.token == tiledToken`.
4. **Add** `toggleFloatingDoesNotTargetFrontmostFloatingWhenFocusIsTiled` —
   mirror the topology in the discovery's "Secondary structural risk": confirmed
   focus on tiled `T`, a different floating `F` is OS-frontmost; assert
   `toggleFocusedWindowFloating` acts on `T` (un-floats nothing, since `T` is
   already tiling) and leaves `F` untouched. This is the regression test for
   the "named `…FocusedWindow…` targets a non-focused window" case.

### `Tests/NehirTests/WMControllerFocusTests.swift` (add)

1. `managedCommandTargetPrefersConfirmedFocusOverFrontmostFloating` —
   confirmed tiled focus + frontmost floating → `.confirmedManagedFocus`, token
   == tiled.
2. `managedCommandTargetFallsBackToLayoutSelectionWhenNoConfirmedFocus` — no
   confirmed focus, viewport selection present → `.layoutSelection`.
3. `managedCommandTargetFallsBackToFrontmostWhenNoFocusAndNoSelection` — no
   confirmed focus, no selection, frontmost managed window present →
   `.frontmostManagedFallback`.

### `Tests/NehirTests/NiriLayoutHandlerTests.swift` (add)

1. `layoutCommandNoOpsWhenConfirmedFocusIsFloating` — confirmed floating focus
   + a tiled viewport selection; invoke `moveWindow(.left)` /
   `toggleFullscreen()` / `cycleSize(forward:)` / `setColumnWidth(.grow)` and
   assert the Niri tree is unchanged (the tiled node's geometry/column is not
   mutated) and the command returns without animating.
2. `layoutCommandActsOnSelectionWhenFocusIsTiled` — same topology but confirmed
   focus on the tiled node; assert the command mutates the expected node
   (regression guard that the guard did not over-fire).
3. `layoutCommandActsOnSelectionWhenNoConfirmedFocus` — no confirmed focus;
   assert the command still acts on the viewport selection (guard does not fire
   on nil focus).

### `Tests/NehirTests/WMControllerScratchpadTests.swift` (light touch)

1. `assignFocusedWindowToScratchpadUsesConfirmedFocus` — confirmed floating
   focus; assert the scratchpad assignment targets the floating window (already
   true today; pin it so Phase 1's alias collapse cannot regress it).

Test hygiene: keep all tests synthetic (no live AX/SkyLight); reuse the
existing `addLayoutPlanTestWindow` + `transitionWindowMode(... to: .floating ...)`
+ `setManagedFocus(...)` fixtures already used at `IPCCommandRouterTests.swift:629`.

## Validation

```bash
swift build
swift test --filter IPCCommandRouterTests
swift test --filter WMControllerFocusTests
swift test --filter WMControllerScratchpadTests
swift test --filter NiriLayoutHandlerTests
swift test --filter CommandHandlerTests
# Optional full sweep if the above are green:
swift test
```

Manual validation:

1. Single workspace, one tiled terminal `T` and one floated notes window `F`.
   Focus `F` (border on `F`).
2. Press `toggle floating` → `F` un-floats (matches intent).
3. Re-float `F`, focus `T`, then focus `F` again. Press `move left` /
   `set column width` / `toggle fullscreen` → `T` is **not** moved/resized/
   fullscreened (intentional no-op); a `layoutCommand.skipped
   reason=focusedFloating` event appears in a runtime dump/trace.
4. Focus `T`. Press `move left` / `set column width` → `T` reacts normally
   (guard did not over-fire).
5. Confirm the #12 scenario still holds: with `F` focused, IPC
   `move-focused-window` / `move-column-to-workspace` targets `F`.

Changeset (minor; confirm release policy): "Make focused-window commands target
the confirmed managed focus, and no-op layout commands when focus is floating."

## Risks and mitigations

- **High blast radius.** `managedCommandTargetToken()` feeds native-fullscreen,
  IPC move-window/move-column, scratchpad assign, and toggle-floating. The
  frontmost-floating removal only changes behavior in the narrow state
  (confirmed tiled focus + different frontmost floating window); the #12
  scenario (confirmed *floating* focus) is untouched. Mitigation: the new
  regression test (#4 in IPCCommandRouterTests) plus the preserved
  `toggleFocusedWindowFloatingTargetsFocusedFloatingWindowOverNiriSelection`.
- **Regressing #12.** The fix for #12 requires that a *focused floating*
  window be the move-to-workspace target. The new policy keeps confirmed
  floating focus at cascade step 1, so #12 is preserved. Mitigation: the manual
  validation step 5 plus the kept `:629` test.
- **Layout no-op feels broken to users.** Silent no-op (option (a)) is the
  least-surprising default given floating windows genuinely cannot be column-
  moved. If field feedback says it is confusing, upgrade to option (b) (border
  flash / affordance) as a follow-up — do not block on it here. Mitigation: the
  `layoutCommand.skipped` trace event makes the no-op observable in diagnostics
  immediately.
- **`selectedNodeId` is also the scroll/viewport anchor.** The Phase 4 guard
  only *reads* `confirmedManagedFocusToken` + entry mode and returns early; it
  does not mutate `selectedNodeId` or touch gesture-time pinning. Mitigation:
  the guard runs before any `state` mutation in `withNiriOperationContext`.
- **Scratchpad toggle divergence.** `toggleScratchpadWindow()` remains
  stored-token and focus-independent. This is intentional and is decided under
  backlog #7, not here. Mitigation: non-goal is stated; `assignFocusedWindow…`
  (the *assign* path) does use the unified policy.
- **Non-managed-focus case.** When `isNonManagedFocusActive` is true, the
  toggle/scratchpad commands today return `.notFound` via the cascade's
  fallbacks. The new policy does not change this (confirmed managed focus is
  nil → falls to layout selection → falls to frontmost). Mitigation: add a test
  asserting `.notFound`/no-op when no managed window is focused and an
  unmanaged app is frontmost, to pin the behavior explicitly.
- **Naming churn.** Collapsing `focusedManagedTokenForCommand()` is a private
  symbol; no external API impact. Mitigation: Phase 1 is gated on a clean
  `grep` showing zero remaining references.

## Follow-ups (out of scope)

- **Backlog #7** — decide whether `toggleScratchpadWindow()` should become
  focus-aware or stay stored-token; co-triage with this plan's assign-path
  policy.
- **Option (b) affordance** — visible feedback (border flash / HUD) when a
  layout command no-ops due to floating focus, if silent no-op proves confusing.
- **Automation surface alignment** — optionally unify Resolver C
  (`focusedOrFrontmostWindowTokenForAutomation`, `:1705`) with the new
  `managedCommandTarget()` contract; today it intentionally diverges for
  `WindowActionHandler`'s non-managed-focus preference.
- **Observability** — add a `.focusedFloating` `Source` case (or a debug
  counter) if field diagnosis needs to distinguish floating-focus targets from
  tiled-focus targets in runtime dumps.
