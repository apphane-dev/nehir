# Fix trackpad recognition debt and release projection — Plan

Verified against `main` plus the diagnostics branch `gesture-traces` on 2026-07-01
(`a67afc14 Add runtime diagnostics for gesture, navigation, and frame issues`, based on
`07ce4168 Reconcile stale hidden-window live frames`). This plan covers gesture
**movement dynamics** after a gesture has been admitted. Gesture admission itself is
covered by `planned/20260701-fix-trackpad-idle-changed-admission-and-contact-ramp.md`.

---

## Problems

Two independent dynamics problems are visible in the improved swipe captures:

1. The first committed gesture update applies the full pre-recognition movement, creating
   a catch-up jump.
2. Release projection uses unbounded trackpad velocity, allowing a release to snap across
   many columns.

They share the same code area (`MouseEventHandler` and `ViewportState+Gestures`) and should
be fixed together only if each sub-fix is independently validated.

---

## Runtime evidence — recognition debt

The first-update diagnostic ties the commit threshold movement to the first applied delta.
Several examples show that the applied delta is far larger than the movement beyond the
recognition threshold:

```text
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=-17.388 threshold=16.000 rawDelta=-17.388 appliedDelta=165.187 wouldDeadZoneDelta=13.187 includesRecognitionDebt=true commitInputPhase=changed
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=17.723 threshold=16.000 rawDelta=17.723 appliedDelta=-168.368 wouldDeadZoneDelta=-16.368 includesRecognitionDebt=true commitInputPhase=changed
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=15.887 threshold=16.000 rawDelta=15.887 appliedDelta=-150.926 wouldDeadZoneDelta=-0.000 includesRecognitionDebt=true commitInputPhase=changed
```

Another capture with higher sensitivity made the same problem larger:

```text
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=16.459 threshold=16.000 rawDelta=16.459 appliedDelta=-304.497 wouldDeadZoneDelta=-8.497 includesRecognitionDebt=true commitInputPhase=changed
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=22.000 threshold=16.000 rawDelta=22.000 appliedDelta=-406.995 wouldDeadZoneDelta=-110.995 includesRecognitionDebt=true commitInputPhase=changed
reason=touch_scroll_gesture_first_update input=trackpadTouches commitCumulativeX=-15.660 threshold=16.000 rawDelta=-15.660 appliedDelta=289.712 wouldDeadZoneDelta=0.000 includesRecognitionDebt=true commitInputPhase=changed
```

The current implementation reports `includesRecognitionDebt=true` for every captured first
update. In cases where `wouldDeadZoneDelta=0.000`, the first visual movement should have
been zero, but main applied hundreds of points.

---

## Runtime evidence — unbounded release projection

Release-candidate diagnostics show projections that would be clamped by a one-screen
diagnostic clamp and that sometimes target the opposite edge of a ten-column workspace:

```text
activeColumnIndex=1 currentViewStart=2422.369 projectedViewStart=4548.869 velocity=6389.088 closestSnapColumn=5 targetColumnDelta=4 projectionScreens=1.068 wouldClamp=true clampedTargetColumn=5
activeColumnIndex=5 currentViewStart=3561.187 projectedViewStart=965.597 velocity=-7798.475 closestSnapColumn=1 targetColumnDelta=-4 projectionScreens=-1.303 wouldClamp=true clampedTargetColumn=2
activeColumnIndex=0 currentViewStart=-799.895 projectedViewStart=1823.175 velocity=7881.037 closestSnapColumn=2 targetColumnDelta=2 projectionScreens=1.317 wouldClamp=true clampedTargetColumn=1
```

A harder swipe produced much larger projections:

```text
activeColumnIndex=1 currentViewStart=-1855.552 projectedViewStart=-13509.797 velocity=-35015.283 closestSnapColumn=0 targetColumnDelta=-1 projectionScreens=-5.851 wouldClamp=true clampedTargetColumn=0
activeColumnIndex=0 currentViewStart=535.929 projectedViewStart=12588.325 velocity=36211.534 closestSnapColumn=9 targetColumnDelta=9 projectionScreens=6.050 wouldClamp=true clampedTargetColumn=3
activeColumnIndex=9 currentViewStart=8365.156 projectedViewStart=-1756.157 velocity=-30409.576 closestSnapColumn=0 targetColumnDelta=-9 projectionScreens=-5.081 wouldClamp=true clampedTargetColumn=7
```

The strongest capture projected more than ten screens:

```text
activeColumnIndex=0 currentViewStart=2821.077 projectedViewStart=30993.529 velocity=84644.387 closestSnapColumn=9 targetColumnDelta=9 projectionScreens=14.143 wouldClamp=true clampedTargetColumn=5
activeColumnIndex=9 currentViewStart=7103.483 projectedViewStart=-15781.229 velocity=-68757.325 closestSnapColumn=0 targetColumnDelta=-9 projectionScreens=-11.488 wouldClamp=true clampedTargetColumn=5
```

---

## Source comparison

