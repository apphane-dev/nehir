# Workspace assignment: lone-window width split + verified inactive reveal

**Status:** planned
**Source discovery:** `discovery/20260619-workspace-assignment-lone-window-width-cache-leak.md`

All source file references were verified against the main Nehir source tree on
2026-06-19. Re-verify line numbers before editing; they drift.

## TL;DR

Fix the workspace-assignment repro as two related but distinct defects:

1. **Lone-window width split.** The default lone-window `.fill` / centered render
   width must be transient render/layout state. It must not write into the
   canonical column `cachedWidth` that multi-column layout uses.
2. **Verified inactive reveal.** A workspace-inactive tiled window must not have
   `hiddenState` cleared just because a reveal position plan was attempted. Clear
   hidden state only after the window is verified near the target onscreen frame,
   or after an existing/pending forced frame-write reveal verifies.

The width fix is the primary model change. Do **not** solve it by opportunistically
clearing `cachedWidth`; that was the failed shortcut captured in the discovery.

## Current code map

- `Sources/Nehir/Core/Layout/Niri/NiriNode.swift:381` — `NiriContainer.cachedWidth`
  is the only horizontal column width cache.
- `Sources/Nehir/Core/Layout/Niri/NiriNode.swift:389` —
  `hasManualSingleWindowWidthOverride` distinguishes user/manual lone-window
  sizing from the default lone-window policy.
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:178` — single-window workspaces
  leave normal multi-column layout early.
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:225` — normal horizontal layout
  uses `containers.map { $0.cachedWidth }` for spans.
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:700` —
  `resolvedSingleWindowWidth` currently computes the default fill/center width.
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift:824` and `:884` —
  `prepareSingleWindowViewport` / `layoutSingleWindowWorkspace` write the lone
  geometry width back into `cachedWidth`; this is the leak.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Sizing.swift:96` / `:106` —
  resize-start seeding can also write a single-window rect width into
  `cachedWidth`.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift:146` — add-window
  has a one-off second-window reset of non-manual column `cachedWidth`; replace
  this with the structural split rather than expanding the reset workaround.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+WorkspaceOps.swift:13` —
  `moveWindowToWorkspace` creates/appends a target column but does not sanitize
  lone-window render state when the target workspace becomes multi-column.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:2379` —
  `applyPositionPlans` attempts SkyLight + AX fallback but returns no status.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3017` —
  `executeHiddenReveal` clears hidden state immediately after a position plan.
- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3706` — layout-plan
  restore applies position plans, then clears hidden state for restore/show
  entries without using placement verification.

## Scope

### In scope

- Split canonical column width from transient lone-window render/layout width.
- Clear/ignore transient lone-window width whenever a workspace leaves the exact
  single normal tiled window state.
- Preserve manual single-window width behavior: manual width/full-width commands
  still commit canonical width and set `hasManualSingleWindowWidthOverride`.
- Add trace/debug output that separately reports canonical `cachedWidth` and the
  transient lone-window override.
- Make workspace-inactive tiled reveal state follow verified onscreen placement.

### Non-goals

- Do not rewrite the whole niri layout engine.
- Do not change the user-facing lone-window `.fill` / centered policy.
- Do not change floating/scratchpad reveal semantics except where code must share
  a verification helper.
- Do not add regression tests before the user confirms the runtime repro is fixed
  in the real environment; follow the repository debugging rule.

## Implementation plan — Part A: width model split

### A1. Add transient width state to `NiriContainer`

Add an optional transient field to `NiriContainer`, for example:

```swift
var loneWindowLayoutWidthOverride: CGFloat?
```

or `singleWindowLayoutWidthOverride`. This is **not** canonical width, should not
be persisted, and should not drive multi-column spans. Add a small helper if it
keeps call sites clear, e.g.:

```swift
func clearLoneWindowLayoutWidthOverride()
```

Expected invariant:

- `cachedWidth` = canonical column width from `width` / manual width / full-width
  state / constraints.
- `loneWindowLayoutWidthOverride` = render/layout width while the workspace has
  exactly one normal tiled window and the non-manual lone-window policy is active.

### A2. Keep canonical width resolved even in lone-window mode

When laying out a non-manual single-window workspace, ensure the column's
canonical `cachedWidth` is resolved from the column spec if it is missing, but do
not replace it with the fill/centered render width.

Concretely, change the current single-window writers:

- `prepareSingleWindowViewport` (`NiriLayout.swift:809`) should assign the computed
  geometry width to the transient override, not to `cachedWidth`.
