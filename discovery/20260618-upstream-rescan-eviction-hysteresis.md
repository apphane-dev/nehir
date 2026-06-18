# Upstream port P1 — Require two consecutive rescan misses before eviction — Discovery

Source upstream commit: [`ba9d1e2`](https://github.com/BarutSRB/OmniWM/commit/ba9d1e271799a6532bb4aed24bb0080c66629cde) — "Require two consecutive rescan misses before evicting windows" (0.4.9.7 line).
Filed against: `BarutSRB/OmniWM` (upstream of nehir — see `NOTICE.md`).
Scope: determine whether the single-miss eviction behavior applies to nehir, and scope the port.

All file/line references below were verified against worktree `worktree-calm-harbor-e6a1` on 2026-06-18. Re-verify before implementing; line numbers drift.

---

## TL;DR

- **Applies: nehir's full-rescan eviction path removes a known window after a single transient miss.** The single production callsite at `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1424` passes `requiredConsecutiveMisses: 1`.
- **Verdict:** 🔴 Open / Applies. Literal one-token port (same as upstream), but it breaks two controller-level tests that hard-code one-miss eviction and must be rewritten to two rescans.
- **The model/manager layer is already correct for `2`:** `WindowModel.confirmedMissingKeys` (`:737`) and `WorkspaceManager.removeMissing` (`:2844`) already accept and exercise `requiredConsecutiveMisses: 2` in existing tests. The only production callsite is pinned to `1`.

## Provenance: is this nehir's code?

Yes. The eviction mechanism is identical to upstream's description:

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1424` — the full-rescan `seenKeys` → `removeMissing` call.
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2844` — `removeMissing(keys:requiredConsecutiveMisses:)`, default `1`.
- `Sources/Nehir/Core/Workspace/WindowModel.swift:737` — `confirmedMissingKeys(keys:requiredConsecutiveMisses:)`, threshold `max(1, requiredConsecutiveMisses)`, per-token `missingDetectionCountByToken`.

This is the only production caller of `removeMissing(...)` (verified by repo-wide grep). The change is scoped to this single site.

## The code in question

### The production eviction call (full rescan)

```swift
// Sources/Nehir/Core/Controller/LayoutRefreshController.swift:1424
controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
```

`seenKeys` is built from on-screen/visible enumeration only (`AXManager.fullRescanEnumerationSnapshot` at `:441` → `SkyLight.shared.queryAllVisibleWindows()` + `CGWindowListCopyWindowInfo([.optionOnScreenOnly, ...])`). Any window omitted from that set for one rescan cycle — AX timing, an app briefly recreation, a momentary Space change, a flaky per-PID enumeration timeout (`failedPIDs`) — increments its miss counter and is evicted.

### The threshold logic (already handles 2 correctly)

```swift
// Sources/Nehir/Core/Workspace/WindowModel.swift:737
func confirmedMissingKeys(keys activeKeys: Set<WindowKey>, requiredConsecutiveMisses: Int = 1) -> [WindowKey] {
    let threshold = max(1, requiredConsecutiveMisses)
    ...
    let misses = (missingDetectionCountByToken[token] ?? 0) + 1
    if misses >= threshold { confirmedMissing.append(token) }
```

A window "seen" again resets its counter; the mechanism is already `2`-capable.

## Why it applies

Nehir's rescan enumerates **visible/on-screen** windows only. A single transient omission — common around AX timing jitter, app window recreation (Electron, TextEdit), per-PID enumeration timeouts, or macOS Space transitions — therefore deletes a still-valid window from the model. Upstream shipped this exact bump for the same reason ("a single transient rescan miss no longer drops a window"). Nehir has the same enumeration shape and the same single-miss callsite.

## Recommendation

**Direct one-token port.** Change `:1424`:

```diff
- controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 1)
+ controller.workspaceManager.removeMissing(keys: seenKeys, requiredConsecutiveMisses: 2)
```

Do **not** change the default parameter of `WorkspaceManager.removeMissing(...)` (other callers and `ReconcileStateTests.swift:202` rely on the default of `1`). Do **not** touch `confirmedMissingKeys`; its threshold logic already does the right thing.

### Test work (the real cost of this patch)

Two controller tests hard-code one-miss eviction and must be rewritten to two rescans + first-miss survival assertions:

- `Tests/NehirTests/RefreshRoutingTests.swift:3213` — `fullRescanRemovesMissingTrackedWindowOnFirstVerifiedMiss` → split into two phases: after first rescan the entry survives; after the second it is evicted.
- `Tests/NehirTests/RefreshRoutingTests.swift:3241` — `fullRescanClearsFocusedFloatingBorderWhenWindowMissing` → run the rescan twice; keep the final assertions, add a mid-point that the floating entry survived the first.

The model/manager layer (`OptimizationCompletionTests` ~`:98-130`, `WorkspaceManagerTests` `removeMissingClearsDeadFocusMemoryAndRecoverySelectsSurvivorAfterConsecutiveMisses` at `:1435`) already asserts the `2`-miss behavior and need no change.

Spot-check the `fullRescanPreserves...` family (`RefreshRoutingTests` ~`:3282`–`:3557`) — these assert *preservation* and should stay green (P1 makes them more correct).

## Suggested validation

```bash
swift build
swift test --filter OptimizationCompletionTests        # unchanged, should pass
swift test --filter WorkspaceManagerTests              # unchanged, should pass
swift test --filter RefreshRoutingTests                # the two rewritten tests + neighbors
swift test --filter AXEventHandlerTests                # catch any other single-miss-eviction assumption
```

## Risks

- A genuinely-destroyed window now lingers one extra rescan cycle before eviction. The destroy path routes via `.windowRemoval` (not `.fullRescan`), so the `windowDestroyed` path is unaffected; only rescan-discovery eviction is delayed by one cycle.
- ~40 tests call `requestFullRescan`; after the one-line change, sweep for any other test that adds a window, makes it invisible, runs one rescan, and asserts `entry(...) == nil`.

## Relationship to other clusters

- This is the direct complement of the Spaces-topology work (M4 Stage 2): M4 Stage 2 exempts windows hidden on inactive native Spaces from miss-eviction entirely; P1 is the general "don't be twitchy" hysteresis that helps regardless of Space mode. The two compose cleanly — `confirmedMissingKeys` would consult topology *and* use a threshold of 2.
