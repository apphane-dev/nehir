# Summon Right into the active workspace when it has no anchor window

**Status:** ✅ **shipped** — landed on `main` as `9cbc7db5` ("Summon Right into
the active workspace on the palette display", 2026-07-06), squashing the whole
`fix/summon-right-display-verify` stack (feature → palette-display targeting →
`NSScreen` hardening → diagnostic tracing → cross-workspace admission fix). Final
merge polish beyond the branch commits: the dead `pointerMonitorId(for:pointer:)`
helper was removed, the three per-commit changesets were consolidated into one
(`.changeset/…-summon-right-into-active-workspace-on-palette-display.md`), and the
summon `describe(...)` trace formatters were extracted into
`Sources/Nehir/Core/Diagnostics/SummonTraceFormatting.swift`. See the follow-up
section at the end for the full landed scope and the one remaining verification
caveat.
**Symptom:** In the command palette (Windows mode) the status line shows
"Enter jumps. **Shift-Enter unavailable for this session.**" and ⇧↩ (Summon
Right) is disabled whenever the currently active workspace has no managed anchor
window — i.e. an empty workspace, or one where the focused window is unmanaged
or lives on a different workspace.
**Desired behavior:** Shift-Enter should still be available in that case and
summon the selected window **into the currently active workspace** (appended as
the new rightmost column), instead of being disabled.

All source references were verified against the main Nehir source tree (HEAD
`06c0bf4e`, "Reveal a same-app focus switch that lands on a window on an
inactive workspace") on 2026-07-06. Re-verify before editing; line numbers
drift.

## TL;DR (root cause, inline)

Summon Right is gated by `isSummonRightAvailable`
(`Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift:315-317`), which
is just `summonAnchor != nil`. The anchor is computed once when the palette opens
by `resolveSummonAnchor(for:)`
(`CommandPaletteController.swift:413-433`):

```swift
static func resolveSummonAnchor(for wmController: WMController) -> CommandPaletteSummonAnchor? {
    guard let activeWorkspace = wmController.interactionWorkspace() else { return nil }
    let anchorToken = if let focusedToken = ...confirmedManagedFocusToken,
                         let entry = ...entry(for: focusedToken),
                         entry.workspaceId == activeWorkspace.id { focusedToken }
                      else { ...preferredWorkspaceFocusToken(in: activeWorkspace.id) }
    guard let anchorToken,
          let entry = ...entry(for: anchorToken),
          entry.workspaceId == activeWorkspace.id
    else { return nil }                       // <-- disables Summon Right
    return .init(token: anchorToken, workspaceId: activeWorkspace.id)
}
```

So the moment there is **no managed window in the active workspace to anchor
against**, it returns `nil`, `summonAnchor` is `nil`, `isSummonRightAvailable`
is `false`, the hint is dropped (`selectedWindowHint`, `:399-402`), the status
text switches to "unavailable for this session" (`windowsStatusText`,
`:404-411`), and the ⇧↩ trigger returns no action
(`:915-918`, `guard let summonAnchor else { return nil }`).

The downstream summon primitive is anchor-centric too. In
`WindowActionHandler.summonWindowRight(handle:anchorToken:anchorWorkspaceId:)`
(`Sources/Nehir/Core/Controller/WindowActionHandler.swift:410-434`) → 
`summonWindowRightInNiri(...)` (`:511-556`), the insert position is derived
purely from the anchor column:

```swift
let insertIndex = focusedColumnIndex + 1
```

There is no path that summons into a workspace **without** an anchor column.

**Fix shape:** make the anchor's token optional. When the active workspace has
no anchor window, still return an anchor carrying only the workspace id (so
Summon Right stays enabled), and teach the summon primitive to append the window
as a new rightmost column (`insertIndex = columns(in: targetWorkspaceId).count`)
when there is no anchor column. The engine already clamps `insertIndex` to
`0 ... cols.count` and appends when `clampedIndex >= cols.count`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:174-180`), so
appending into an empty or non-empty workspace is already supported at the
lowest layer.

## Scope

### Files to change

1. `Sources/Nehir/UI/CommandPalette/CommandPaletteController.swift`
   - **`CommandPaletteSummonAnchor` (`:47-50`).** Change `let token: WindowToken`
     to `let token: WindowToken?`. The struct stays `Equatable`. Semantics: a
     non-nil token means "summon to the right of this specific window"; a nil
     token means "summon into `workspaceId` (append rightmost)".
   - **`resolveSummonAnchor(for:)` (`:413-433`).** Only require an active
     interaction workspace. Keep the existing anchor-token resolution, but when
     no anchor token resolves in the active workspace, return
     `.init(token: nil, workspaceId: activeWorkspace.id)` instead of `nil`.
     Return `nil` **only** when `interactionWorkspace()` is `nil`. Concretely,
     drop the `guard let anchorToken … else { return nil }` early-out
     (`:425-430`) and instead compute an optional validated token:
     ```swift
     let validatedToken: WindowToken? = anchorToken.flatMap { token in
         guard let entry = wmController.workspaceManager.entry(for: token),
               entry.workspaceId == activeWorkspace.id else { return nil }
         return token
     }
     return .init(token: validatedToken, workspaceId: activeWorkspace.id)
     ```
   - **`Environment.summonWindowRight` closure (`:110-118`).** Change the token
     parameter type from `WindowToken` to `WindowToken?` and thread it through
     to `controller.summonCommandPaletteWindowRight(...)`.
   - **`performSelectionAction` summon case (`:950-956`).** No structural change;
     it already forwards `summonAnchor.token` / `summonAnchor.workspaceId`, which
     are now `WindowToken?` / id. Confirm the call still type-checks against the
     updated closure/method signatures.
   - **`selectionAction` alternate branch (`:915-918`).** Unchanged: it still
     guards `guard let summonAnchor` (the whole anchor), which is now non-nil for
     the empty-workspace case, so ⇧↩ produces a `.summonWindowRight` action.

2. `Sources/Nehir/Core/Controller/WMController.swift`
   - **`summonCommandPaletteWindowRight(_:anchorToken:anchorWorkspaceId:)`
     (`:3411-3421`).** Change `anchorToken: WindowToken` to
     `anchorToken: WindowToken?` and forward it unchanged to
     `windowActionHandler.summonWindowRight(...)`.

3. `Sources/Nehir/Core/Controller/WindowActionHandler.swift`
   - **`summonWindowRight(handle:anchorToken:anchorWorkspaceId:)`
     (`:410-434`).** Change `anchorToken: WindowToken` to
     `anchorToken: WindowToken?`. When `anchorToken` is nil, skip the anchor
     `entry` lookup/validation (`:417-418`) and the `token != anchorToken` guard
     (`:425`); still require `targetEntry = entry(for: handle)` for
     `sourceWorkspaceId`. Pass the optional token through to
     `summonWindowRightInNiri(..., focusedToken: anchorToken)`.
   - **`summonWindowRightInNiri(token:sourceWorkspaceId:targetWorkspaceId:focusedToken:)`
     (`:511-556`).** Change `focusedToken: WindowToken` to
     `focusedToken: WindowToken?`. Compute `insertIndex`:
     - when `focusedToken` is non-nil: resolve `focusedNode` / `focusedColumn` /
       `focusedColumnIndex` exactly as today and set
       `insertIndex = focusedColumnIndex + 1`;
     - when `focusedToken` is nil: set
       `insertIndex = engine.columns(in: targetWorkspaceId).count` (append as the
       new rightmost column). `columns(in:)` is at
       `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:268`.
     The rest of the method (same-workspace insert vs cross-workspace move +
     insert, then `commitSummonedWindowFocus`) is unchanged; both branches call
     `insertWindowInNewColumn(handle:insertIndex:in:)`, whose engine
     implementation clamps and appends safely
     (`NiriLayoutEngine+ColumnOps.swift:174-180`).

### Non-goals / do-not-touch fences

- **Do not change the IPC/no-anchor overload
  `summonWindowRight(handle:)` (`WindowActionHandler.swift:392-408`).** It
  intentionally requires a confirmed managed focus in the current workspace and
  serves the IPC surface (`Sources/Nehir/IPC/IPCCommandRouter.swift:268`); its
  contract is out of scope. Only the explicit-anchor overload
  (`:410-434`) and its Niri helper (`:511-556`) change.
- **Do not change the status/hint copy.** "Shift-Enter summons right." reads
  correctly for the append-rightmost case; `windowsStatusText` (`:404-411`) and
  `selectedWindowHint` (`:399-402`) already key off the boolean and need no edit
  beyond the availability now being true more often. (If field feedback finds
  "summons right" confusing for an empty workspace, revisit as a follow-up — do
  not block on it.)
- **Do not** add a distinct summon animation or focus policy for the no-anchor
  case; reuse `commitSummonedWindowFocus(... startNiriScrollAnimation: true)`
  (`WindowActionHandler.swift:536`, `:554`) as-is.
- **Do not** change `preferredWorkspaceFocusToken(in:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:1824`) — the fix is that
  a nil result no longer disables the feature, not that the resolver should
  return something new.

## Exact implementation plan

Phased; each phase is independently buildable.

### Phase 1 — Optional anchor token end to end (no behavior change yet)

1. `CommandPaletteController.swift`: make `CommandPaletteSummonAnchor.token`
   optional (`:48`); update the `Environment.summonWindowRight` closure token
   param to `WindowToken?` (`:110`).
2. `WMController.swift`: make `summonCommandPaletteWindowRight` `anchorToken`
   optional (`:3413`).
3. `WindowActionHandler.swift`: make both `summonWindowRight(handle:anchorToken:
   anchorWorkspaceId:)` (`:413`) and `summonWindowRightInNiri(... focusedToken:)`
   (`:515`) accept optional tokens; inside the Niri helper, branch `insertIndex`
   on `focusedToken` presence as specified above.
4. At this point `resolveSummonAnchor` still returns `nil` in the no-anchor case,
   so runtime behavior is unchanged; this phase only widens the types.

**Gate:** `swift build` green; existing tests green.

### Phase 2 — Enable Summon Right for the anchorless active workspace (behavior change)

1. `CommandPaletteController.swift`: rewrite `resolveSummonAnchor(for:)`
   (`:413-433`) to return a `token: nil` anchor when the active workspace has no
   valid anchor token, and `nil` only when there is no interaction workspace.
2. Verify the alternate-selection path (`:915-918`) now yields a
   `.summonWindowRight` action, `isSummonRightAvailable` is `true`
   (`:315-317`), the ⇧↩ hint shows, and the status text reads "summons right".

**Gate:** the new/updated tests below green; existing summon tests green.

## Tests

### `Tests/NehirTests/CommandPaletteControllerTests.swift` (add)

The existing `windowsStatusTextReflectsSummonAvailability` (`:527-535`),
`selectedWindowHintReflectsSummonAvailability` (`:517-524`), and the ⇧↩ trigger
mapping test `selectionTriggerHandlesReturnAndKeypadEnter` (`:537+`) already
cover the boolean-parametrized surface and stay unchanged (re-run to confirm).
Add coverage for the new anchor semantics:

1. `resolveSummonAnchorReturnsWorkspaceOnlyAnchorWhenNoManagedWindow` — with an
   active interaction workspace that has no managed anchor window (no confirmed
   managed focus in it and `preferredWorkspaceFocusToken` nil), assert
   `resolveSummonAnchor(for:)` returns a non-nil anchor whose `token == nil` and
   `workspaceId == activeWorkspace.id`.
2. `resolveSummonAnchorReturnsTokenAnchorWhenManagedWindowPresent` — with a
   managed window focused in the active workspace, assert the anchor's `token`
   equals that window's token (regression guard that the common path is
   unchanged).
3. `resolveSummonAnchorReturnsNilWhenNoInteractionWorkspace` — with no
   interaction workspace, assert `resolveSummonAnchor(for:)` returns `nil`
   (feature genuinely unavailable).

Use the existing command-palette test fixtures/`WMController` builders already
used in this file; keep everything synthetic (no live AX/SkyLight).

### `Tests/NehirTests/WindowActionHandlerTests.swift` (add — or the existing summon test file if one exists; confirm when implementing)

1. `summonWindowRightAppendsToRightmostColumnWhenNoAnchor` — active workspace
   `W` containing tiled columns `[A, B]`; call
   `summonWindowRight(handle: X, anchorToken: nil, anchorWorkspaceId: W)` where
   `X` is a window on another workspace. Assert `X` is inserted as the **new
   rightmost** column of `W` (column order `[A, B, X]`) and focus commits to
   `X`.
2. `summonWindowRightIntoEmptyActiveWorkspaceWithNoAnchor` — active workspace
   `W` with **no** columns; summon `X` from elsewhere with `anchorToken: nil`.
   Assert `X` becomes the sole column of `W` and is focused. (Exercises the
   `insertIndex = 0 == cols.count` append path and the cross-workspace
   move+insert branch, `WindowActionHandler.swift:540-554`.)
3. `summonWindowRightStillInsertsRightOfAnchorWhenTokenPresent` — regression
   guard: with anchor column `A` focused in `W` (`[A, B]`), summoning `X` with
   `anchorToken: A` inserts `X` at index 1 (`[A, X, B]`), matching today's
   `focusedColumnIndex + 1` behavior. Pin this so Phase 1's type widening cannot
   regress the anchored path.

If the repo already has a dedicated summon test suite (grep
`summonWindowRight` under `Tests/`), add these cases there instead of creating a
new file, to match existing fixtures.

## Validation

```bash
swift build
swift test --filter CommandPaletteControllerTests
swift test --filter WindowActionHandlerTests
# Optional full sweep if the above are green:
swift test
```

Manual validation:

1. Switch to an **empty** workspace (no windows). Open the command palette
   (Windows mode). Confirm the status line reads
   "Enter jumps. Shift-Enter summons right." and the ⇧↩ "Summon Right" hint is
   shown on the selected window row.
2. Select a window that lives on another workspace and press ⇧↩. Confirm the
   window is summoned into the (previously empty) active workspace as its only
   column and gets focus.
3. On a workspace that already has columns `[A, B]`, open the palette with the
   focus on an **unmanaged** app (so no anchor). Summon a window `X` and confirm
   it lands as the new rightmost column `[A, B, X]`.
4. Regression: with a managed window focused in the active workspace, summon `X`
   and confirm it still lands immediately to the **right of the focused window**
   (existing behavior), not at the far right.

Changeset (minor; confirm release policy): "Allow Summon Right to summon into
the active workspace when it has no anchor window."

## Risks and mitigations

- **Type widening blast radius.** `CommandPaletteSummonAnchor.token`,
  `summonCommandPaletteWindowRight`, `summonWindowRight(handle:anchorToken:
  anchorWorkspaceId:)`, and `summonWindowRightInNiri` all move to optional
  tokens. The IPC no-anchor overload (`summonWindowRight(handle:)`) is a
  *separate* method and is fenced out. Mitigation: Phase 1 is a pure
  type/compile change with all existing tests green before any behavior change.
- **Anchored path regression.** The most important invariant is that summoning
  with a real anchor still inserts at `focusedColumnIndex + 1`. Mitigation: test
  #3 in the WindowActionHandler suite pins it, and the non-nil branch of
  `summonWindowRightInNiri` is byte-for-byte the current logic.
- **Empty-workspace append correctness.** `insertIndex = cols.count` relies on
  the engine's clamp/append (`NiriLayoutEngine+ColumnOps.swift:174-180`), which
  already handles `cols.count == 0`. Mitigation: test #2 exercises the empty
  workspace explicitly.
- **Summoning a window that is already the only window in the active
  workspace.** With `anchorToken: nil` this re-inserts it into a new rightmost
  column — effectively a no-op reshuffle. Acceptable; not a corruption. If it
  proves surprising, add an early-out when `targetEntry.workspaceId ==
  anchorWorkspaceId` and it is already the sole column — treat as follow-up, not
  a blocker.
- **Copy accuracy.** "summons right" is slightly loose for an empty workspace
  (nothing to be right *of*). Deliberately left unchanged to keep scope minimal;
  listed as a follow-up.

## Follow-ups (out of scope)

- Consider workspace-aware copy for the anchorless case (e.g. "Shift-Enter
  summons here") if users find "summons right" confusing on an empty workspace.
- Consider whether the IPC `summonWindowRight(handle:)`
  (`WindowActionHandler.swift:392-408`) should gain the same
  summon-into-active-workspace fallback for parity with the palette.

---

## Follow-up (2026-07-06): fix cross-workspace summon admission drop

**Status:** ✅ shipped in the same squashed merge `9cbc7db5` (2026-07-06). The
cross-workspace commit now drives
`commitWorkspaceTransition(affectedWorkspaces:{source,target},
reason:.workspaceTransition)` focusing the summoned token, relying on
`moveWindow`'s `prepareMovedWindowTargetViewport` for the revealed viewport +
remembered focus (no redundant session patch). Regression test
`RefreshRoutingTests.crossMonitorPaletteSummonRetainsTargetColumnAcrossFollowUpRelayout`
guards the column-drop across a follow-up relayout. **Remaining caveat:** the
synthetic 2-monitor test reproduces the drop mechanism, but real
vertically-stacked multi-monitor AppKit coordinate mapping (`NSScreen`) could not
be unit-tested without hardware — validate with one on-device Shift-Enter capture
on the empty second display (expect `commit path=crossWorkspace` and no
`context=focused_admission` dependency).

**Landed branch history (squashed into `9cbc7db5`):**

- `b4bc69b9` — summon into anchorless active workspace (append rightmost column).
- `c838c9cc` — target the palette's monitor, not the interaction monitor.
- `bfd70189` — harden: single `paletteScreen()` feeds both `positionPanel` and
  the summon monitor mapping (AppKit-space `NSScreen` resolution, not CG-space
  `Monitor.frame`).
- `19e55b90` — Summon Right diagnostic tracing (kept; formatters later extracted
  to `SummonTraceFormatting.swift`).
- `b8994c80` — fix cross-workspace admission drop.

Runtime instrumentation proved the display targeting is correct; the follow-on
bug was admission, not targeting.

All source references below were verified against `fix/summon-right-display-verify`
HEAD `19e55b90` on 2026-07-06. Line numbers drift (instrumentation shifted
them) — re-verify before editing.

### Symptom

On a 2-monitor setup, a **cross-workspace** Summon Right (selected window lives
on another workspace/monitor; palette open on the *empty* active workspace of a
second display) summons the window into the correct destination workspace, but
the window is **misplaced and not admitted** to that workspace — it stays resting
on the source display at its old frame, and the destination workspace shows no
column — **until the user manually manipulates it** (scroll/focus), at which
point a focus-driven admission finally moves and admits it.

The **same-workspace** summon (append into the current workspace) is unaffected.

### Evidence (inlined from a runtime trace; self-contained)

Topology: display 1 (built-in, main) `frame=(0,0,2056,1329)`; display 2 (DELL)
`frame=(-1171,1329,2560,1440)` stacked below. Palette opened on display 2 over
empty workspace `2059F643` (workspace "6"); interaction monitor was display 1,
interaction workspace `FAED2700` (workspace "1").

Summon instrumentation (`## Niri insertion trace`):

```
commandPalette.palette.show pointerMonitor=display2 interactionMonitor=display1
    anchor=token=nil,workspace=2059F643   ← correct target (display 2, empty ws)
summonRight.dispatch targetWorkspace=2059F643 focusedToken=nil
summonRight.insertPlan mode=append targetColumnsBefore=0 insertIndex=0 targetWorkspace=2059F643
summonRight.moved targetWorkspace=2059F643 columnsAfterMove=1     ← inserted OK
summonRight.commit path=crossWorkspace targetWorkspace=2059F643
```

Then, ~2 s later while the user 3-finger-scrolls the empty display-2 workspace:

```
workspace=6 id=2059F643 ... columns=0 layout=no-columns    ← the column FELL OUT
```

And only after the manual manipulation (~11 s after summon):

```
event=window_admitted token=w8149 workspace=2059F643 context=focused_admission
```

Throughout, the **model stayed correct** — the moved window's entry always read
`desired=workspace=2059F643,monitor=display2`. By trace end the window is framed
on display 2 (`liveAXFrame≈{{-909,1336},{2035,1371}}`, i.e. display-2
coordinates). So this is **not** model/workspace-assignment corruption; it is a
**physical-frame + niri-admission gap**: the moved window's frame is never pushed
to the destination monitor by the summon's own refresh, so the next reconcile
does not retain its freshly-inserted column, and it takes a focus-driven
admission to physically move + re-admit it.

### Root cause (source-backed)

The cross-workspace summon commit uses the wrong refresh primitive.

- Cross-workspace branch of
  `WindowActionHandler.summonWindowRightInNiri(...)` (~`WindowActionHandler.swift:600-641`):
  `controller.workspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)`
  then `niriLayoutHandler.insertWindowInNewColumn(...)` then
  `commitSummonedWindowFocus(...)`.
- `WorkspaceNavigationHandler.moveWindow(handle:toWorkspaceId:)`
  (`WorkspaceNavigationHandler.swift:918-940`) is, **by its own contract, a
  refresh-free primitive** — it transfers the source engine node, calls
  `reassignManagedWindow`, and `prepareMovedWindowTargetViewport`, but does
  **not** drive the hide/show/frame refresh. The sibling
  `moveWindowFromBar(...)` (`:952-973`) carries the explicit doc-comment
  (`:942-950`) that it, *unlike* the summon-shared `moveWindow`, "always drives
  the hide/show/frame refresh itself, **so the moved window does not remain
  physically resting on the source workspace until an unrelated refresh applies
  the assignment**" — which is exactly our symptom.
- The summon's own refresh, `commitSummonedWindowFocus(...)`
  (`WindowActionHandler.swift:656-677`), issues
  `layoutRefreshController.requestRefresh(reason: .layoutCommand)` with **empty
  `affectedWorkspaceIds`** and focuses the summoned token. Empty
  `affectedWorkspaceIds` falls back to `activeWorkspaceIds`
  (`LayoutRefreshController.swift:1128`). This is sufficient for the
  same-workspace case (the window is already admitted on that monitor) but does
  **not** perform the cross-monitor hide-on-source / show+frame-on-target
  admission the moved window needs.
- The proven-correct cross-workspace/monitor move commit is
  `commitNonFollowingWindowMove(...)`
  (`WorkspaceNavigationHandler.swift:980-1013`): it recovers source focus, stops
  the source scroll animation, `prepareMovedWindowTargetViewport`, then
  `layoutRefreshController.commitWorkspaceTransition(affectedWorkspaces:{source,
  target}, reason:.workspaceTransition)`. `commitWorkspaceTransition`
  (`LayoutRefreshController.swift:849-860`) is an immediate relayout scoped to
  **both** the source and target workspaces — this is what actually applies the
  cross-monitor frame and admission.

Both `.layoutCommand` and `.workspaceTransition` share
`route == .immediateRelayout` (`RefreshReason.swift:104-106`), so the fix is
**not** the route — it is (a) scoping the relayout to **both** source and target
workspaces, and (b) using the workspace-transition commit that applies the
physical frame to the destination monitor, instead of the same-workspace-oriented
`commitSummonedWindowFocus`.

### Proposed fix

In the **cross-workspace** branch of `summonWindowRightInNiri` only (leave the
same-workspace branch on `commitSummonedWindowFocus`), replace the
`commitSummonedWindowFocus(...)` call with a workspace-transition commit that
mirrors `commitNonFollowingWindowMove` but **focuses the summoned window** (and
follows interaction to the target monitor) instead of recovering source focus:

- Drive `layoutRefreshController.commitWorkspaceTransition(affectedWorkspaces:
  {sourceWorkspaceId, targetWorkspaceId}, reason:.workspaceTransition)` with a
  `postLayout` that focuses the summoned `token` on the target workspace.
- Keep `prepareMovedWindowTargetViewport` (already done inside `moveWindow`) and
  the `applySessionPatch(rememberedFocusToken: token)` so the summoned window is
  the remembered focus of the target workspace.
- Preserve `startScrollAnimation(for: targetWorkspaceId)` behaviour if still
  needed after the transition (verify it does not fight the transition relayout).
- Do **not** regress the same-workspace path (it must stay on
  `commitSummonedWindowFocus`, which works today).

Prefer extracting the shared commit so summon and bar-move do not duplicate the
transition logic — but a focused, duplicated commit in `summonWindowRightInNiri`
is acceptable if extraction widens the blast radius.

### Open question for the implementer to confirm at runtime (instrumentation exists)

The exact reason the freshly-inserted niri column is *dropped* by the next
reconcile (rather than merely un-framed) is not fully pinned from static reading.
Before finalizing, confirm with the `## Niri insertion trace` instrumentation
(already on `19e55b90`) plus a targeted capture that, after switching to the
workspace-transition commit: (1) `summonRight.commit path=crossWorkspace` still
fires, (2) the destination workspace retains `columns=1` across the following
reconcile (no `columns=0` regression), and (3) the window is framed on the target
monitor without any manual manipulation (no dependency on
`context=focused_admission`). If the column still drops, the culprit is the niri
root rebuild reading observed-vs-desired monitor mismatch, and the fix must also
ensure the destination frame is applied *before* the reconcile that rebuilds the
target root.

### Tests

- Extend `Tests/NehirTests/` summon coverage (the cross-workspace summon path):
  a synthetic 2-monitor + 2-workspace controller (reuse
  `makeLayoutPlanPrimaryTestMonitor` / `makeLayoutPlanSecondaryTestMonitor` and
  the `WorkspaceConfiguration(.main/.secondary)` fixture already used in
  `RefreshRoutingTests`), summon a window from the source workspace into the
  empty secondary workspace, and assert the destination workspace's niri engine
  retains exactly one column **after** a follow-up relayout/reconcile (not just
  immediately after insert), and that the moved window's entry monitor is the
  target monitor. This is the regression guard for the "column falls out" drop.
- Keep the existing `CommandPaletteControllerTests` display-targeting tests
  green.

### Gates & pre-existing failures

- Fast: `mise run build`. Full: `mise run check`.
- **Known pre-existing failures on this branch's base — do NOT attribute to this
  change** (confirm they reproduce identically on a clean checkout):
  `RefreshRoutingTests.nativeFullscreenSpaceChangeRetainsMultiColumnNiriOrderWithSameWindowId`
  (6 issues) and
  `AXEventHandlerTests.nativeFullscreenReplacementCreateRetriesWhenWindowServerInfoIsInitiallyUnavailable`
  (3 issues). Everything else must be green.

### Fences

- Change **only** the cross-workspace branch of `summonWindowRightInNiri`.
- Do **not** touch the same-workspace summon branch, the display-targeting
  resolution (`paletteScreen`/`paletteMonitorId`/`resolveSummonAnchor`), the IPC
  `summonWindowRight(handle:)` overload, or the status/hint copy.
- Keep the diagnostic instrumentation (`19e55b90`) in place — it is the
  verification tool.