- `layoutSingleWindowWorkspace` (`NiriLayout.swift:876`) should do the same.
- `resolvedSingleWindowWidth` (`NiriLayout.swift:700`) should only read/write
  `cachedWidth` for manual single-window overrides. For non-manual policy, it
  should compute the render width from policy + constraints while leaving
  canonical width intact.

Manual case: if `hasManualSingleWindowWidthOverride == true`, keep using the
canonical width cache as the render width. Manual commands are user intent, not a
transient policy overlay.

### A3. Normal multi-column layout ignores and clears the override

At the normal-layout path after the single-window early return is skipped
(`NiriLayout.swift:178`), clear the transient lone-window override for all
containers in the workspace before computing spans. Then continue using only
`cachedWidth` for `containerSpans` (`NiriLayout.swift:225`).

This should make the transition deterministic:

```text
# One default fill lone window on a 2040-ish working area:
cached≈1008 override≈2040 spec=prop:0.5000 manual=false

# Same workspace after a second column is added or moved in:
c0 cached≈1008 override=nil spec=prop:0.5000
c1 cached≈1008 override=nil spec=prop:0.5000
```

### A4. Fix resize-start seeding

Update `cachedWidthForResizeStart` (`NiriLayoutEngine+Sizing.swift:96`) so a
non-manual single-window workspace never seeds canonical `cachedWidth` from
`resolvedSingleWindowRect`. If `cachedWidth <= 0`, resolve from the column spec
with `resolveAndCacheWidth`.

Keep the existing `toggleColumnWidth` behavior that compares preset cycling
against the canonical tile width for non-manual lone windows. When a user invokes
a sizing command, `applyColumnWidth` should continue setting
`hasManualSingleWindowWidthOverride = true` and animating/committing the canonical
width.

### A5. Replace add/move reset workaround with override cleanup

- In `NiriLayoutEngine+Windows.swift:146`, stop clearing non-manual
  `cachedWidth` as the primary correctness mechanism. If a cleanup is still
  needed there, clear only the transient lone-window override.
- In `NiriLayoutEngine+WorkspaceOps.swift:13`, after moving a window into a target
  workspace that now has more than one normal tiled window, clear the transient
  override for the target root's existing and new columns. Do not clear canonical
  `cachedWidth`.
- Audit related column-transfer helpers in `NiriLayoutEngine+ColumnOps.swift` for
  copied/moved width state. A moved/copied column should carry canonical width
  and manual flags, but not a stale transient lone-window override.

### A6. Make diagnostics show the split

Update the niri debug dump in `Sources/Nehir/Core/Controller/WMController.swift`
near the existing `cached=... spec=... manual=...` output to include the new
transient width, for example `override=...` or `lone=...`.

This is part of the acceptance signal. The real repro should show canonical and
transient state separately.

## Implementation plan — Part B: verified workspace-inactive reveal

### B1. Return verification from position plans

Change `applyPositionPlans` (`LayoutRefreshController.swift:2379`) from fire-and-
forget to returning per-window placement status. A compact shape is enough:

```swift
struct WindowPositionApplyResult {
    let token: WindowToken
    let requestedFrame: CGRect
    let observedFrame: CGRect?
    let fallbackAttempted: Bool
    let fallbackResult: AXFrameWriteResult?
    let verified: Bool
}
```

`verified` should mean the final observed origin/frame is within the existing
position epsilon of the requested target and is plausibly onscreen for the target
monitor/display. Preserve the current SkyLight and AX fallback trace lines, and
add a final status trace so captures distinguish:

- position requested,
- SkyLight verified,
- AX fallback attempted,
- final placement verified/unverified,
- hidden state cleared or retained.

Callers that only hide windows can ignore the return value.

### B2. Gate `executeHiddenReveal` hidden-state clearing

In `executeHiddenReveal` (`LayoutRefreshController.swift:2998`), for
workspace-inactive tiled reveals:

1. Apply the position plan.
2. Clear `hiddenState` only if the returned result verifies the requested target.
3. If placement is unverified, keep the workspace-inactive hidden state and route
   the window through a forced frame-write / pending reveal retry using the known
   target frame when available.

The goal is that Nehir never reports `phase=tiled hidden=nil` for an assigned
window that is still parked at the offscreen edge.

### B3. Extend pending reveal verification to tiled workspace-inactive restores

