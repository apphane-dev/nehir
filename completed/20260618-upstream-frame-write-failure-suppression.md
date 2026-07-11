# Upstream port P4 — Suppress app-originated frame-change relayout after a recent AX write failure — Discovery

Source: closed Hiro PR BarutSRB/OmniWM#403 concept (not a merged upstream commit); the nehir-native recommendation is documented in [`20260616-omniwm-403-frame-write-race-min-size-suppression.md`](20260616-omniwm-403-frame-write-race-min-size-suppression.md) (now in `completed/`).
This doc is the **patch-cluster discovery** for that one-branch fix; the linked sibling is the full root-cause trace.

Scope: confirm the suppression gap exists in nehir, confirm the bounded-clearing safety property the fix relies on, and scope the patch.

---

## TL;DR

- **Applies: nehir's `AXManager.shouldSuppressFrameChangeRelayout` checks only `pendingFrameWrites` and `lastAppliedFrames`, not `recentFrameWriteFailures`.** On a failed/min-size write, the pending map is cleared and `lastAppliedFrames` is never set, so the app's snap-back `kAXFrameChangedNotification` is not suppressed and kicks off a relayout that re-writes the identical too-small target — a self-sustaining loop.
- **Verdict:** 🔴 Open / Applies. One-branch fix; safe in nehir specifically because every legitimate enqueue clears the failure flag (`AXManager.swift:602`), bounding the suppression window to "after a failed write, before the next legitimate write."
- **This is the trigger-side fix, not the root cause.** The loop fundamentally exists because nehir computes a sub-minimum target (the M1 / BarutSRB/OmniWM#384 layout side). P4 suppresses the thrash now; M1's constraint feedback stops computing the bad target. Land **P4 first**, then M1 characterization.

## Provenance: is this nehir's code?

Yes. The suppression decision, the per-window frame-write state maps, and the result-handling path all exist and match the sibling discovery's description.

## The code in question

### The suppression function (the gap)

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:165
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil {
        return true
    }
    guard let observedFrame,
          let lastAppliedFrame = lastAppliedFrames[windowId]
    else {
        return false                       // ← failed-write path lands here: no pending, no lastApplied
    }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

### The failure path sets no lastApplied

On a failed write (`handleFrameApplyResults`, `AXManager.swift:804`):

- `:810` clears `pendingFrameWrites[resolvedWindowId]` before the success/failure split.
- `:839` records `recentFrameWriteFailures[resolvedWindowId] = failureReason`.
- The failure branch **never** assigns `lastAppliedFrames[id]` (only the success branch at `:823` does).

So a post-failure snap-back notification hits the `guard` fallthrough and returns `false` (unsuppressed) ⇒ relayout ⇒ re-enqueue the same failing target.

### The bounded-clearing safety property (why the fix is safe)

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:601-602  (enqueue path)
pendingFrameWrites[windowId] = frame
recentFrameWriteFailures.removeValue(forKey: windowId)   // ← cleared on EVERY enqueue
```

Every legitimate relayout (focus change, workspace switch, window add) enqueues a fresh frame, which clears the failure flag. So adding a suppression branch keyed on `recentFrameWriteFailures` can only suppress between a failed write and the next legitimate write — exactly the window in which the app's snap-back is spurious.

Full audit of `recentFrameWriteFailures` mutation sites confirms no other clear leaves the branch stranded: `:273` (full teardown), `:323-324` (rekey, preserves), `:348` (`confirmFrameWrite` — explicit success, correct), `:381` (window removal), `:710` (`suppressFrameWrites` teardown), `:824` (success branch). The suppression window is strictly bounded.

### The single caller

`AXEventHandler.shouldSuppressFrameChangedRelayout` (`Sources/Nehir/Core/Controller/AXEventHandler.swift:826`), called from the frame-change handler at `:805`. Verified: only one runtime caller.

## Why it applies

The loop, traced in nehir:

1. **Write fails** for a min-size app — write a too-small frame; app clamps back; readback observes the clamped (larger) frame ≠ target ⇒ `.verificationMismatch`. `pending` cleared (`:810`), failure recorded (`:839`), `lastApplied` **not** set.
2. **Bounded retry fires once** — `retryBudgetByWindowId` seeded to `1` on enqueue (`:623`); re-enqueues the same target (`:859`), fails identically, exhausts the budget.
3. **The app's snap-back is unsuppressed** — `kAXFrameChangedNotification` → `shouldSuppressFrameChangeRelayout` returns `false` (the gap).
4. **Unsuppressed relayout re-enqueues the identical target** — back to step 1. The app's own snap-back is the self-sustaining trigger.

P4 removes the trigger at step 3.

## Recommendation

**One branch, concept-ported (not a diff port — there is no merged upstream diff):**

```swift
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil { return true }
    if recentFrameWriteFailures[windowId] != nil { return true }   // ← the fix
    guard let observedFrame,
          let lastAppliedFrame = lastAppliedFrames[windowId]
    else { return false }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

## Suggested tests

Add to `Tests/NehirTests/AXManagerTests.swift` (`@Suite(.serialized)`, `@testable import Nehir`). Mirror the existing `terminalObserverFiresOnceAfterRetriesExhaustOnFailure` harness (drives a `.verificationMismatch` via `frameApplyOverrideForTests`).

1. `shouldSuppressFrameChangeRelayoutAfterRecentFrameWriteFailure` — drive a `.verificationMismatch` to terminal; assert preconditions (`recentFrameWriteFailure(for:) == .verificationMismatch`, `lastAppliedFrame(for:) == nil`, `pendingFrameWrite(for:) == nil`); then assert suppression returns `true` for both an unrelated observed frame and `nil`. (Fails pre-fix; passes after.)
2. `frameChangeRelayoutSuppressionEndsAfterEnqueueClearsFailure` — reach the same post-failure state; swap in a success override; enqueue a fresh target; assert the failure flag cleared and suppression now returns `false` for an unrelated frame. (Proves the bounded-clearing property.)

The end-to-end loop-bound test (synthesize the full `AXEventHandler → LayoutRefreshController` snap-back loop via `frameApplyAsyncOverrideForTests` and assert bounded enqueue count) is optional and more involved; defer.

## Suggested validation

```bash
swift build
swift test --filter AXManagerTests
swift test --filter AXEventHandlerTests                 # the single caller
swift test --filter LayoutRefreshControllerTests        # also exercise .verificationMismatch paths
swift test --filter RefreshRoutingTests
```

## Risks

- **Band-aid, not root cause.** Pair with M1/BarutSRB/OmniWM#384 (respect min-size in column-width math) so the bad target is never computed. Non-blocking.
- **A real user resize during the failure window is also suppressed** until the next legitimate enqueue. Intended trade-off: it is better to not fight the app during the failed-write window than to re-write the identical failing target. The next enqueue re-enables normal behavior.
- Unconditional suppression (any frame-change notification while the flag is present) vs. narrowing to "observedFrame near the failed target." Recommend unconditional — simplest correct shape given the bounded window; no safety gain from narrowing.

## Relationship to other clusters

- **M1 (refused-frame feedback):** nehir already implements the structural constraint-feedback loop; P4 is its missing trigger-side companion. Sequence **P4 → M1 characterization**.
- **BarutSRB/OmniWM#384 (respect window min-size in column-width math):** the true root cause. Tracked separately; not a patch.
