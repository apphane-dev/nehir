# P2 — Coalesce same-kind refreshes without cancelling

**Status:** completed — shipped on `main` in `0ac70a5d` ("Coalesce same-kind refreshes instead of cancelling the active one (P2)").
**Source discovery:** `completed/20260618-upstream-refresh-coalescing.md`
**Upstream commit:** `631caa9` — "Coalesce same-kind refreshes without cancelling"

## Completion evidence

`origin/main` contains `0ac70a5d` with the plan's intended source and test changes. Verified while updating this plan branch on 2026-06-19 via `git log origin/main` and `git show --stat 0ac70a5d`.


## Goal

Stop `LayoutRefreshController.handleRefresh` from cancelling the in-flight
refresh task when an incoming refresh is the **same kind** as the active one
(`(.immediateRelayout, .immediateRelayout)` and `(.relayout, .relayout)`).
Same-kind arrivals should merge into the pending refresh and let the active
task run to completion. This is a **progress guarantee**, not an execution-count
reduction: under a burst of same-kind requests the current code cancels the
active task on every arrival and re-enters from the merged pending, so if
arrivals outpace completion the active task never finishes (starvation /
self-inflicted churn).

## Scope

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` — the
  `handleRefresh(_:whileActive:)` switch (two edits, described below).
- `Tests/NehirTests/RefreshRoutingTests.swift` — ~3 new tests.

### Non-goals

- Do **not** drop a coalesced same-kind pending even when it is a pure no-op
  (same kind, same affected workspaces, no new postLayout actions). Upstream
  `631caa9` does not; keep this patch minimal. Revisit only if burst flicker is
  observed.
- Do **not** change any execution-count / debounce behavior beyond removing the
  two cancels.

## Exact edits

File: `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`

### Edit 1 — `(.immediateRelayout, .immediateRelayout)` at line 1636 (cancel at 1638)

Current (lines 1636–1638):
```swift
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
```

Post-fix:
```swift
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
```

### Edit 2 — split `(.relayout, .relayout)` out of the escalation group (group at 1646, cancel at 1651)

Current (lines 1646–1651):
```swift
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .relayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
```

Post-fix — `.relayout, .relayout` becomes its own merge-only case; the
escalation trio keeps cancelling:
```swift
        case (.relayout, .relayout):
            mergePendingRefresh(refresh)
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
```

## What NOT to change

- `mergePendingRefresh(_:)` (line **1664**) — same-kind still merges into
  `layoutState.pendingRefresh`. Behaviour of the merge is unchanged.
- `startNextRefreshIfNeeded()` and `finishRefresh(_:didComplete:)` — the
  coalesced pending starts via the existing path after the active completes
  naturally.
- **Escalation / visibility cancels are untouched.** All of these still cancel:
  - `.visibilityRefresh` active + anything that cancels today
    (fullRescan / windowRemoval / immediateRelayout / relayout groups at
    ~1628–1635).
  - `.relayout` active + `.fullRescan` / `.immediateRelayout` / `.windowRemoval`
    (the trio kept in Edit 2).
  - `.immediateRelayout` active + `.fullRescan` (~1628) and
    + `.windowRemoval` (~1645).
- **Switch exhaustiveness.** There are 5 refresh kinds (fullRescan,
  visibilityRefresh, windowRemoval, immediateRelayout, relayout) = 25
  `(activeKind, incomingKind)` pairs. The split moves `.relayout, .relayout`
  into its own case but keeps every combination covered exactly once; Swift
  will compile-check this. Confirm all 25 stay covered.

## Tests

File: `Tests/NehirTests/RefreshRoutingTests.swift`. Add alongside
`relayoutQueuedBehindActiveImmediateRelayoutStillExecutes` (line **4061`) and
`canceledImmediateRelayoutPreservesPostLayoutActionsWhenUpgradedToFullRescan`
(line **4290**).

1. **`immediateRelayoutCoalescesWithActiveImmediateRelayoutWithoutCancelling`**
   — gate the first `.immediateRelayout`, send a second, assert
   `activeWasCancelled == false` and the merged pending ran (two route entries).
2. **`relayoutCoalescesWithActiveRelayoutWithoutCancelling`** — same shape with
   two `.relayout`-route reasons. Use a `.plain`-scheduling reason for the
   active side (e.g. `.gapsChanged`) to avoid the `.relayout` debounce sleep in
   `execute` (~833–836) racing the gate.
3. **`activeRelayoutIsStillCancelledByIncomingFullRescan`** — negative /
   regression test proving escalation still cancels (lock in `.relayout` active
   + `.fullRescan` incoming).

### ⚠️ Test observability caveat (critical)

"Did not cancel" is **not** observable from execution count alone under the
existing debug-hook harness: `executeRelayout(...)` short-circuits when the
`onRelayout` debug hook returns `true`, so the count cannot distinguish
"cancelled" from "ran to hook, then ran pending."

Two options, prefer the first:

- **Zero-instrumentation observable:** sample `Task.isCancelled` **inside** the
  gated hook after `gate.wait()`. The existing `AsyncGate` is at
  `RefreshRoutingTests.swift:273` and its `wait()` (line **277**) uses a
  non-throwing `withCheckedContinuation` that is not cancellation-aware, so it
  stays parked until `gate.open()`; on resume `Task.isCancelled` reflects
  whether `activeRefreshTask?.cancel()` fired during the park. Assert
  `Task.isCancelled == false` after the second refresh is routed in.
- **Fallback if flaky:** add a `RefreshDebugCounters.activeRefreshCancellations`
  counter incremented at each cancel site in `handleRefresh`, and assert it
  does not increment for the coalesce cases but does for the escalation
  negative test. This is a slightly larger diff; only use it if the
  `Task.isCancelled` approach proves flaky.

## Validation

```bash
swift build
swift test --filter RefreshRoutingTests
# specifically:
swift test --filter RefreshRoutingTests/immediateRelayoutCoalescesWithActiveImmediateRelayoutWithoutCancelling
swift test --filter RefreshRoutingTests/relayoutCoalescesWithActiveRelayoutWithoutCancelling
swift test --filter RefreshRoutingTests/activeRelayoutIsStillCancelledByIncomingFullRescan
swift test --filter RefreshRoutingTests/relayoutQueuedBehindActiveImmediateRelayoutStillExecutes
swift test --filter RefreshRoutingTests/pendingVisibilityRefreshUpgradesToFullRescan
```

The last two are existing tests that must stay green (they pin the unchanged
escalation/coalesce behaviour).

## Risks

- **Extra layout pass under burst.** Same-kind bursts now run the active to
  completion plus one catch-up. Relayouts are idempotent (same target frames),
  so visible flicker should be minimal; revisit only if observed (out of scope
  here).
- **Switch exhaustiveness** — the Swift compiler enforces this after the split;
  the diff keeps all 25 combinations covered exactly once. Verify the build is
  clean.
- **`.relayout` debounce sleep** in `execute` (~833–836) runs before the hook;
  prefer `.plain`-scheduling reasons for the active side in test #2 to avoid
  racing the gate.
- **Behavioural subtlety to sanity-check at review:** after removing the cancel,
  a burst may now produce one extra catch-up pass (active + one coalesced). This
  is intended and acceptable because relayouts are idempotent.

## Open question (defer)

Should the coalesced pending be dropped when it is a pure no-op (same kind,
same affected workspaces, no new postLayout actions)? Upstream `631caa9` does
not. Recommend keeping the patch minimal (merge-only) and revisiting only if
burst flicker is observed.
