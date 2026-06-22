# OmniWM #295 — Preserve Niri window width when moved

**Status:** planned
**Source discovery:** `discovery/20260616-omniwm-295-niri-window-width-preservation.md`
**Upstream reference:** <https://github.com/BarutSRB/OmniWM/issues/295>
**Related (same machinery, different scenario):** `completed/20260619-workspace-assignment-lone-window-width-and-reveal.md` and `completed/20260619-workspace-assignment-lone-window-width-cache-leak.md` — these introduced the post-move `clearLoneWindowLayoutWidthOverride()` loop the fix must compose with.

All file/line references were re-verified against the main Nehir source tree
(`6ba6760f`) on 2026-06-21. Re-verify before editing; line numbers drift.

## TL;DR

When a single window is moved to another workspace (often on another monitor)
via `NiriLayoutEngine.moveWindowToWorkspace(...)`, the engine creates or claims a
target column and unconditionally calls `initializeNewColumnWidth(...)`, which
discards the moved window's source column width and resets
`hasManualSingleWindowWidthOverride = false`. With the default lone-window
`.fill` policy, an empty target workspace then renders the moved window at 100%
width — exactly the OmniWM #295 report: a 50% window becomes full-width after
the move.

Fix it in one place: when the **source** column has a manual width override
(`hasManualSingleWindowWidthOverride == true`), copy the source column's width
state onto the freshly created/claimed target column instead of resetting it.
The existing private `copyColumnWidthState(from:to:)` helper already does exactly
this for column-split/expel moves; expose it through a small internal wrapper and
call it from the workspace-move path. When the source has no manual override,
behavior is unchanged (the target workspace default still applies). Because the
copied width is a `ProportionalSize` (e.g. `.proportion(0.5)`), it naturally
re-resolves against the target monitor's working width on the next layout pass,
giving the issue's requested "50% relative to the current screen" behavior.

Whole-column workspace moves (`moveColumnToWorkspace`) move the existing
`NiriContainer` and are already unaffected.

## Discovery corrections / decisions

The discovery's recommendation is right; these corrections are needed before
implementation:

1. **Line-number drift (cosmetic, re-verified):**
   - `moveWindowToWorkspace(...)` lives in
     `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:19-67`
     (discovery said `:13-44`). The target-column create/claim block that calls
     `initializeNewColumnWidth` is at lines `40-49`; `window.detach()` is at
     line `38`; `targetColumn.appendChild(window)` is at line `50`.
   - `initializeNewColumnWidth(...)` is at
     `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:235-247` (discovery
     said `:223-233`).
   - `resolvedSingleWindowWidth(for:in:gaps:)` is at
     `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:707-720` (discovery said
     `:700-707`). The `hasManualSingleWindowWidthOverride` guard is at line
     `716-718`; the `cachedWidth`-returning branch is at line `720`.
   - The regression test `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn`
     is at `Tests/NehirTests/NiriLayoutEngineTests.swift:3828-3856` (discovery
     said `:3670-3697`).
   - Controller entry points are at
     `Sources/Nehir/Core/Controller/WorkspaceNavigationHandler.swift:909`
     (`moveWindowToWorkspaceOnMonitor(workspaceIndex:monitorDirection:)`),
     `:914+` (the `rawWorkspaceID` overload), and `:492+`
     (`transferWindowFromSourceEngine(token:from:to:)`). These are call-site
     context only; this plan does **not** require controller-side changes.

2. **`copyColumnWidthState` has drifted (load-bearing).** The discovery quoted
   the helper without its `clearLoneWindowLayoutWidthOverride()` call. The
   current helper at
   `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift:37-48` is:

   ```swift
   private func copyColumnWidthState(from sourceColumn: NiriContainer, to targetColumn: NiriContainer) {
       targetColumn.width = sourceColumn.width
       targetColumn.presetWidthIdx = sourceColumn.presetWidthIdx
       targetColumn.isFullWidth = sourceColumn.isFullWidth
       targetColumn.savedWidth = sourceColumn.savedWidth
       targetColumn.hasManualSingleWindowWidthOverride = sourceColumn.hasManualSingleWindowWidthOverride
       targetColumn.cachedWidth = 0
       targetColumn.clearLoneWindowLayoutWidthOverride()
       targetColumn.widthAnimation = nil
       targetColumn.targetWidth = nil
   }
   ```

   The `targetColumn.clearLoneWindowLayoutWidthOverride()` call is desirable
   here: `loneWindowLayoutWidthOverride` is a pixel cache tied to the source
   monitor's working width and must not be carried across monitors. Keep the
   helper as-is.