The existing pending reveal transaction machinery is currently limited by
`shouldUsePendingRevealTransaction` to floating hidden-state restores. Add a
separate predicate or extend the logic so tiled workspace-inactive restores with a
known layout target frame can use the same success/failure finalization path.

Important finalization behavior:

- Success: `finalizePendingRevealTransactionSuccess` clears hidden state and
  confirms the frame.
- Failure/delay: hidden state remains workspace-inactive or a delayed verification
  is scheduled; do not silently clear state on a verification mismatch.

If the existing failure finalizer intentionally clears workspace-inactive state,
change that for the verified-reveal path so a terminal mismatch cannot advance
the model ahead of the window server.

### B4. Update layout-plan restore/show clearing

In `executeLayoutPlan`, the restore block around `restorePlans` currently calls
`applyPositionPlans(restorePlans)` and then clears hidden state for restore
entries. Change this to use the returned placement results:

- Clear immediately for entries that are not workspace-inactive tiled reveals and
  keep existing behavior where safe.
- For workspace-inactive tiled reveals, clear only when placement verified or a
  pending reveal transaction later verifies.
- Keep `blockedRevealTokens` / `pendingRevealTokens` semantics so a token does not
  get cleared by the later `shownEntries` loop in the same plan.

## Validation plan

### Before adding tests

The repository rule for runtime bugs applies: do not add or rewrite tests until
the real repro is confirmed fixed by the user.

Run only implementation sanity checks first:

```bash
swift build
```

Then validate in the original repro:

1. Assign one window into an inactive empty workspace and activate it.
   - Expected: if the model clears hidden state, the selected/focused token has an
     onscreen frame near the layout target (`x≈8` in the captured topology), not
     the parking edge (`x≈2055`).
   - If placement fails, expected: hidden state is retained or a pending verified
     retry is visible in traces; model state does not claim normal tiled visibility.
2. Assign/move one window into an empty workspace under `.fill`, then assign/move
   a second window into that workspace.
   - Expected lone state: `cached≈balanced/default`, transient override≈full
     working width.
   - Expected two-column state: both columns have balanced/default cached widths
     and transient override is nil.

### Post-confirmation regression tests

After the user confirms the real repro is fixed, add focused tests:

1. `NiriLayoutEngineTests` — default fill lone window then second **moved** window
   balances columns. This must cover `moveWindowToWorkspace`, not only
   `addWindow`.
2. Update/strengthen
   `addingSecondWindowReturnsToNormalColumnSizingAfterSingleWindowOverride` so it
   asserts canonical cached width and nil transient override in the two-column
   state.
3. Manual single-window override still persists: manual width/full-width in a
   lone workspace commits canonical width; adding/moving a second column does not
   discard the manual width.
4. `LayoutRefreshControllerTests` — with a fake frame writer / live-frame readback
   that reports a verification mismatch for a workspace-inactive tiled reveal,
   hidden state is not cleared until a verified forced/pending reveal succeeds.

Suggested commands after adding tests:

```bash
swift test --filter NiriLayoutEngineTests
swift test --filter LayoutRefreshControllerTests
swift build
```

## Acceptance criteria

- No default lone-window `.fill` / centered code path writes the policy render
  width into canonical `cachedWidth`.
- Multi-column layout uses canonical `cachedWidth` only and ignores transient
  lone-window override state.
- Workspace moves into a formerly lone target workspace produce balanced/default
  canonical widths for all non-manual columns.
- Manual single-window width behavior is preserved.
- Workspace-inactive tiled reveal clears hidden state only after verified onscreen
  placement or a verified pending reveal.
- Runtime traces/debug dumps make it obvious whether width is canonical vs
  transient and whether hidden-state clearing followed verified placement.

Changeset: `patch` — user-visible bug fix for workspace assignment visibility and
lone-window width leakage.

## Risks / open questions

- **In-memory polluted caches from a previous build.** The structural split fixes
  new computations. If an already-running session has a polluted non-manual
  `cachedWidth`, avoid broad reset logic unless the repro proves it matters after
  restart/update.
- **Manual override ambiguity.** Manual lone-window sizing should remain canonical.
  Be careful not to treat a user-set full-width column as a transient `.fill`
  overlay.
- **Pending reveal failure semantics.** Existing code clears workspace-inactive
  state in some failure paths. The fix must not preserve that behavior for tiled
  assignment reveals that failed verification.
- **Exact frame assertions are brittle.** Tests should prefer visibility/verified
  placement predicates and approximate widths over hard-coded offsets where
  possible.