Diagnostics branch source confirms the behavior is still main behavior:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` records
  `touch_scroll_gesture_first_update`, but the diagnostic comments state that the commit
  branch still applies the full accumulated pre-recognition movement as the first delta.
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` computes diagnostic clamp fields
  for `touch_scroll_gesture_end_candidate`, but `clampScreens=nil` records that main does
  not configure or apply a clamp.
- `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift` still chooses the closest
  snap from raw `projectedTrackerPos + gesture.deltaFromTracker`.

---

## Fix strategy

### Phase 1 — recognition dead-zone

When an armed gesture crosses the horizontal threshold, compute the first delta as only
the overshoot beyond the threshold along the committed axis:

```text
firstDelta = sign(cumulativeX) * max(0, abs(cumulativeX) - threshold)
```

Then apply sensitivity and inversion to this dead-zone-adjusted value. Preserve the
existing non-horizontal rejection before committing.

Validation expectation:

- `touch_scroll_gesture_first_update` should show `appliedDelta` close to
  `wouldDeadZoneDelta`.
- Cases with `abs(commitCumulativeX) <= threshold` should apply approximately zero first
  delta.

### Phase 2 — release projection clamp

Clamp trackpad release projection by screen distance before choosing the closest snap.
The diagnostic clamp used `1.0` screen; earlier experimental tuning used a stricter value.
Choose the product value only after real-repro validation. Suggested approach:

- introduce a setting/internal constant such as `maxTrackpadGestureProjectionScreens`;
- compute `projectionDeltaFromCurrent = rawProjectedViewStart - currentViewStart`;
- clamp that delta to `±maxTrackpadGestureProjectionScreens * viewportWidth`;
- choose the closest snap from the clamped projected view start;
- record both raw and clamped projection values for validation.

Validation expectation:

- hard flicks should not select a target several screens away purely because of release
  velocity;
- `wouldClamp=true` captures should show the actual target matching the clamped target,
  not the raw `closestSnapColumn`;
- normal slow swipes (`wouldClamp=false`) should keep existing snap behavior.

---

## Risks

- Too-small projection clamp can make deliberate fast flings feel unresponsive. Validate on
  ten-column workspaces before choosing the constant.
- Dead-zone subtraction changes first-frame feel; it should remove the catch-up jump but
  still allow immediate movement once the threshold is crossed.
- Do not combine this with the idle-admission fix in one validation pass unless the user is
  explicitly testing the whole gesture stack; otherwise it becomes hard to know which fix
  changed behavior.

No tests should be added until the runtime fix is confirmed in the real repro.

---

## Implementation outcome — completed 2026-07-01

Implemented and committed in the main Nehir source tree as:

```text
8571b2d0 Fix trackpad swipe dead-zone and projection clamp
```

Source changes:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift`
  - The armed→committed transition now applies only horizontal movement beyond the
    recognition dead zone as the first committed delta.
  - `touch_scroll_gesture_first_update` diagnostics now compare `appliedDelta` with the
    dead-zone-adjusted expected delta and report `includesRecognitionDebt=false` when they
    match.
- `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift`
  - Trackpad release projection is clamped to `maxTrackpadGestureProjectionScreens = 1.0`
    screen before snap selection.
  - Release-candidate diagnostics preserve raw projection fields while also reporting the
    clamped projection and target.
- `Tests/NehirTests/MouseEventHandlerTests.swift`
  - After runtime confirmation, the trackpad commit tests were updated to assert the
    dead-zone-overshoot behavior instead of the former cumulative armed-delta behavior.
- `.changeset/20260701191524-fix-trackpad-swipe-catch-up-jumps-and-clamp-rele.md`
  - Added the patch release note.

Runtime validation after the fix:

- First-update samples all matched the dead-zone-adjusted delta:

```text
commitCumulativeX=-17.291 threshold=16.000 appliedDelta=23.882 wouldDeadZoneDelta=23.882 includesRecognitionDebt=false
commitCumulativeX=-17.226 threshold=16.000 appliedDelta=22.683 wouldDeadZoneDelta=22.683 includesRecognitionDebt=false
commitCumulativeX=15.747 threshold=16.000 appliedDelta=-0.000 wouldDeadZoneDelta=-0.000 includesRecognitionDebt=false
```

- Release projection samples kept the raw high-velocity projection for diagnostics while
  snapping from the clamped projection:

```text
rawProjectionScreens=5.838 projectionScreens=1.000 rawTargetColumnDelta=9 targetColumnDelta=3 clampedTargetColumn=3
rawProjectionScreens=-5.129 projectionScreens=-1.000 rawTargetColumnDelta=-9 targetColumnDelta=-3 clampedTargetColumn=6
rawProjectionScreens=-4.023 projectionScreens=-1.000 rawTargetColumnDelta=-6 targetColumnDelta=-4 clampedTargetColumn=2
```

- For all checked end candidates, the final ended column matched `clampedTargetColumn`, not
  the raw projected snap target.

Verification:

```text
mise run build
mise run test
```

Both completed successfully after the regression-test update.