3. **Discovery omitted the post-append loop added by the completed workspace-
   assignment fix.** `moveWindowToWorkspace` now also runs, after
   `targetColumn.appendChild(window)` (lines `51-55`):

   ```swift
   if targetRoot.allWindows.count != 1 {
       for column in targetRoot.columns where !column.hasManualSingleWindowWidthOverride {
           column.clearLoneWindowLayoutWidthOverride()
       }
   }
   ```

   This loop composes cleanly with the fix: when the source had a manual
   override, the copied target column has `hasManualSingleWindowWidthOverride
   == true` and is skipped by the loop; the lone-window render path then uses
   the freshly re-cached `cachedWidth` (resoled against the target monitor).
   When the source had no manual override, the loop behavior is unchanged.
   No edit to this loop is required.

4. **Decision on the discovery's open questions:**
   - **Preserve only on manual override.** Copy the source column width state
     exclusively when `sourceColumn.hasManualSingleWindowWidthOverride == true`.
     Rationale: the issue is specifically about losing a *user-resized* width.
     If the source is still at its workspace default, the current reset-to-
     target-default behavior is the least surprising (a window at workspace A's
     default 0.7 should not impose 0.7 on workspace B whose default is 0.5).
     This also minimizes blast radius — the existing regression test continues
     to hold.
   - **Fixed pixel widths are copied as-is.** `ProportionalSize.fixed` is part
     of `column.width` and `copyColumnWidthState` already copies it. This
     matches `moveColumnToWorkspace`, which trivially preserves fixed widths
     because the column object moves. No special-casing.
   - **Non-empty target workspace also preserves manual width.** When the
     target already has windows, `claimEmptyColumnIfWorkspaceEmpty` returns
     `nil`, a brand-new column is created for the moved window, and that column
     gets the source's manual width state. This is consistent Niri-like
     behavior and avoids surprises when moving into an occupied workspace.

## Scope

### Files to change

1. `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`
   - Add an internal helper next to the existing private `copyColumnWidthState`
     (around line `48`) that picks between copy and reset based on the source
     column's manual-override flag:

     ```swift
     /// Applies the source column's width state to a freshly created/claimed
     /// target column when the user manually resized the source, so individual
     /// window workspace moves preserve width (OmniWM #295). Falls back to the
     /// workspace default reset otherwise.
     func applySourceColumnWidthOrReset(
         from sourceColumn: NiriContainer,
         to targetColumn: NiriContainer,
         in workspaceId: WorkspaceDescriptor.ID
     ) {
         if sourceColumn.hasManualSingleWindowWidthOverride {
             copyColumnWidthState(from: sourceColumn, to: targetColumn)
         } else {
             initializeNewColumnWidth(targetColumn, in: workspaceId)
         }
     }
     ```

   - `copyColumnWidthState` itself stays `private` to this file; the new
     wrapper is the only call site that needs cross-file visibility.

