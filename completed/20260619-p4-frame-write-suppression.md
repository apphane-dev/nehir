# P4 — Suppress app-originated frame-change relayout after a recent AX frame-write failure

**Status:** completed — shipped on `main` in `0162aab4` ("Suppress frame-change relayout after a recent frame-write failure (P4)").
**Cluster:** upstream-port patch track (P4)
**Source concept:** closed Hiro PR #403; nehir-native recommendation.
**Discovery docs:**
- Primary: `completed/20260618-upstream-frame-write-failure-suppression.md`
- Root-cause sibling (background only): `20260616-omniwm-403-frame-write-race-min-size-suppression.md` (now in `completed/`)

## Completion evidence

`origin/main` contains `0162aab4` with the plan's intended source and test changes. Verified while updating this plan branch on 2026-06-19 via `git log origin/main` and `git show --stat 0162aab4`.


## Goal

Break the self-sustaining relayout loop: an app rejects a too-small frame write,
snaps back, fires `kAXFrameChangedNotification`, which nehir currently does *not*
suppress, so it triggers a relayout that re-enqueues the identical failing
target — repeating indefinitely.

Concretely, in the loop nehir's per-window state reaches:

- `pendingFrameWrite == nil` (cleared at end of the failed apply),
- `lastAppliedFrame == nil` (the failure branch never sets it),
- `recentFrameWriteFailure == .verificationMismatch` (recorded on the failed write),
- `retryBudget == 0` (the single seeded retry was spent on the same failing target).

With that exact state, `shouldSuppressFrameChangeRelayout` falls through the
`lastAppliedFrame` guard and returns `false`, so the app's own snap-back drives
a fresh relayout. P4 adds one branch so that state returns `true`, removing the
trigger.

P4 is the **trigger-side fix**. The root cause — nehir computing a
sub-minimum target — is tracked separately as **M1 / #384** (refused-frame-size
constraint feedback + respect window min-size in column-width math). P4 stops the
thrash now; M1 stops the bad target from being computed. Sequence: **P4 first,
then M1 characterization.**

## Scope

- **One branch** in `AXManager.shouldSuppressFrameChangeRelayout`.
- **Two focused tests** in `Tests/NehirTests/AXManagerTests.swift`, reusing the
  existing `.verificationMismatch` / `frameApplyOverrideForTests` harness.

## Non-goals

- Do **not** narrow suppression to "observedFrame near the failed target."
  Unconditional suppression is simplest and correct given the bounded window;
  narrowing yields no safety gain.
- Do **not** change the enqueue path's flag-clearing behavior
  (`recentFrameWriteFailures.removeValue(forKey: windowId)` at the enqueue
  site). That clearing is the property that bounds the suppression window.
- Do **not** alter the retry-budget logic, the write-side skip at
  `AXManager.swift:538` (different code path), or `lastAppliedFrames` handling.
- Do **not** attempt the optional end-to-end loop-bound test in this patch
  (synthesizing the full `AXEventHandler → LayoutRefreshController` snap-back
  loop). Defer it.

## Exact edit

File: `Sources/Nehir/Core/Ax/AXManager.swift`
Function: `shouldSuppressFrameChangeRelayout(for:observedFrame:)` (current line **165**).

Current (verified against `main` at `7b731a51`):

```swift
func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
    if pendingFrameWrites[windowId] != nil {           // line 166
        return true
    }
    guard let observedFrame,                           // line 169
          let lastAppliedFrame = lastAppliedFrames[windowId]   // line 170
    else {
        return false
    }
    return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: 0.5)
}
```

After the `pendingFrameWrites` early return (line 166-168) and **before** the
`lastAppliedFrame` guard (line 169), add:

```swift
    if recentFrameWriteFailures[windowId] != nil {
        return true
    }
```

No other source change.

## Why it is safe (bounded-clearing property)

Every legitimate relayout enqueues a fresh frame, and the enqueue path clears
the failure flag unconditionally:

```swift
// AXManager.swift:601-602
pendingFrameWrites[windowId] = frame
recentFrameWriteFailures.removeValue(forKey: windowId)
```

So the new branch can only suppress between a failed write and the next
legitimate write — exactly the window in which the app's snap-back is spurious.
A full audit of `recentFrameWriteFailures` mutation sites (teardown, rekey,
`confirmFrameWrite` success, window removal, `suppressFrameWrites` teardown,
and the success branch of `handleFrameApplyResults`) confirms no other clear
leaves the branch stranded. See the primary discovery doc for the full site list.

## Caller

`AXEventHandler.shouldSuppressFrameChangedRelayout(for:observedFrame:)`
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:826`) is the single runtime
caller; it delegates to `AXManager.shouldSuppressFrameChangeRelayout`. No change
needed there.

## Tests

File: `Tests/NehirTests/AXManagerTests.swift` (`@Suite(.serialized)`,
`@testable import Nehir`). Reuse the harness proven by
`terminalObserverFiresOnceAfterRetriesExhaustOnFailure` (line **105**), which
drives a `.verificationMismatch` via `frameApplyOverrideForTests` and reaches
the post-failure state asserted at lines **155-157**:
`recentFrameWriteFailure(for:) == .verificationMismatch`,
`lastAppliedFrame(for:) == nil`, `pendingFrameWrite(for:) == nil`.

### Test 1 — `shouldSuppressFrameChangeRelayoutAfterRecentFrameWriteFailure`

Drive a `.verificationMismatch` to terminal (mirror lines 105-158; reach the
state where the terminal observer fires). Then assert **preconditions**:
- `recentFrameWriteFailure(for: windowId) == .verificationMismatch`
- `lastAppliedFrame(for: windowId) == nil`
- `pendingFrameWrite(for: windowId) == nil`

Then assert `shouldSuppressFrameChangeRelayout` returns `true` for:
- an unrelated `observedFrame` (any frame not equal to the target), and
- `nil` observedFrame.

Fails pre-fix (current returns `false` via the `lastAppliedFrame` guard
fallthrough); passes after.

### Test 2 — `frameChangeRelayoutSuppressionEndsAfterEnqueueClearsFailure`

From the same post-failure state (assert it first), swap the override to a
**success** result (`lastAppliedFrame` set, no failure recorded) and enqueue a
fresh target via `applyFramesParallel`. Then assert:
- `recentFrameWriteFailure(for: windowId) == nil` (flag cleared on enqueue),
- `shouldSuppressFrameChangeRelayout(for: windowId, observedFrame: <unrelated>)`
  returns `false`.

This proves the bounded-clearing property: suppression is strictly bounded to
the failure window.

## Validation

```bash
swift build
swift test --filter AXManagerTests
swift test --filter AXEventHandlerTests          # the single caller
swift test --filter LayoutRefreshControllerTests  # exercises .verificationMismatch paths
swift test --filter RefreshRoutingTests
```

The two new `AXManagerTests` must pass; all four filtered suites must stay
green.

## Risks

- **Band-aid, not root cause.** Pair with M1/#384 so the bad target is never
  computed. Non-blocking for P4.
- **A real user resize during the failure window is also suppressed** until the
  next legitimate enqueue. Intended trade-off: it is better not to fight the app
  during the failed-write window than to re-write the identical failing target.
  The next enqueue re-enables normal behavior.
- Line numbers in this plan were verified at `7b731a51`; re-confirm before
  implementing since lines drift.

## Sequencing

P4 first (this patch — removes the trigger), then M1 characterization
(`discovery/20260618-refused-frame-feedback-characterization.md`) to close the
structural loop by feeding terminally refused sizes into solver constraints, and
#384 to respect window min-size in column-width math.
