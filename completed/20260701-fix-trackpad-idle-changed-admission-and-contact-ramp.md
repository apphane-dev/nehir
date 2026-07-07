# Fix trackpad idle `.changed` admission and raw contact-count ramp — Plan

**Status:** completed — shipped on `main` in `88fed658` ("Fix trackpad idle .changed
admission and raw contact-count ramp"). Moved from `planned/` to `completed/` on
2026-07-01.

Verified against `main` plus the diagnostics branch `gesture-traces` on 2026-07-01
(`a67afc14 Add runtime diagnostics for gesture, navigation, and frame issues`, based on
`07ce4168 Reconcile stale hidden-window live frames`). This plan covers only gesture
**admission correctness**. Gesture movement tuning and release projection are handled in
`completed/20260701-fix-trackpad-recognition-debt-and-release-projection.md`.

---

## Problem

Main can arm a new trackpad workspace gesture while the internal gesture state is idle but
the incoming raw phase is `.changed`, not `.began`. The improved diagnostics prove this is
not rare: across the improved swipe captures, every attempted gesture in two captures and
most gestures in another were admitted as `idleAdmissionKind=changed`.

This is risky because an idle `.changed` frame may be a stale same-count frame, a contact
count ramp frame, or a continuation after a previous sequence was reset. The handler has no
way to know which without stronger raw phase semantics.

---

## Runtime evidence

The capture contained explicit idle-admission records like:

```text
reason=touch_scroll_gesture_idle_changed_admission input=trackpadTouches inputPhase=changed requiredFingers=3 activeTouches=3 previousGesturePhase=idle startTouch=0.484,0.475 columns=10 activeColumnIndex=1 currentOffset=-30.0 targetOffset=-30.0 currentViewStart=951.0 targetViewStart=951.0
reason=touch_scroll_gesture_armed input=trackpadTouches requiredFingers=3 activeTouches=3 phase=4 inputPhaseRaw=4 inputPhaseName=changed previousGesturePhase=idle idleAdmission=true idleAdmissionKind=changed rawActiveCount=3 startTouch=0.484,0.475 previousRawActiveCount=2 activeCountDelta=1
```

More examples from later swipes:

```text
reason=touch_scroll_gesture_idle_changed_admission input=trackpadTouches inputPhase=changed requiredFingers=3 activeTouches=3 previousGesturePhase=idle startTouch=0.438,0.319 columns=10 activeColumnIndex=2 currentOffset=-520.5 targetOffset=-520.5 currentViewStart=1441.5
reason=touch_scroll_gesture_idle_changed_admission input=trackpadTouches inputPhase=changed requiredFingers=3 activeTouches=3 previousGesturePhase=idle startTouch=0.853,0.504 columns=10 activeColumnIndex=0 currentOffset=-520.5 targetOffset=-520.5 currentViewStart=-520.5
```

Counts across the improved swipe captures:

- six gestures in one capture, five of them with `idleAdmissionKind=changed`;
- five gestures in another capture, all five with `idleAdmissionKind=changed`;
- two gestures in another capture, both with `idleAdmissionKind=changed`.

The `previousRawActiveCount=2 activeCountDelta=1` detail is important: some of these are
real 2→3 contact ramps. A handler-only guard that simply rejects idle `.changed` would
also reject legitimate raw ramps unless the raw source emits `.began` for count increases.

---

## Source comparison

The diagnostics branch shows the current main behavior with extra fields only:

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` arms out of `.idle` without
  requiring `phase == .began`; the diagnostic records `idleAdmissionKind` but does not
  block changed-phase admission.
- `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift` still derives the raw
  phase as:

```swift
let phase: NSEvent.Phase = previousActiveCount == 0 ? .began : .changed
```

That means a real 1→2→3 ramp reaches the gesture handler as `.changed` even though the
third-finger arrival is the start of the configured gesture.

---

## Fix strategy

### Phase 1 — make the raw source phase semantic

Change `MultitouchGestureSource.makeSnapshot(...)` so contact-count increases emit
`.began`:

```swift
let phase: NSEvent.Phase = activeCount > previousActiveCount ? .began : .changed
```

Keep active-count drop behavior strict:

- active count `0` after nonzero still emits `.ended`;
- active count decreases while still nonzero emits `.changed`, not `.began`;
- over-count / palm / wrist noise remains rejected by the existing handler logic.

### Phase 2 — require idle admission to start from `.began`

In `MouseEventHandler.handleTouchScrollGesture(...)`, before arming from `.idle`, require
`phase == .began`. If the handler is idle and receives a valid-count `.changed`, emit a
skip diagnostic and return without arming:

```text
gesture.skip reason=changedWithoutBegin ... activeTouches=3 phase=4
```

Do not abort an already committed gesture because of this guard; it only applies to idle
admission.

### Phase 3 — preserve diagnostics

Keep the improved idle-admission diagnostics for a release or two so validation captures
can prove the fix:

- successful starts should show `idleAdmissionKind=began`;
- stale changed frames should show `gesture.skip reason=changedWithoutBegin`;
- real 2→3 ramps should not disappear; they should become `.began` at the raw source.

---

## Validation

Use a ten-column workspace and repeat fast three-finger swipes with fingers already near
the trackpad before motion. The fix is validated when:

1. no gesture arms from idle with `idleAdmissionKind=changed`;
2. real 2→3 contact ramps still arm and commit;
3. stale same-count changed frames, if present, produce `gesture.skip reason=changedWithoutBegin`;
4. strict over-count behavior is unchanged — wrist/palm noise still aborts rather than
   rearming.

No tests should be added until the runtime fix is confirmed in the real repro.

---

## Implementation notes (2026-07-01)

Implemented on branch `gesture-traces` in commit `73e2e228`, on top of the diagnostics
commit `a67afc14`. **Confirmed in a real runtime capture** (see below); build clean, full
suite green.

### What shipped

- **Phase 1** — `MultitouchGestureSource.makeSnapshot` phase derivation changed from
  `previousActiveCount == 0 ? .began : .changed` to
  `activeCount > previousActiveCount ? .began : .changed`. The active-count-0 branch still
  emits `.ended`; same-count/decreasing frames stay `.changed`.
- **Phase 2** — `MouseEventHandler`'s `.idle` switch case now starts with
  `guard phase == .began`. A valid-count idle `.changed` emits
  `gesture.skip reason=changedWithoutBegin` and returns without arming. It does **not**
  call `abortActiveGestureIfNeeded()` (nothing to abort from idle) and does not touch the
  `.armed`/`.committed` cases.
- **Phase 3** — retired the now-unreachable `touch_scroll_gesture_idle_changed_admission`
  record and simplified `idleAdmissionKind` to the constant `began` (the only value that
  can now reach the arm), keeping it as the positive validation signal.

### Decisions made

- **Removed the idle-`.changed` diagnostic instead of leaving it dead.** With the guard,
  the arm block is only reachable via `.began`, so the anomaly record could never fire; the
  replacement signal is the `changedWithoutBegin` skip. Kept `idleAdmissionKind=began` and
  the `previousRawActiveCount`/`activeCountDelta` fields so a capture still proves ramps arm.
- **The guard returns rather than aborts.** Idle admission has no active gesture to abort;
  aborting would only risk clearing unrelated suppression flags.

### Validation evidence

A ten-column swipe capture confirmed all four criteria:

- 10 arms, **all `idleAdmissionKind=began`**, zero `idleAdmissionKind=changed`, zero
  retired-anomaly records;
- **every arm was a real 2→3 ramp** (`previousRawActiveCount=2 activeCountDelta=1`) — the
  exact input the pre-fix build admitted as `changed` — now admitted as `began`, 6 of them
  committed;
- 281 `underCount` skips (the 0→1→2 finger-landing frames now emit `.began` but are
  correctly rejected by the count guard **without arming**), zero over-count rearms;
- `changedWithoutBegin` did not fire in this clean capture — the guard is present but the
  input contained no stale same-count idle frames to reject.

### Lessons learned

- **The raw phase was the root cause, not the handler.** A handler-only "reject idle
  `.changed`" would have killed every legitimate 2→3 ramp; the fix only works because the
  raw source emits `.began` on contact-count increases first. The diagnostics'
  `previousRawActiveCount`/`activeCountDelta` fields are what proved the ramps were real and
  justified doing both halves.
- **Existing gesture tests were already compatible** — they arm with `.began` then move
  with `.changed`, which is exactly what the guard requires, so no test churn was needed.
- The diagnostics plan's `idleAdmissionKind` field paid for itself here: it turned "is idle
  `.changed` admission real?" from an inference into a one-line grep before and after the
  fix.
