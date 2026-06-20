# OmniWM PR #403 — "Break AX frame-write race loop for min-size apps" — Discovery

**Status:** completed — the recommended one-clause suppression fix shipped on `main` as part of P4 in commit `0162aab4` ("Suppress frame-change relayout after a recent frame-write failure (P4)"). The `recentFrameWriteFailures[windowId] != nil` branch this doc recommended is present at `Sources/Nehir/Core/Ax/AXManager.swift` in `shouldSuppressFrameChangeRelayout`. Implementation record: [`20260619-p4-frame-write-suppression.md`](20260619-p4-frame-write-suppression.md); background concept: [`20260618-upstream-frame-write-failure-suppression.md`](20260618-upstream-frame-write-failure-suppression.md). Moved from `discovery/` on 2026-06-20.

Source PR: https://github.com/BarutSRB/OmniWM/pull/403
Merge state: **closed without merge** (head branch `dev/combined-fixes`, a 19-commit
bundle of unrelated fixes; only the final commit is relevant here). Port the concept,
never the diff.
Scope of this doc: determine whether nehir has the AX frame-write retry/race loop for
min-size-constrained apps, and whether the proposed one-clause suppression fix adapts.

All file/line references were verified against nehir worktree `worktree-calm-meadow-6229`
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro trace"). Line
numbers drift — re-verify before implementing.

---

## TL;DR

- **nehir reproduces the exact loop: on a failed frame write, `pendingFrameWrites` is cleared and `lastAppliedFrames` is never set, so the min-size app's snap-back notification sails past `shouldSuppressFrameChangeRelayout` unsuppressed and kicks off a relayout that re-writes the identical too-small target. The fix — check `recentFrameWriteFailures` in the suppression function — is absent in nehir.**
- **Verdict:** 🔴 **Open / Applies.** Root cause identical to upstream; the one-clause fix ports cleanly and safely (nehir already clears the failure flag on enqueue, which is the key safety property the fix relies on).

## What the PR changes (concept, not diff)

The relevant commit (the last of the branch) adds one clause to the function that
decides whether an app-originated `kAXFrameChangedNotification` should trigger a
relayout:

> Root cause: `shouldSuppressFrameChangeRelayout` only checked `pendingFrameWrites`
> and `lastAppliedFrames`. On write failure, `pendingFrameWrites` is cleared and
> `lastAppliedFrames` is never set, so the app's self-resize triggers an unsuppressed
> relayout that writes the same failing frame again. Fix: also check
> `recentFrameWriteFailures` in the suppression function. The failure state is cleared
> when a new frame write is enqueued, so legitimate relayouts from workspace switches,
> focus changes, or window additions still work.

The diff is a single boolean branch; nothing structural. We evaluate whether nehir's
equivalent function has the same gap and the same safety precondition.

## Provenance: is this nehir's code?

Yes. The suppression decision, the per-window frame-write state maps, and the
result-handling path all exist in nehir and are structured identically to the
upstream description:

- `AXManager.shouldSuppressFrameChangeRelayout(for:observedFrame:)` — `Sources/Nehir/Core/Ax/AXManager.swift:165`
- The caller that feeds app-originated frame-change notifications into it — `AXEventHandler.shouldSuppressFrameChangedRelayout` at `Sources/Nehir/Core/Controller/AXEventHandler.swift:745`
- The state maps: `lastAppliedFrames` (`:55`), `pendingFrameWrites` (`:56`), `recentFrameWriteFailures` (`:57`), `retryBudgetByWindowId` (`:58`)

## The code in question

The suppression function, verbatim — note the two conditions checked, and what is *not*
checked:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:165
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil {
        return true
    }
    guard let observedFrame,
          let lastAppliedFrame = lastAppliedFrames[windowId]
    else {
        return false                       // ← failure path lands here: no pending, no lastApplied
    }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

