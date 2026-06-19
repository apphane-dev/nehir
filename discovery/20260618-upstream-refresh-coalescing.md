# Upstream port P2 — Coalesce same-kind refreshes without cancelling — Discovery

Source upstream commit: [`631caa9`](https://github.com/BarutSRB/OmniWM/commit/631caa9) — "Coalesce same-kind refreshes without cancelling" (0.4.9.7 line, behind the release-note "back-to-back relayouts coalesce instead of cancelling each other").
Filed against: `BarutSRB/OmniWM` (upstream of nehir — see `NOTICE.md`).
Scope: determine whether the same-kind cancel behavior applies to nehir, and scope the port.

---

## TL;DR

- **Applies: nehir cancels the active refresh task when an incoming refresh is the same kind as the active one** (`(.immediateRelayout, .immediateRelayout)` and `(.relayout, .relayout)`).
- **Why it's bad:** under a burst of same-kind requests, the in-flight task is cancelled on every arrival and restarted from the merged pending. If arrivals outpace completion, the active task never completes — starvation / self-inflicted churn.
- **Verdict:** 🔴 Open / Applies. Small, surgical switch-case edit; escalation cancellation is preserved. The test work is non-trivial because "did not cancel" is not observable from execution count alone under the existing debug-hook harness.

## Provenance: is this nehir's code?

Yes. `LayoutRefreshController.handleRefresh(_:whileActive:)` is the refresh-scheduling decision point and is structured identically to upstream's pre-fix description.

## The code in question

The same-kind cancellation lives in the `handleRefresh` switch, `Sources/Nehir/Core/Controller/LayoutRefreshController.swift`:

```swift
// :1636-1638  — immediateRelayout same-kind cancels
case (.immediateRelayout, .immediateRelayout):
    mergePendingRefresh(refresh)
    layoutState.activeRefreshTask?.cancel()

// :1646-1651  — relayout same-kind is bundled with escalation cases and cancels
case (.relayout, .fullRescan),
     (.relayout, .immediateRelayout),
     (.relayout, .relayout),
     (.relayout, .windowRemoval):
    mergePendingRefresh(refresh)
    layoutState.activeRefreshTask?.cancel()
```

The corresponding post-fix shape (from upstream) is:

```swift
case (.immediateRelayout, .immediateRelayout):
    mergePendingRefresh(refresh)
    // (no cancel)
...
case (.relayout, .relayout):
    mergePendingRefresh(refresh)
    // (no cancel)
case (.relayout, .fullRescan),
     (.relayout, .immediateRelayout),
     (.relayout, .windowRemoval):
    mergePendingRefresh(refresh)
    layoutState.activeRefreshTask?.cancel()
```

Escalation cancellations (e.g. `.visibilityRefresh` active + anything; `.relayout` active + `.fullRescan`/`.immediateRelayout`/`.windowRemoval`) are untouched.

## Why it applies

`mergePendingRefresh` collapses concurrent same-kind arrivals into a single pending refresh. Cancelling the active task on each arrival discards the in-flight work and re-enters from the merge; under a burst this can cycle without progress. Removing the cancel lets the active run to completion and the coalesced pending run once afterward. This is a **progress guarantee**, not a smaller execution count — a burst may now produce one extra catch-up pass (active + one coalesced), which is acceptable because relayouts are idempotent.

## Recommendation

**Direct port of the two switch edits** described above. Preserve all escalation/visibility cancels.

### What NOT to change

- `mergePendingRefresh(_:)` (`:1664`) — same-kind still merges into `pendingRefresh`.
- `startNextRefreshIfNeeded()` (`~:1806`) / `finishRefresh(_:didComplete:)` (`~:1858`) — the coalesced pending starts via the existing path after the active completes naturally.
- `.visibilityRefresh` and escalation cancels are unrelated — leave them.

### Test design note (important)

`executeRelayout(...)` short-circuits when the `onRelayout` debug hook returns `true`, so execution-count alone cannot distinguish "cancelled" from "ran to hook then ran pending." The zero-instrumentation observable is `Task.isCancelled` sampled **inside** the gated hook after `gate.wait()` (the existing `AsyncGate.wait()` in `RefreshRoutingTests.swift:277` uses a non-throwing `withCheckedContinuation` and is not cancellation-aware, so it stays parked until `gate.open()`; on resume `Task.isCancelled` reflects whether `activeRefreshTask?.cancel()` fired during the park). Fallback if flaky: add one `RefreshDebugCounters.activeRefreshCancellations` counter incremented at each cancel site.

## Suggested tests

Add to `Tests/NehirTests/RefreshRoutingTests.swift`, alongside `relayoutQueuedBehindActiveImmediateRelayoutStillExecutes` (`:4061`) and `canceledImmediateRelayoutPreservesPostLayoutActionsWhenUpgradedToFullRescan` (`:4290`):

1. `immediateRelayoutCoalescesWithActiveImmediateRelayoutWithoutCancelling` — gate the first `.immediateRelayout`, send a second, assert `activeWasCancelled == false` and the merged pending ran (two route entries).
2. `relayoutCoalescesWithActiveRelayoutWithoutCancelling` — same shape with two `.relayout`-route reasons (e.g. `.gapsChanged`, scheduling `.plain`, to avoid the relayout debounce sleep racing the gate).
3. `activeRelayoutIsStillCancelledByIncomingFullRescan` — negative test proving escalation still cancels (lock in `.relayout` active + `.fullRescan`).

## Suggested validation

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

## Risks

- **Extra layout pass under burst.** Same-kind bursts now run the active to completion plus one catch-up. Relayouts are idempotent (same target frames), so visible flicker should be minimal; if observed, a follow-up could drop no-op same-kind pending (out of scope for this patch).
- **Switch exhaustiveness** — Swift will compile-check after the split; ensure all `(activeKind, incomingKind)` pairs stay covered exactly once (the diff keeps all 25 combinations covered).
- **`.relayout` debounce sleep** in `execute` (`~:833-836`) runs before the hook; prefer `.plain`-scheduling reasons for the active side in test #2.

## Open questions

- Should the coalesced pending be dropped when it is a pure no-op (same kind, same affected workspaces, no new postLayout actions)? Upstream `631caa9` does not. Recommend keeping the patch minimal (merge-only) and revisiting only if burst flicker is observed.
