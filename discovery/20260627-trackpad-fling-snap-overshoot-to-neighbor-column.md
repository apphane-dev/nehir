# Discovery: trackpad fling-snap overshoots to a neighbor column's far edge

Status: discovery only — captures one reproducible "viewport jump" that is
**not** the unrecorded-mutation class. It is the intended fling-snap behavior
(momentum projection + nearest-snap selection) firing on a small, fast flick,
and landing on a different column's edge. Recorded here so a future plan can
decide whether to retune momentum or snap selection. Out of scope for the
`20260625-unrecorded-viewport-offset-mutation-attribution` plan, which
explicitly defers snap targeting and momentum thresholds.

Verified against the main Nehir source tree on 2026-06-27 (source line numbers
below are durable code citations).

## Summary

A trackpad three-finger horizontal scroll with a **small committed displacement**
but **high release velocity** can land the viewport a full column away from
where the finger actually dragged. The viewport does not move during the drag;
the jump happens at gesture end, as a single spring animation toward a snap
point that belongs to a neighbor column.

This is distinct from the "viewport shifts before a committed gesture" bug:
here the pre-end state is consistent (the gesture-update records track the
finger), and the discontinuity is entirely at `touch_scroll_gesture_end`,
produced by `endGesture`'s momentum projection and nearest-snap selection. With
the viewport-mutation audit instrumentation in place, the move is fully
attributed (`lastViewportMutation=endGesture.spring`), confirming it is not a
silent write.

## Topology / repro

- Single monitor, one workspace with many columns (capture had 12 columns).
- Active column: index 2 (a 972 pt proportional column).
- Neighbor: index 3, a wide column (1875.6 pt, manual width override, preset 3).
- Action: a short, fast three-finger horizontal trackpad flick while column 2 is
  active, released mid-flick.

## Evidence (inlined from the capture)

### During the drag — finger movement tracked correctly

Committed gesture updates, active column 2, offset creeping with the finger:

```text
reason=touch_scroll_gesture_update phase=committed delta=2.376 activeColumnIndex=2 currentOffset=209.4 currentViewStart=2217.4
reason=touch_scroll_gesture_update phase=committed delta=2.268 activeColumnIndex=2 currentOffset=213.2 currentViewStart=2221.2
reason=touch_scroll_gesture_update phase=committed delta=2.079 activeColumnIndex=2 currentOffset=216.8 currentViewStart=2224.8
```

So the finger only moved the viewport ~7 pt total (`2217.4 -> 2224.8`), and the
active column stayed at index 2 throughout.

### At gesture end — projection overshoots, snap jumps to column 3

The end-candidate record (the decision point):

```text
reason=touch_scroll_gesture_end_candidate snap=true
  activeColumnIndex=2
  currentOffset=216.780
  currentViewStart=2224.780
  projectedOffset=516.258
  projectedViewStart=2524.258
  velocity=899.786
  closestSnap=2879.600
  closestSnapColumn=3
  closestSnapKind=rightEdge
  closestSnapDistance=355.342
  targetOffset=871.600
```

Read this carefully:

- **Actual position:** `currentViewStart=2224.8` (inside column 2, which spans
  roughly 2008–2980).
- **Velocity:** `899.786` — high, from a fast flick despite the tiny displacement.
- **Momentum projection:** `projectedViewStart=2524.3` — `SwipeTracker`'s
  `projectedEndPosition()` carries the predicted end ~300 pt forward. Note this
  projected point is *still inside column 2*.
- **Chosen snap:** `closestSnap=2879.6` on **column 3**, `rightEdge`, distance
  `355.3` from the projection. Column 2's own snap points (left/right edge near
  the viewport bounds, center near 2494) were apparently farther from the
  projected 2524.3 than column 3's right edge at 2879.6.

### Result — single attributed spring to column 3