2. `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift`
   - In `moveWindowToWorkspace(...)` (lines `40-49`), replace the two
     `initializeNewColumnWidth(...)` calls with calls to the new helper. The
     `sourceColumn` is already captured at line `29` via
     `findColumn(containing:in:)`, before `window.detach()` at line `38`, so
     its width state is still readable at the target-column setup point. After
     the edit the block reads:

     ```swift
     let targetColumn: NiriContainer
     if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
         applySourceColumnWidthOrReset(from: sourceColumn, to: existingColumn, in: targetWorkspaceId)
         targetColumn = existingColumn
     } else {
         let newColumn = NiriContainer()
         applySourceColumnWidthOrReset(from: sourceColumn, to: newColumn, in: targetWorkspaceId)
         targetRoot.appendChild(newColumn)
         targetColumn = newColumn
     }
     targetColumn.appendChild(window)
     ```

   - Leave the post-append `clearLoneWindowLayoutWidthOverride` loop
     (lines `51-55`), `cleanupEmptyColumn(sourceColumn, ...)` (line `57`), and
     all selection/`WorkspaceMoveResult` logic untouched.
   - `moveColumnToWorkspace(...)` (lines `70-118`) is unchanged: it moves the
     existing `NiriContainer`, so no width state needs to be reset or copied.

3. `Tests/NehirTests/NiriLayoutEngineTests.swift`
   - Add positive-path tests for the new behavior (see `## Tests`).
   - Keep `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn`
     (lines `3828-3856`) as-is: its source column has no manual override, so it
     now documents the fallback branch of the fix. No rename, no assertion
     change — it stays green.

### Non-goals

- Do **not** change `moveColumnToWorkspace` — whole-column moves already
  preserve width and selection correctly.
- Do **not** preserve width when the source has no manual override. Default-
  width windows keep using the target workspace's default (current behavior).
- Do **not** special-case fixed pixel widths across monitor sizes; they are
  copied as-is, matching column moves.
- Do **not** touch the controller path
  (`WorkspaceNavigationHandler.transferWindowFromSourceEngine`,
  `moveWindowToWorkspaceOnMonitor`) — the bug and the fix are entirely inside
  the layout engine.
- Do **not** add a setting/toggle for the behavior; preserving a user-set
  width is the expected Niri-like default.
- Do **not** reconcile `loneWindowLayoutWidthOverride` across monitors beyond
  clearing it (already done by `copyColumnWidthState`); the next layout pass
  on the target monitor re-caches it from the copied proportional width.
- Do **not** change preset-width matching, the lone-window policy, or the
  post-append `clearLoneWindowLayoutWidthOverride` loop.

## Exact implementation plan

### Phase 1 — Expose a width-copy-or-reset helper in `+ColumnOps.swift`

1. Open `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ColumnOps.swift`.
2. Immediately after the closing brace of `copyColumnWidthState` (line `48`),
   add the internal helper `applySourceColumnWidthOrReset(from:to:in:)` quoted
   in `Scope` above.
3. Confirm it compiles: it calls `copyColumnWidthState` (private, same file)
   when the source flag is set, otherwise `initializeNewColumnWidth`
   (internal, declared in `NiriLayoutEngine.swift`).

### Phase 2 — Route the workspace-move path through the helper

1. Open `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift`.
2. In `moveWindowToWorkspace(...)` (line `19`), replace the body of the
   target-column create/claim block (lines `40-49`) so both branches call
   `applySourceColumnWidthOrReset(from: sourceColumn, to: <column>, in:
   targetWorkspaceId)` instead of `initializeNewColumnWidth(<column>, in:
   targetWorkspaceId)`. The exact replacement text is in `Scope` above.
3. Do not reorder any other statements. In particular, `window.detach()`
   (line `38`) stays before the target-column setup so that
   `claimEmptyColumnIfWorkspaceEmpty` sees a target workspace that may have
   become empty for unrelated reasons; the source column's width fields are
   already captured in the `sourceColumn` reference and are not affected by
   detaching the child window.
4. Build: `swift build`.

### Phase 3 — Add tests

Add the four tests listed under `## Tests` to
`Tests/NehirTests/NiriLayoutEngineTests.swift`, near the existing
`moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn` test (around
line `3828`).

### Phase 4 — Validate end-to-end

Run the validation commands under `## Validation`. Manually verify on a
two-monitor host: resize a window to ~50% on monitor A, move it to a workspace
on monitor B, confirm it renders at ~50% of monitor B's working width (not
100%), and confirm repeat moves back and forth are stable.

## Tests