What happens on a *failed* write (`handleFrameApplyResults`, `AXManager.swift:804`):

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:810  — pending cleared BEFORE the success/failure split
pendingFrameWrites.removeValue(forKey: resolvedWindowId)

if let confirmedFrame = resolvedResult.confirmedFrame {
    // ... success: AXManager.swift:823 sets lastAppliedFrames[id] = confirmedFrame; clears failure
    lastAppliedFrames[resolvedWindowId] = confirmedFrame
    recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
    ...
    continue
}

// Sources/Nehir/Core/Ax/AXManager.swift:832 — FAILURE branch: records the failure, sets NO lastAppliedFrames
if let failureReason = resolvedResult.writeResult.failureReason {
    recentFrameWriteFailures[resolvedWindowId] = failureReason   // :839
}
// retryBudget handling follows (:845–862); lastAppliedFrames[id] is NEVER assigned here
```

And the safety precondition the fix relies on — the failure flag is cleared the instant
a *new* frame is enqueued, so suppression cannot outlive a legitimate layout change:

```swift
// Sources/Nehir/Core/Ax/AXManager.swift:601–602  (enqueue path)
pendingFrameWrites[windowId] = frame
recentFrameWriteFailures.removeValue(forKey: windowId)   // ← failure flag cleared on every enqueue
```

## Why it applies (the loop, traced in nehir)

A min-size-constrained app (App Store, Xcode, etc.) enforces a minimum window size.
nehir's column-width math does **not** yet respect that minimum (that is the separate
#384 layout-side pairing, for which no nehir discovery/fix exists yet), so it computes
a target smaller than the app's enforced minimum. Then:

1. **Write fails.** nehir writes the too-small frame; the app clamps it back to its
   minimum; the readback observes the clamped (larger) frame ≠ target → `.verificationMismatch`.
   `handleFrameApplyResults` clears `pendingFrameWrites[id]` (`:810`) and records
   `recentFrameWriteFailures[id] = .verificationMismatch` (`:839`). `lastAppliedFrames[id]`
   is **not** set on the failure branch.
2. **A bounded retry fires once.** `retryBudgetByWindowId` is seeded to `1` on enqueue
   (`:623`); `shouldRetryFrameWrite` returns true for `.verificationMismatch` (`:889`).
   The retry re-enqueues the **same** failing target (`let frame = resolvedResult.targetFrame`,
   `:859`) via a `Task` (`:861`), which re-clears the failure flag (`:602`) and fails
   the identical way, exhausting the budget. That is 2 of the "30+" failures.
3. **The app's snap-back notification is not suppressed.** The clamp-back posts
   `kAXFrameChangedNotification`; `AXEventHandler` routes it to
   `shouldSuppressFrameChangeRelayout` (`AXEventHandler.swift:745`). With `pendingFrameWrites`
   cleared and `lastAppliedFrames` either nil or a stale prior frame ≠ the observed
   min-size frame, the function returns **false** (`AXManager.swift:165` → falls through
   the guard at `:170`).
4. **Unsuppressed relayout re-enqueues the identical target.** Because the layout math
   still does not know the min-size, it recomputes the same too-small frame and enqueues
   it → step 1 repeats. The app's own snap-back is the self-sustaining trigger; without
   it the loop has no fuel.

PR #403's fix removes the trigger at step 3: adding
`if recentFrameWriteFailures[windowId] != nil { return true }` makes the snap-back
notification suppressed during the post-failure window, so no relayout is kicked off,
so the identical target is never re-enqueued by the app. The bounded retry (step 2)
still runs and self-terminates; genuine layout changes (focus, workspace switch, window
add) clear the failure flag on enqueue (`:602`) and proceed normally.

### Why this is not already covered (not a noop)

Two existing nehir mechanisms are *related but do not close this gap*:

- **The resize-minimum learner** (`LayoutRefreshController`, see the sibling discovery
  `20260614-ax-frame-write-verification-race.md` §3a) eventually learns the app's
  minimum and pins it into the solver so future targets respect it — the structural
  fix (and the #384-side concept). But it is slower-timescale: it needs at least one
  failed write to learn, and per §3a of that doc a transient mismatch can *cascade*
  rather than converge. It does nothing about the burst of snap-back-driven relayouts
  *during* the failed-write window.
- **The dedup path already consults the failure flag** — `!hasRecentFailure` at
  `AXManager.swift:558` (`hasRecentFailure` computed at `:538`). This means a failing
  window is deliberately *not* deduped and *is* re-written on a legitimate relayout.
  That is a different axis (dedup of computed targets vs suppression of app-originated
  notifications) and is consistent with the fix: it keeps legitimate retries working
  while the fix stops the spurious app-triggered relayout. The two are complementary.

The sibling discovery `20260614-ax-frame-write-verification-race.md` **flagged this
exact gap** in §6.5 ("shouldSuppressFrameChangeRelayout ends with the pending window …
a late-arriving notification from a racy write can still trigger a follow-on relayout")
but proposed options A–D aimed at the *readback verification oracle*, none of which is
"add `recentFrameWriteFailures` to the suppression function." So this is the narrow,
low-risk fix the sibling doc identified but did not adopt — not a duplicate of it.

## Recommendation

**Port the concept (adapted).** Add one branch to
`shouldSuppressFrameChangeRelayout` that suppresses while a recent failure is recorded:

```swift
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil { return true }
    if recentFrameWriteFailures[windowId] != nil { return true }   // ← the PR #403 fix
    guard let observedFrame,
          let lastAppliedFrame = lastAppliedFrames[windowId]
    else { return false }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

