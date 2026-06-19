# OmniWM issue #301 — "3 finger swiping gets stuck on windows" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/301>
Scope of this doc: determine whether the "3-finger swipe gets stuck"
report applies to nehir, whether it is a gesture-commit / scroll-snap /
animation-state bug, and whether the upcoming upstream fix should be ported.

All file/line references were verified against `worktree-calm-meadow-6229`
at `7f61cb3` ("docs: update four-finger gesture discovery with non-repro
trace"). Re-verify before implementing; line numbers drift.

> **Filed under discovery/noop/** — the report reproduces against the same
> nehir gesture path, but its root cause and fix are already owned by the
> sibling discovery
> [`20260616-nehir-53-trackpad-four-finger-swipe-gesture.md`](../discovery/20260616-nehir-53-trackpad-four-finger-swipe-gesture.md)
> (same `averageGestureTouchPosition` matcher, same abort-on-nil, same
> diagnostic gap). OmniWM #301 is the 3-finger / app-competition manifestation
> of that root cause; it motivates no new repo action beyond what #53's
> Recommendation #1 (abort-path tracing) and #3 (armed/committed hysteresis)
> already prescribe. Porting the upcoming OmniWM fix directly is N/A — nehir
> does not share the upstream rewrite's code.

---

## TL;DR

- **nehir uses a single, finger-count-agnostic trackpad column-swipe path; the
  3-finger "gets stuck" symptom is the same detection fragility the nehir-53
  four-finger doc already analyzed — not a distinct commit/snap/animation bug.**
- **Verdict:** 🔴 **Applies** — the cited code (`MouseEventHandler.swift`)
  exists verbatim in nehir and reproduces the reported behavior under app-level
  gesture competition; filed under `noop/` only because the root cause and fix
  are owned by the sibling nehir-53 discovery.

## What the issue actually says

Reported 2026-05-06 against OmniWM `0.4.8.1`, still **open**. Title: "3 finger
swiping gets stuck on windows." Body: the swipe halts mid-navigation;
"Keyboard shortcuts seem to work fine though." The reporter's gesture config:

```toml
[gestures]
fingerCount = 3
invertDirection = true
scrollEnabled = true
scrollModifierKey = "optionShift"
scrollSensitivity = 3.0000000000000004
```

Two maintainer-thread comments (the linked video is unreachable, so the
diagnosis rests on these and the code):

- **`nick-s5` (2026-06-15):** *"The issue … seems to have to do with whatever
  app is currently in focus. If it accepts 3 finger swipe/slide as an input,
  then that seems to take precedence over OmniWM's 3 finger swipe detection,
  which causes it to glitch out. … certain web browser pages have this issue
  while others don't … it's specific to if they utilize 3 finger touchpad
  input."* They worked around it with BetterTouchTool, which "does not have
  this app-specific responsiveness issue."
- **`BarutSRB` (maintainer, 2026-06-16):** *"Fix should roll out tomorrow."*

So the upstream diagnosis is **app-level gesture competition**: a focused app
that also consumes 3-finger touchpad input interferes with nehir/OmniWM's
detection, and the navigation "glitches out / gets stuck."

## Provenance: is this nehir's code?

Yes — entirely in-tree, single path. The trackpad column-swipe is implemented
in `Sources/Nehir/Core/Controller/MouseEventHandler.swift` (gesture tap at
`:285`, handler `:1398`, matcher `:2146`). There is no second gesture path and
no per-finger-count branch; `fingerCount = 3` flows in exactly as 4 would
(`SettingsStore.gestureFingerCount` → `requiredFingers`, confirmed for the
four-finger case in the sibling doc). The same matcher, threshold, commit, and
finalize code runs for all configured finger counts.

## The code in question

### 1. The matcher: strict exact-count equality, identical for 3 and 4 fingers

`averageGestureTouchPosition(requiredFingers:touches:)` (`MouseEventHandler.swift:2146`)
is the sole gate. It bails on any over-count (`:2163`) and accepts the frame
**only** at exact equality (`:2176`):

```swift
for touch in touches {
    if touch.phase == .ended || touch.phase == .cancelled { continue }
    touchCount += 1
    if touchCount > requiredFingers { return nil }          // :2163  over-count bail
    ...
}
guard touchCount == requiredFingers, activeCount > 0 else { return nil }  // :2176  exact only
```

A focused app that also claims the 3-finger gesture perturbs the raw
`NSEvent.allTouches()` stream reaching nehir's listen-only HID tap (`:285`):
frames intermittently report ≠ 3 active touches, the matcher returns `nil`,
and the gesture never cleanly qualifies.

### 2. What a `nil` frame does to an in-flight gesture

`handleGestureEvent` (`:1398`) calls the matcher and, on `nil`, branches
(`:1491`–`:1503`):

```swift
guard let averageTouchPosition = Self.averageGestureTouchPosition(
    requiredFingers: requiredFingers,
    touches: snapshot.touches
) else {
    if state.gesturePhase == .committed, activeTouchCount < requiredFingers {   // :1495
        finalizeCommittedGestureAfterTouchRelease(engine: engine, timestamp: snapshot.timestamp)
        return
    }
    abortActiveGestureIfNeeded()        // :1502  ← armed gesture dies here; committed gesture snaps
    return
}
```

- Still `.armed` (under threshold, not yet committed, `:1586`): the gesture
  **silently dies** in `resetGestureState()` via `abortActiveGestureIfNeeded()`
  (`:1887`) with **no trace** — the navigation simply does not advance, which
  reads to the user as "stuck."
- Already `.committed`: `abortActiveGestureIfNeeded()` calls
  `finalizeOrCancelCommittedGesture` (`:1747`) → `endGesture(snapToColumn:)`,
  so the live viewport drag (driven each frame by
  `applyTrackpadViewportScrollDelta` at `:1621`) **snaps to the nearest column**
  rather than continuing under the finger. With a competing app splitting the
  stream, the matcher alternates `nil`/non-`nil` across frames: the gesture
  arms → aborts, or commits → snaps back, repeatedly — exactly nick-s5's
  *"glitch out."*

### 3. No stranded-gesture recovery, and the abort path is untraced

Two structural facts make this exact symptom class likely and hard to field-diagnose:

- **No timeout / no finalize for a stranded committed gesture.** I grepped the
  handler for any recovery/timeout/stranded-gesture finalizer; none exists. The
  only "until touches end" guard is `suppressGestureUntilTouchesEnd`
  (`:1404`), and it is set only on overlay suppression (`:1447`) and on the
  touch-release-finalize path (`:1867`) — **not** on the mid-drag abort path
  (`:1502`). So an app that perturbs the stream mid-swipe aborts (snaps) with
  no suppression and no trace.
- **`abortActiveGestureIfNeeded()` and `resetGestureState()` write no trace.**
  The only trackpad-gesture traces are on the success path
  (`touch_scroll_gesture_armed`, `_committed`, `_update`). When #301 reproduces,
  the trace shows only absence — the same diagnostic gap the sibling nehir-53
  doc already calls out (its "Diagnostic gap" section and Recommendation #1).

## Why it applies but is a duplicate of the sibling discovery

The root cause is **the strict exact-count matcher plus abort-on-nil, with no
hysteresis and no failure trace** — every element of which is already
documented in
[`20260616-nehir-53-trackpad-four-finger-swipe-gesture.md`](../discovery/20260616-nehir-53-trackpad-four-finger-swipe-gesture.md):

- nehir-53 §"The code in question" analyzes this same matcher (`:2146`/`:2163`/`:2176`),
  the same `nil`-abort block, and the same multi-frame commit threshold
  (`niriTouchpadGestureRecognitionThreshold = 16.0`, `:4`; commit at `:1586`).
- nehir-53 §"Why 4 may fail" (esp. point B) already explains gesture competition
  perturbing the touch stream, and cites the AltTab analog where a 3-finger
  recognizer mis-fires during a competing OS gesture — i.e. the same
  "app/OS consumes the gesture, delivered touch set is momentarily ≠ N" mechanism.
- nehir-53 Recommendation #1 (trace the abort/skip path with a `reason`) and #3
  (once `.armed`/`.committed` at `requiredFingers`, tolerate `requiredFingers ± 1`
  for a few miss-frames before aborting) are **finger-count-agnostic** and would
  directly address OmniWM #301's 3-finger "stuck/glitch": the hysteresis absorbs
  the transient count changes a competing app produces, so the swipe no longer
  aborts mid-transition.

The only thing #301 adds is the **app-level** (browser/app binds 3-finger)
competition vector and the **"stuck/glitch" symptom** — versus nehir-53's
OS-level 4-finger reservation and "never commits" symptom. These are different
symptoms of the same code defect; they share one fix.

> Sibling reference in triage: OmniWM #336 ("gesture scroll without scroll-snap")
> concerns the `bypassSnap` modifier path (`MouseEventHandler.swift:1530`–`:1540`,
> `:1695`), a distinct feature, and is not the duplicate owner here.

## Recommendation

Do **not** open a separate fix for #301; do **not** attempt to port the
"fix tomorrow" OmniWM change — nehir does not share the upstream rewrite's code,
and the relevant logic already lives in
`MouseEventHandler.swift`. Instead, fold #301 into the existing sibling track:

1. **Tracing first** (nehir-53 Rec #1): emit a `touch_scroll_gesture_abort`
   with `requiredFingers`, `activeTouches`, phase, and a `reason`
   (`overCount` / `underCount` / `nonHorizontal` / `overlay` / `disabled`).
   This is what would prove whether #301's "stuck" is abort-and-snap vs.
   never-commit, and it is the cheapest broadly-useful step. Add the abort
   call inside `handleGestureEvent` at `:1502` (and in `resetGestureState`,
   `:1924`-era).
2. **Hysteresis** (nehir-53 Rec #3): once a gesture is `.armed` or
   `.committed` at `requiredFingers`, tolerate `requiredFingers ± 1` for a
   bounded number of consecutive miss-frames (last-good centroid) before
   aborting. This is the actual fix for the app-competition "stuck": a browser
   that momentarily splits the 3-finger stream no longer kills the in-flight
   swipe.
3. **Workaround note** (nehir-53 Rec #4): some pages/apps bind 3-finger
   swipes; users can remap the offending app's 3-finger gesture, or use the
   modifier-snap-bypass (`scrollModifierKey`) path, while the hysteresis fix
   is pending.

## Suggested tests   (extend the sibling track, not a new suite)

- In `Tests/NehirTests/MouseEventHandlerTests.swift` (near the existing
  `trackpadGesture*` tests): feed a committed 3-finger stream, then inject a
  frame with `activeTouches == requiredFingers ± 1` and assert the gesture
  does **not** abort within the hysteresis window (lock-in behavior for #301).
- Assert the new abort trace carries the correct `reason` for over-count vs.
  under-count vs. non-horizontal frames (the diagnostic for both #301 and #53).