All in `Tests/NehirTests/NiriLayoutEngineTests.swift`, near line `3828`. Use
the same fixtures as `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn`
(`NiriLayoutEngine(balancedColumnCount: 3)`, `makeTestHandle()`,
`engine.addWindow(...)`, two `UUID` workspace ids, fresh `ViewportState`s).

1. **`moveWindowToWorkspacePreservesManualSourceColumnWidthIntoEmptyTarget`**
   - Add one window to `sourceWorkspaceId`, grab its column via
     `engine.column(of:)`.
   - Set `column.width = .proportion(0.5)`, `column.hasManualSingleWindowWidthOverride = true`,
     and a non-nil `column.presetWidthIdx` (e.g. `2`) to model a user resize.
   - Move the window to an empty `targetWorkspaceId`.
   - Expect the single target column's `width == .proportion(0.5)`,
     `hasManualSingleWindowWidthOverride == true`, `presetWidthIdx == 2`.
   - Locks in: manual source width is preserved on move into an empty target.

2. **`moveWindowToWorkspacePreservesManualWidthIntoClaimedEmptyColumn`**
   - Pre-seed `targetWorkspaceId` with an empty root and an empty placeholder
     column (mirror how `ensureRoot`/`claimEmptyColumnIfWorkspaceEmpty` behave:
     `engine.roots[targetWorkspaceId] = NiriRoot(workspaceId: targetWorkspaceId)`
     and append an empty `NiriContainer`).
   - Source column has a manual override (`.proportion(0.5)`, flag `true`).
   - Move the window.
   - Expect the **claimed** column (identity-equal to the placeholder) to end
     up with the source width state; expect exactly one column in the target.
   - Locks in: the `claimEmptyColumnIfWorkspaceEmpty` branch also preserves
     width.

3. **`moveWindowToWorkspacePreservesManualWidthIntoNonEmptyTarget`**
   - Add a window to `targetWorkspaceId` first so it is non-empty.
   - Source column has a manual override (`.proportion(0.4)`, flag `true`).
   - Move the source window into the target.
   - Expect the target to have two columns; expect the **newly created**
     column (the one containing the moved window, found via
     `engine.column(of: movedWindow)`) to have `width == .proportion(0.4)` and
     `hasManualSingleWindowWidthOverride == true`. The pre-existing target
     column is untouched.
   - Locks in: preserve-on-move applies even when the target is occupied.

4. **`moveWindowToWorkspaceResolvesProportionalWidthAgainstTargetMonitor`**
   - Build the minimal layout context used elsewhere in this test file
     (`workingFrame` of a known width, e.g. `CGRect(x: 0, y: 0, width: 2000,
     height: 1000)`, `gaps: 8`). Source column has
     `width = .proportion(0.5)`, `hasManualSingleWindowWidthOverride = true`.
   - Move the window to an empty target workspace.
   - Call `targetColumn.resolveAndCacheWidth(workingAreaWidth: 2000, gaps: 8)`
     on the target column.
   - Expect `targetColumn.cachedWidth` to be ~`1000 - 2*8` (≈ 984), i.e.
     ~50% of the 2000px working width — not ~2000 (which would be `.fill`).
   - Optionally assert via the private `resolvedSingleWindowWidth` contract
     indirectly: because `hasManualSingleWindowWidthOverride == true`, the
     lone-window `.fill` policy is bypassed and `cachedWidth` is used.
   - Locks in: the copied proportional width re-resolves against the target
     working frame, giving OmniWM #295's "50% relative to current screen".

5. **Existing regression test stays green.**
   `moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn`
   (line `3828`) continues to assert `targetColumn.width == .proportion(0.7)`
   and `presetWidthIdx == nil`. With the fix, its source column has no manual
   override, so `applySourceColumnWidthOrReset` takes the
   `initializeNewColumnWidth` branch and the assertions still hold. No edit
   required.

6. **Whole-column move regression (existing, unchanged).**
   `moveLastColumnToWorkspaceLeavesSourceWorkspaceEmpty` (line `3857`) and the
   column-move coverage at line `3871` continue to lock in that whole-column
   moves preserve the column object and its width. No edit required; rerun to
   confirm.

## Validation

