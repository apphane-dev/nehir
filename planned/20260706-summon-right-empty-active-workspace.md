# Summon Right into the active workspace when it has no anchor window

**Status:** planned.
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
