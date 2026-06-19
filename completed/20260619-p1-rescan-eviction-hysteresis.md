# P1 — Require two consecutive rescan misses before evicting windows

Status: **completed** — shipped on `main` in `294b253a` ("Require two rescan misses before evicting a window (P1)").
Patch family: upstream port (`P1`), `20260618-upstream-port-patch-fixes.md` track.
Source upstream commit: `ba9d1e2` — "Require two consecutive rescan misses before evicting windows".

## Completion evidence

`origin/main` contains `294b253a` with the plan's intended source and test changes. Verified while updating this plan branch on 2026-06-19 via `git log origin/main` and `git show --stat 294b253a`.


## Goal

Stop a single transient rescan miss (AX timing jitter, app window recreation, per-PID enumeration timeout, macOS Space transition) from immediately deleting a still-valid window from Nehir's model. Bump the single production full-rescan eviction call from one-miss to two-miss hysteresis.

## Scope

One token in the full-rescan eviction path. The model/manager threshold layer already handles `2` correctly; only the production callsite is pinned to `1`. Two controller-level tests that hard-code one-miss eviction must be rewritten to two-phase (survives first rescan, evicted on second).

## Non-goals

- Do **not** change the default parameter of `WorkspaceManager.removeMissing(keys:requiredConsecutiveMisses:)` (`:2846`, default `1`). Other callers and `ReconcileStateTests` rely on the default.
- Do **not** touch `WindowModel.confirmedMissingKeys` (`:737`). Its threshold logic (`max(1, requiredConsecutiveMisses)` + per-token `missingDetectionCountByToken`, reset-on-seen) already does the right thing for `2`.
- Do **not** change the `.windowRemoval` / `windowDestroyed` path — genuine window destruction still evicts immediately; only rescan-discovery eviction is hysteresis-delayed.
- No Spaces-topology eviction exemption (that is M4 Stage 2, composes cleanly later).

## Exact edits

**File:** `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`
**Current (verified 2026-06-19, line 1424):**

```swift
controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
```

**After:**

```swift
controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 2)
```

This is the only production caller of `removeMissing(...)` (verified by repo-wide grep). `seenKeys` is built from on-screen/visible enumeration only.

## Tests

`Tests/NehirTests/RefreshRoutingTests.swift`. Both existing tests set `currentWindowsAsyncOverride = { [] }` (makes the window invisible) and run `requestFullRescan(reason: .startup)` + `await waitForRefreshWork(on: controller)` exactly once, then assert eviction. Rewrite each to run the rescan **twice** and insert a mid-point survival assertion.

### 1. `fullRescanRemovesMissingTrackedWindowOnFirstVerifiedMiss` (line 3213)

Rename intent → two-miss. After the existing single rescan block, before the `== nil` assertion:

- Assert the entry **still exists** after the first rescan: `#expect(controller.workspaceManager.entry(forPid: pid, windowId: windowId) != nil)`.
- Run a second rescan:
  ```swift
  controller.layoutRefreshController.requestFullRescan(reason: .startup)
  await waitForRefreshWork(on: controller)
  ```
- Keep the existing final assertions: `entry(...) == nil`, `pendingFrameWriteCount == 0`, `retryBudgetCount == 0`, `forceApplyWindowIdCount == 0`, `inactiveWorkspaceWindowIdCount == 0`.

Consider renaming the function to `fullRescanRemovesMissingTrackedWindowOnSecondVerifiedMiss` (optional; if renamed, leave the `.startup` reason and all setup unchanged).

### 2. `fullRescanClearsFocusedFloatingBorderWhenWindowMissing` (line 3241)

Same two-phase shape. After the single rescan block, before the `== nil` assertions:

- Assert the floating entry **survives** the first rescan: `#expect(controller.workspaceManager.entry(for: token) != nil)` (the floating geometry, managed focus, and border were already primed — no need to re-prime between rescans).
- Run a second rescan:
  ```swift
  controller.layoutRefreshController.requestFullRescan(reason: .startup)
  await waitForRefreshWork(on: controller)
  ```
- Keep the existing final assertions: `entry(for: token) == nil`, `currentBorderTarget() == nil`, `lastAppliedBorderWindowId(on: controller) == nil`.

### Unchanged tests (must stay green)

- `OptimizationCompletionTests` (~`:98-130`) — already asserts 2-miss behavior at the model layer.
- `WorkspaceManagerTests.removeMissingClearsDeadFocusMemoryAndRecoverySelectsSurvivorAfterConsecutiveMisses` (~`:1435`) — already asserts 2-miss at manager layer.
- The `fullRescanPreserves...` family (`RefreshRoutingTests` ~`:3282`–`:3557`) — assert preservation; P1 makes them more correct.

### Sweep check before finishing

~40 tests call `requestFullRescan`. After the edit, grep for any other test that adds a window, makes it invisible, runs one rescan, and asserts `entry(...) == nil`, and fix it to the two-phase shape. Expected to find only the two above.

## Validation

```bash
swift build
swift test --filter OptimizationCompletionTests     # unchanged, must pass
swift test --filter WorkspaceManagerTests           # unchanged, must pass
swift test --filter RefreshRoutingTests             # two rewritten + neighbors
swift test --filter AXEventHandlerTests             # catch other single-miss assumptions
```

## Risks

- **Delayed eviction of genuinely-destroyed windows by one rescan cycle.** Mitigated: the destroy path routes via `.windowRemoval`, not `.fullRescan`, so `windowDestroyed` is unaffected. Only rescan-discovery eviction is delayed one cycle.
- **Latent single-miss test assumptions elsewhere.** Mitigated by the sweep check above; `AXEventHandlerTests` run covers adjacent code.
- No user-visible behavior regression for legitimate windows — they are seen again on the next rescan and the miss counter resets.

## Evidence (self-contained)

The eviction mechanism, verified against main at the lines above:

- Production callsite passes `requiredConsecutiveMisses: 1`.
- `confirmedMissingKeys` threshold: `let threshold = max(1, requiredConsecutiveMisses)`; `let misses = (missingDetectionCountByToken[token] ?? 0) + 1; if misses >= threshold { confirmedMissing.append(token) }`. A window seen again resets its counter — already 2-capable.

## Pointer

Discovery doc: [`discovery/20260618-upstream-rescan-eviction-hysteresis.md`](../discovery/20260618-upstream-rescan-eviction-hysteresis.md). Track summary: [`discovery/20260618-upstream-port-patch-fixes.md`](../discovery/20260618-upstream-port-patch-fixes.md).