```bash
swift build

# Targeted: both branches of the fix
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspaceUsesExplicitDefaultWidthForTargetColumn
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspacePreservesManualSourceColumnWidthIntoEmptyTarget
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspacePreservesManualWidthIntoClaimedEmptyColumn
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspacePreservesManualWidthIntoNonEmptyTarget
swift test --filter NiriLayoutEngineTests/moveWindowToWorkspaceResolvesProportionalWidthAgainstTargetMonitor

# Whole-engine Niri suite (catches accidental regressions in column/sizing paths)
swift test --filter NiriLayoutEngineTests

# Other call sites of moveWindowToWorkspace that must stay green
swift test --filter OverviewProjectionTests
swift test --filter RefreshRoutingTests/moveWindowToWorkspaceOnMonitorUsesImmediateRelayoutOnly
```

Manual validation on a two-monitor host (default lone-window `.fill` policy):

1. On monitor A, resize a managed window to ~50% of A's working width.
2. Move that window to a workspace whose home monitor is B (e.g. via the
   `moveWindowToWorkspaceOnMonitor` hotkey/IPC path).
3. Confirm the moved window renders at ~50% of monitor B's working width —
   not 100%.
4. Move it back to A; confirm the ~50% width is retained.
5. Repeat with a non-empty target workspace on B and confirm the moved window
   still gets its own ~50%-wide column next to the existing column(s).
6. Resize a second window on A *without* manual override (i.e. leave it at the
   workspace default) and move it to B; confirm it still adopts B's workspace
   default width (fallback branch unchanged).

Changeset (patch): "Preserve manually-resized Niri column width when moving a
single window to another workspace (OmniWM #295)."

## Risks and mitigations

- **Preset-width idx drift across workspaces.** `copyColumnWidthState` copies
  `presetWidthIdx` verbatim. Presets are engine-global, so the idx remains
  valid on the target workspace. If a future change makes presets per-workspace,
  re-validate this copy.
- **`.fixed` widths on a smaller target monitor.** A fixed-pixel source width
  is copied as-is and may overflow the target working area, but this is
  consistent with `moveColumnToWorkspace` and with the user's explicit resize.
  Horizontal scroll already handles overflow; no new mitigation needed here.
- **Stale `loneWindowLayoutWidthOverride` after move.** Mitigated:
  `copyColumnWidthState` clears it, and the post-append loop at lines `51-55`
  clears it for non-manual columns. The next target-monitor layout pass
  re-caches it correctly.
- **Existing test encodes the old behavior.** Mitigated: with the "preserve
  only on manual override" decision, the existing regression test's source
  has no manual override and continues to assert the target default. The test
  is intentionally kept to lock in the fallback branch.
- **`copyColumnWidthState` visibility change.** The helper stays `private` to
  `+ColumnOps.swift`; only the new internal wrapper
  `applySourceColumnWidthOrReset` becomes cross-file visible. Minimal surface
  increase, no public API change.
- **Source column captured before detach.** Confirmed safe: `sourceColumn`
  (line `29`) is a strong reference to the `NiriContainer`, and detaching a
  child window does not mutate the container's own width fields.

## Follow-ups (out of scope)

- Per-app initial column width (OmniWM #283, see
  `discovery/20260617-omniwm-283-per-app-initial-column-width.md`) is a
  separate feature and would interact with this fix only at column *creation*
  on admission, not at workspace move.
- Allowing Niri columns wider than 100% of the working area (OmniWM #326, see
  `discovery/20260617-omniwm-326-niri-column-over-100-percent-width.md`) is
  independent; this fix copies whatever `ProportionalSize` the source column
  already has, so a future >100% capability composes naturally.
- A future "preserve on default-width move too" behavior change (if user
  feedback wants it) would only require dropping the `hasManualSingleWindowWidthOverride`
  guard in `applySourceColumnWidthOrReset`. Deliberately deferred here.
- Cross-monitor fixed-pixel width scaling (e.g. convert `.fixed(800px)` between
  DPIs) is not addressed; out of scope for #295, which is explicitly about
  proportional widths.