This is safe in nehir specifically because the failure flag is already cleared on every
enqueue (`AXManager.swift:602`), so the suppression window is bounded to "after a
failed write, before the next legitimate write" — exactly the window in which the
app's snap-back is spurious. It does not need any of the unrelated 18 commits in the
closed PR.

Caveats to handle at implementation time (not blockers, but verify):

- This is a **band-aid on the trigger**, not the root cause. The loop fundamentally
  exists because nehir computes a sub-minimum target (#384 layout side). Pair this fix
  with a #384 discovery/port (respect min-size in column-width math); the two are
  complementary: #403 suppresses the thrash now, #384 stops computing the bad target.
- Confirm the failure flag is *not* cleared anywhere between a failed write and the
  next enqueue other than `:602` (e.g. `suppressFrameWrites` at `:709–710` clears it,
  but that path also tears down all per-window state, so suppression there is moot).
  A grep for `recentFrameWriteFailures.removeValue` / `removeAll` is the audit.

## Suggested tests

The loop is structurally testable (unlike the readback race itself): the failure flag
and suppression are plain state, no live window server needed.

1. **Suppression after failure, before next enqueue.** Seed
   `recentFrameWriteFailures[id] = .verificationMismatch` with `pendingFrameWrites[id]`
   nil and `lastAppliedFrames[id]` nil/stale; assert
   `shouldSuppressFrameChangeRelayout(for: id, observedFrame: <min-size frame>)` returns
   `true`. (This is the regression test for the fix — it currently returns `false`.)
2. **Suppression ends on legitimate enqueue.** After enqueueing a fresh frame for the
   same id (which clears the flag at `:602`), assert suppression returns `false` for an
   unrelated observed frame — proving legitimate relayouts still proceed.
3. **End-to-end loop bound (optional, via the test frame-apply override).** Using
   `frameApplyOverrideForTests` / `frameApplyAsyncOverrideForTests`
   (`AXManager.swift:649`/`:657`), force a persistent `.verificationMismatch` for a
   window whose target is below a fake min-size, then synthesize the app snap-back
   `kAXFrameChangedNotification`. Assert the number of frame enqueues over N AX ticks is
   bounded (≈ the single original write + its 1 retry), not unbounded. This locks in
   that the self-sustaining trigger is broken.
