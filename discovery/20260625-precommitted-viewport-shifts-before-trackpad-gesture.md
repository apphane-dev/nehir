# Discovery: viewport shifts before committed trackpad gesture

Status: discovery only — the trace proves two pre-commit viewport discontinuities, and the main source tree proves those shifts were already in viewport state before the gesture handler applied user scroll delta. The captured evidence is not enough to identify the mutation site, so this is not yet a fix plan.

Validated against `main` on 2026-06-25 at commit `8887adcb`.

## Summary

A runtime trace captured on 2026-06-25 between `09:08:15Z` and `09:09:00Z` shows two cases where the Niri viewport start changed between a stable `scroll_animation_stop` and the next `touch_scroll_gesture_armed` / `touch_scroll_gesture_committed` records.

Source validation matters here: `touch_scroll_gesture_armed` is emitted while the handler is still in its `.idle` gesture phase. In that branch, `MouseEventHandler` only stores the locked gesture context and start touch coordinates, sets the handler-side phase to `.armed`, and records the trace. It does **not** call `beginGesture` or `updateGesture`; the viewport state is first changed by the handler later in `applyTrackpadViewportScrollDelta`, after the `.committed` threshold path.

Therefore, the two shifted viewport values present in the `armed` records were already in `ViewportState` before Nehir accepted a user scroll delta for the new gesture.

## Evidence from the trace

### Shift 1: `-8.0 -> -58.8` before the new gesture committed

Stable state:

```text
2026-06-25T09:08:35Z reason=scroll_animation_stop displayId=1 columns=5 activeColumnIndex=0 currentOffset=-8.0 targetOffset=-8.0 currentViewStart=-8.0 targetViewStart=-8.0 gesture=false animating=false selectedNode=054AAC30-79B5-427D-947E-B655FB29BFDA preferredFocus=WindowToken(pid: 32351, windowId: 20101) confirmedFocus=WindowToken(pid: 32351, windowId: 20101)
```

Next viewport-bearing record for that workspace:

```text
2026-06-25T09:08:48Z reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 startTouch=0.702,0.621 columns=5 activeColumnIndex=0 currentOffset=-58.8 targetOffset=-58.8 currentViewStart=-58.8 targetViewStart=-58.8 gesture=false animating=true selectedNode=054AAC30-79B5-427D-947E-B655FB29BFDA preferredFocus=WindowToken(pid: 32351, windowId: 20101)
```

Then commit/update:

```text
2026-06-25T09:08:49Z reason=touch_scroll_gesture_committed cumulativeX=-14.774 cumulativeY=-9.775 threshold=16.000 currentViewStart=-58.8 targetViewStart=-58.8 gesture=false animating=true
2026-06-25T09:08:49Z reason=touch_scroll_gesture_update delta=36.936 currentViewStart=4.0 targetViewStart=4.0 gesture=true animating=false
```

Interpretation: the viewport was already at `-58.8` before the first accepted scroll delta (`delta=36.936`).

### Shift 2: `1211.2 -> ~1566.8` before the new gesture committed

Stable state:

```text
2026-06-25T09:08:49Z reason=scroll_animation_stop displayId=1 columns=5 activeColumnIndex=1 currentOffset=-719.2 targetOffset=-719.2 currentViewStart=1211.2 targetViewStart=1211.2 gesture=false animating=false selectedNode=1D65853B-F032-4007-9825-F2AC2F76991E preferredFocus=WindowToken(pid: 45090, windowId: 21152) confirmedFocus=WindowToken(pid: 45090, windowId: 21152)
```

Next viewport-bearing record for that workspace:

```text
2026-06-25T09:08:50Z reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 startTouch=0.662,0.506 columns=5 activeColumnIndex=1 currentOffset=-364.5 targetOffset=-363.6 currentViewStart=1565.9 targetViewStart=1566.8 gesture=false animating=true selectedNode=1D65853B-F032-4007-9825-F2AC2F76991E preferredFocus=WindowToken(pid: 45090, windowId: 21152) confirmedFocus=WindowToken(pid: 45090, windowId: 21152)
```

Then commit/update:

```text
2026-06-25T09:08:50Z reason=touch_scroll_gesture_committed cumulativeX=-14.893 cumulativeY=-8.946 threshold=16.000 currentViewStart=1566.8 targetViewStart=1566.8 gesture=false animating=true
2026-06-25T09:08:50Z reason=touch_scroll_gesture_update delta=37.233 currentViewStart=1630.1 targetViewStart=1630.1 gesture=true animating=false
```

Interpretation: the viewport was already near `1566.8` before the first accepted scroll delta (`delta=37.233`).

## Source validation

Relevant source paths are repository-relative.