```text
reason=touch_scroll_gesture_end endedActiveColumnIndex=3
  currentOffset=-533.5 targetOffset=-132.4
  currentViewStart=2438.7 targetViewStart=2879.6
  gesture=false animating=true
  lastViewportMutation=endGesture.spring
  lastViewportMutationCaller=Nehir/ViewportState+Gestures.swift endGesture(...)
  lastViewportMutationBeforeCurrentOffset=216.8 lastViewportMutationBeforeKind=gesture
  lastViewportMutationAfterCurrentOffset=-782.0 lastViewportMutationAfterKind=spring
```

Then the spring runs and settles:

```text
reason=scroll_animation_start currentViewStart=2479.2 targetViewStart=2879.6 animating=true
reason=scroll_animation_stop  currentViewStart=2879.6 targetViewStart=2879.6 animating=false
```

Net effect: a ~7 pt finger drag produced a **~655 pt viewport leap**
(`2224.8 -> 2879.6`) onto column 3's right edge.

### A focus-confirm fired mid-snap and correctly did nothing

A window in column 3 (`WindowToken(pid: 90499, windowId: 24238)`) was
focus-confirmed while the snap spring was still running:

```text
reason=ax_focus_confirm_before_activate preserveActiveViewport=true wasAnimating=true
reason=ax_focus_confirm_reveal_skipped   preserveActiveViewport=true
```

`preserveActiveViewport=true` + `reveal_skipped` means the reveal path saw the
ongoing animation and did not fight it. This part is correct and is **not** part
of the defect.

## Root cause (source)

The discontinuity is produced by `endGesture` in
`Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift`:

1. Momentum projection at `ViewportState+Gestures.swift:110-114`:
   ```swift
   let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
   let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker
   ...
   let projectedViewPos = Double(activeColX) + projectedOffset
   ```
   `projectedEndPosition()` lives in `Sources/Nehir/Core/Animation/SwipeTracker.swift:42`
   and is `position - v / (1000 * log(decelerationRate))`. A high `v` (899.8)
   dominates the term and projects far forward regardless of how little the
   finger actually displaced the viewport.

2. Nearest-snap selection at `ViewportState+Gestures.swift:124`:
   ```swift
   guard let targetSnap = context.closest(to: CGFloat(projectedViewPos)) else { ... }
   ```
   `context.closest(to:)` picks the globally nearest snap point to the
   projection. When the projected position lands in a "dead zone" between the
   active column's own snap points and a neighbor's, the neighbor's edge can be
   nearer — so the active column silently changes from 2 to 3.

The combination is what makes it feel like a jump: the projection is velocity-
dominated (small drag + high speed), and the global nearest-snap has no
preference for staying in the active column.

## Why it is not the unrecorded-mutation bug

- The pre-end viewport state is consistent with the finger input (updates track
  the drag).
- The end move is a single `endGesture.spring`, fully attributed by the audit
  (`lastViewportMutationCaller=endGesture`).
- No `currentViewStart` change lacks a named mutation record between the last
  gesture update and the spring.

## Candidate fix directions (all behavior changes — deferred)

Each touches gesture feel and was explicitly carved out of the
unrecorded-mutation plan, so each needs its own plan + repro set:

1. **Clamp the projection by actual displacement.** In `SwipeTracker` or in
   `endGesture`, bound `projectedEndPosition()` so a high-velocity release cannot
   project more than (say) one column width beyond the actual drag. Keeps
   momentum for real flings; kills the small-drag overshoot.
2. **Prefer the active column in snap selection.** When the projected position is
   still geometrically inside the active column (or within its snap candidates),
   do not let `context.closest(to:)` jump to a neighbor column's edge. Reserve
   cross-column snaps for projections that actually leave the active column.
3. **Velocity gating.** Require both a minimum displacement *and* a minimum
   velocity before momentum projection is applied; otherwise snap from the
   release position directly.

Any of these would also need regression coverage against the existing
`ViewportGeometryTests` gesture suite (snap-back, momentum snap at strip end,
preserve-offset tests), which currently encode the present projection/snap
behavior as correct.

## References

- `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:110` (momentum
  projection), `:124` (nearest-snap selection), `:128` (snap result).
- `Sources/Nehir/Core/Animation/SwipeTracker.swift:42`
  (`projectedEndPosition()`).
- Related plan: `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`
  (explicitly defers snap targeting and momentum thresholds).