### `touch_scroll_gesture_armed` is diagnostic/handler state only

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1625-1648` handles the `.idle` case. It resolves and stores `lockedGestureContext`, records `gestureStartX/Y`, sets the mouse handler's `gesturePhase = .armed`, and emits `reason=touch_scroll_gesture_armed`.

No viewport mutation happens in this branch: no `beginGesture`, no `updateGesture`, no `viewOffsetPixels` assignment.

### The user scroll delta is only applied after commitment

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1690-1729` computes cumulative touch movement and only crosses into `.committed` after threshold and horizontal-direction checks. Then `MouseEventHandler.swift:1742-1748` calls `applyTrackpadViewportScrollDelta`.

`Sources/Nehir/Core/Controller/MouseEventHandler.swift:1767-1795` is where viewport mutation for the new gesture occurs:

- if an existing viewport animation is active, it calls `vstate.settleAtCurrentOffset()`;
- it prepares/seeds viewport geometry;
- if not already a gesture, it calls `vstate.beginGesture(...)`;
- it applies the accepted scroll delta via `vstate.updateGesture(...)`.

The trace records `touch_scroll_gesture_update` only after this path (`MouseEventHandler.swift:1800-1810`).

### Beginning a gesture preserves the current viewport offset

`Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:14-18` begins a gesture by reading `viewOffsetPixels.current()` and wrapping that offset in `.gesture(ViewGesture(...))`. It does not choose a new snap point or intentionally shift the viewport by itself.

### Trace values are read from current viewport state

`Sources/Nehir/Core/Controller/WMController.swift:2497-2529` computes runtime trace fields from the current `ViewportState`: `currentViewStart`, `targetViewStart`, current/target offsets, `gesture`, and `animating`. Thus the shifted values on the `touch_scroll_gesture_armed` records reflect the viewport state at trace time, not a special value calculated by the gesture recognizer.

## What remains unknown

The trace does not include the mutation that changed the viewport between:

- `09:08:35Z scroll_animation_stop currentViewStart=-8.0` and `09:08:48Z touch_scroll_gesture_armed currentViewStart=-58.8`; or
- `09:08:49Z scroll_animation_stop currentViewStart=1211.2` and `09:08:50Z touch_scroll_gesture_armed currentViewStart≈1566.8`.

The second `armed` record already says `gesture=false animating=true`, which implies the viewport state had become animated again before the new gesture was committed. But the trace lacks a causal record naming the code path that created that animation or target.

## Recommended next investigation

Add temporary trace records around every non-gesture viewport mutation path that can run between gestures, especially paths that assign `.spring`, call `animateToOffset`, call `setStaticOffset`, offset `viewOffsetPixels`, or reseed/restore single-window viewport offsets. Include:

- old/current/target offset and active column before mutation;
- new/current/target offset and active column after mutation;
- reason/caller label;
- selected, preferred-focus, and confirmed-focus window tokens.

Useful starting areas:

- `Sources/Nehir/Core/Layout/Niri/ViewportState+Animation.swift`
- `Sources/Nehir/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+Windows.swift`
- `Sources/Nehir/Core/Layout/Niri/NiriLayout.swift` single-window viewport seeding/centering paths

## Suggested tracing improvements

The next capture should make the missing mutation self-identifying. Suggested changes:

1. Add a centralized viewport mutation audit helper, for example `recordViewportMutation(workspaceId:reason:before:after:)`, and call it around every intentional viewport state mutation. Each record should include both before/after values for `currentOffset`, `targetOffset`, `currentViewStart`, `targetViewStart`, `activeColumnIndex`, and the offset kind (`static`, `spring`, or `gesture`).

2. Trace every `viewOffsetPixels` write and offset adjustment. The most important writes are in animation helpers (`cancelAnimation`, `settleAtCurrentOffset`, `animateToOffset`, static-offset setters, reset paths), column-transition helpers, viewport commands, window insertion/removal paths, and single-window centering/seeding paths.

3. Trace every `.spring(...)` assignment with animation provenance: `caller`, `from`, `to`, `initialVelocity`, `startTime`, active column, selected node, preferred focus token, and confirmed focus token. The suspicious records already show `gesture=false animating=true`, so the missing record is likely an animation creation or animation-preserving reseed.

4. Trace prepare/seed calls only when they change viewport state. For `prepareAndSeedSingleWindowViewport` and nearby layout preparation paths, emit a before/after record such as `reason=viewport_prepare_seed_changed_state` when current/target offset, active column, or offset kind changes.

5. Emit an explicit anomaly record when arming a new gesture finds preexisting animation state, for example `reason=touch_scroll_gesture_armed_with_preexisting_animation`, including the last known mutation reason and age if available. In the captured trace, both anomalous `armed` records had `gesture=false animating=true` before the first committed update.

6. Store debug-only last-mutation provenance on `ViewportState`, such as `lastViewportMutationReason`, `lastViewportMutationTimestamp`, and compact before/after offset values. Then append `lastViewportMutation` and `lastViewportMutationAgeMs` to every runtime viewport trace line. This would turn a gap like `scroll_animation_stop -> touch_scroll_gesture_armed` into a directly attributable sequence.

Once the missing mutation is captured, promote this discovery into a fix plan with the exact offending path and tests.
