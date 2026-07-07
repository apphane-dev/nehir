# nehir issue #53 — "4 finger swipe gestures on built-in trackpad don't work in 0.5.0rc10" — Discovery

Groom 2026-07-07: superseded — the raw MultitouchSupport gesture source shipped on main (b92a1b04; see completed/20260620-m5-raw-multitouch-gesture-source.md); re-validate issue #53 against the new source before applying the exact-count hysteresis recommendation.

**Update 2026-06-20:** the input source under test has changed. The raw MultitouchSupport gesture source shipped on `main` in `b92a1b04` (see [`../completed/20260620-m5-raw-multitouch-gesture-source.md`](../completed/20260620-m5-raw-multitouch-gesture-source.md)), and the Step 1 `gesture.skip`/abort trace landed with it. The analysis below was written against the old `NSEvent.allTouches()` over `.gesture`-tap path; re-validate #53 against the raw source before deciding whether the exact-count hysteresis recommendation still applies.

Source issue: <https://github.com/Guria/nehir/issues/53>
Originally reported (as a discussion comment) by `@axburgess-godaddy` in
<https://github.com/Guria/nehir/discussions/25#discussioncomment-17312660>,
filed as an issue by the maintainer.

Scope of this doc: investigate a report that a 4-finger trackpad swipe fails to
switch columns in nehir while 2- and 3-finger gestures work; confirm whether it
is a config-parsing problem; and scope the next diagnostic/fix steps. This is a
discovery/analysis doc — no code is changed here.

All file/line references were verified against the Nehir source tree
at `b7ac7e5` ("Add more issues dicoveries"). Re-verify before implementing;
line numbers drift.

---

## TL;DR

- **New trace result: maintainer could not reproduce.** A 10.353s runtime
  capture on nehir `v17dafe` (2026-06-16 11:02:45–11:02:55Z) shows 4-finger
  gestures working: 7 `touch_scroll_gesture_armed`, 5
  `touch_scroll_gesture_committed`, 83 `touch_scroll_gesture_update`, 5
  `touch_scroll_gesture_end`, and 0 `touch_scroll_gesture_abort` records.
  The committed gestures all carry `requiredFingers=4 activeTouches=4` and
  switch columns in both directions. This disproves the earlier stronger claim
  that 4-finger mode cannot commit on a built-in trackpad.
- **The config is parsed correctly.** `fingerCount = 4` round-trips through
  the TOML decoder, `SettingsStore.gestureFingerCount`
  (`SettingsStore.swift:281`), and lands as `requiredFingers = 4` inside the
  gesture handler (`MouseEventHandler.swift:1459`). The reporter's config is
  valid; any failure is downstream of parsing. (Default is `.three`, so the
  reporter deliberately chose 4 — `SettingsExport.swift:147`.)
- **Exact-count matching is still the main code-level fragility, not yet a
  proven root cause for #53.** `averageGestureTouchPosition(requiredFingers:touches:)`
  (`MouseEventHandler.swift:2146`) accepts only frames whose active touch count
  equals `requiredFingers` exactly, with an early over-count bail at `:2163` and
  exact equality at `:2176`. The successful trace shows this works when macOS
  delivers a clean exact-four stream; it could still fail for a reporter whose
  stream intermittently reports 3 or 5 active touches.
- **Likely scope after non-repro:** the issue is environment- or input-stream
  dependent (macOS 4-finger gesture settings, trackpad model, hand posture,
  incidental contacts, or OS gesture competition), rather than a universal
  4-finger implementation defect.
- **Diagnostic gap remains the safest next fix.** `abortActiveGestureIfNeeded()`
  / `resetGestureState()` (`:1887`, `:1924`) emit no failure trace. The current
  non-repro trace is rich on the success path, but a reporter's failing trace
  would still show only absence unless abort/skip reasons are logged.

---

## 2026-06-16 maintainer non-reproduction trace

A 10.353s maintainer runtime capture on nehir `v17dafe` was recorded from
2026-06-16 11:02:45Z to 11:02:55Z. The relevant evidence is inlined below so
this document does not depend on any machine-local trace file.

Evidence from the trace:

- `touch_scroll_gesture_armed`: 7 records.
- `touch_scroll_gesture_committed`: 5 records.
- `touch_scroll_gesture_update`: 83 records.
- `touch_scroll_gesture_end`: 5 records.
- `touch_scroll_gesture_abort`: 0 records.
- Every commit event includes `requiredFingers=4 activeTouches=4`, e.g.
  `11:02:50Z cumulativeX=17.405 cumulativeY=0.084`,
  `11:02:51Z cumulativeX=-17.300 cumulativeY=1.406`,
  `11:02:53Z cumulativeX=16.331 cumulativeY=-2.398`, and
  `11:02:53Z cumulativeX=-17.199 cumulativeY=-3.307`.
- Gesture end records show actual column-navigation outcomes, including
  `previousActiveColumnIndex=1 endedActiveColumnIndex=0`,
  `0 → 1`, and `1 → 0` transitions.

Interpretation:

- nehir is receiving 4-finger trackpad gesture events on this machine.
- The strict `requiredFingers == activeTouches == 4` path can arm, commit,
  update, and end successfully.
- Therefore the earlier deterministic diagnosis should be narrowed: exact-count
  matching is a plausible failure mechanism for noisy streams, but not proof
  that 4-finger mode is globally broken.
- The next useful artifact is a **failing** trace from the reporter after abort
  reasons are logged, plus their macOS Trackpad → More Gestures settings.

---

## Provenance: is this nehir's own trackpad-gesture path?

Yes. The trackpad column-navigation gesture is implemented entirely in-tree:

```
Sources/Nehir/Core/Controller/MouseEventHandler.swift   <- event tap, handleGestureEvent, matcher
Sources/Nehir/Core/Config/GestureFingerCount.swift      <- 2/3/4 enum
Sources/Nehir/Core/Config/SettingsStore.swift           <- gestureFingerCount
Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift     <- TOML [gestures].fingerCount
Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift  <- viewport gesture math
```

The reporter is on a shipping nehir build (0.5.0rc10); this code is the only
column-swipe implementation, and it is gated solely on the configured finger
count. There is no second gesture path that could be "winning" the event.

---

## Config flow (verified end to end)

Reporter's config:

```toml
[gestures]
fingerCount = 4
invertDirection = true
mouseResizeModifierKey = "option"
scrollEnabled = true
scrollModifierKey = "optionShift"
scrollSensitivity = 2.5
```

Each key reaches the handler:

| TOML key        | Decoded at                            | Surfaces as                           | In handler          |
|-----------------|---------------------------------------|---------------------------------------|---------------------|
| `fingerCount`   | `CanonicalTOMLConfig.swift:429` (Int) | `gestureFingerCount = .four` (`SettingsStore.swift:281`) | `requiredFingers = 4` (`MouseEventHandler.swift:1459`) |
| `scrollEnabled` | `CanonicalTOMLConfig.swift:425` (Bool)| `scrollGestureEnabled`                | `guard ... scrollGestureEnabled` (`:1416`) passes |
| `invertDirection` | `CanonicalTOMLConfig.swift:430`     | `gestureInvertDirection`              | `if invertDirection { deltaUnits = -deltaUnits }` (`:1607`) |
| `scrollSensitivity` | `CanonicalTOMLConfig.swift:426`   | `scrollSensitivity`                   | `rawDeltaX * scrollSensitivity` (`:1606`) |

The `.four` case exists and is valid (`GestureFingerCount.swift:4` →
`case four = 4`). `GestureFingerCount(rawValue: 4) ?? .three`
(`SettingsStore.swift:527`) succeeds without falling back. **Nothing here
rejects 4.** If the reporter-side failure reproduces, it is downstream of how
`requiredFingers` is *used/enforced*, not how it is *read*.

---

## The code in question

### 1. Touch source: `NSEvent.allTouches()` over an HID-level gesture tap

The gesture tap is installed at the HID level, listen-only, for
`NSEvent.EventTypeMask.gesture` only (`MouseEventHandler.swift:286`–`:289`):

```swift
state.gestureTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: gestureMask,          // == .gesture only
    callback: gestureCallback,
    userInfo: nil
)
```

Each `.gesture` event is materialized into a snapshot whose `touches` array
comes straight from `NSEvent.allTouches()` (`:2195`–`:2203`):

```swift
private nonisolated static func makeGestureEventSnapshot(from cgEvent: CGEvent) -> GestureEventSnapshot? {
    guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
    return GestureEventSnapshot(
        ...
        touches: nsEvent.allTouches().map { touch in
            GestureTouchSample(
                phase: touch.phase,
                normalizedPosition: sanitizedGestureTouchPosition(touch.normalizedPosition)
            )
        }
    )
}
```

So `touches` is **every** contact the trackpad reports for that gesture frame,
including incidental palm/thumb contacts that macOS surfaces at the HID level.
This is the raw, unfiltered multitouch set.

### 2. The matcher: strict exact-count equality

`averageGestureTouchPosition(requiredFingers:touches:)` (`:2146`) is the sole
gate that decides whether a frame "is" the configured gesture:

```swift
static func averageGestureTouchPosition(
    requiredFingers: Int,
    touches: [GestureTouchSample]
) -> CGPoint? {
    guard requiredFingers > 0 else { return nil }

    var sumX: CGFloat = 0
    var sumY: CGFloat = 0
    var touchCount = 0
    var activeCount = 0

    for touch in touches {
        if touch.phase == .ended || touch.phase == .cancelled {
            continue
        }

        touchCount += 1
        if touchCount > requiredFingers {        // :2163  hard bail on OVER-count
            return nil
        }

        guard let normalizedPosition = touch.normalizedPosition else {
            return nil
        }

        sumX += normalizedPosition.x
        sumY += normalizedPosition.y
        activeCount += 1
    }

    guard touchCount == requiredFingers, activeCount > 0 else { return nil }   // :2176  exact equality
    ...
}
```

Two constraints make this fragile:

- **`:2163`** — as soon as the active count exceeds `requiredFingers`, return
  `nil` immediately. One transient palm contact at any point → frame rejected.
- **`:2176`** — the frame is accepted **only** if the active count equals
  `requiredFingers` *exactly*. A dip to `requiredFingers - 1` (a finger lifting
  one frame early) → frame rejected.

### 3. What a rejected frame does to an in-progress gesture

`handleGestureEvent` calls the matcher and, on `nil`, aborts unless the gesture
is already committed and touches are lifting (`:1491`–`:1509`):

```swift
guard let averageTouchPosition = Self.averageGestureTouchPosition(
    requiredFingers: requiredFingers,
    touches: snapshot.touches
) else {
    if state.gesturePhase == .committed, activeTouchCount < requiredFingers {
        finalizeCommittedGestureAfterTouchRelease(engine: engine, timestamp: snapshot.timestamp)
        return
    }
    abortActiveGestureIfNeeded()      // <- .armed (or .idle) gesture dies here
    return
}
```

The commit path itself requires more than one good frame: after arming at
exactly N touches, the gesture must accumulate horizontal travel beyond a
threshold before it is promoted `.armed → .committed` (`:1566`–`:1583`):

```swift
let cumulativeX = (avgX - state.gestureStartX) * macNormalizedTouchPositionToNiriGestureUnits   // ×500
...
let distanceSquared = cumulativeX * cumulativeX + cumulativeY * cumulativeY
let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold  // 16.0²
guard distanceSquared >= thresholdSquared else { ... return }     // not yet committed
guard abs(cumulativeX) > abs(cumulativeY) else { resetGestureState(); return }   // must be horizontal
```

(`niriTouchpadGestureRecognitionThreshold = 16.0` and
`macNormalizedTouchPositionToNiriGestureUnits = 500.0`, both file-private at
the top of `MouseEventHandler.swift:4` / `:8`.)

**The consequence:** to commit a 4-finger swipe, the matcher must return a
non-`nil` centroid on **every** frame across the several frames needed to cross
the horizontal threshold — and every one of those frames must report *exactly*
four active touches. The maintainer trace shows this can happen successfully;
for a noisy reporter-side stream, however, this window may be too small, so the
gesture can abort at `:1502` before committing.

---

## Why 4 may fail for the reporter while it works in the maintainer trace

### A. Exact-match semantics are hostile to high finger counts

Every additional finger raises the probability that some frame's active count
is not exactly N:

- **Over-count (count → N+1):** a large built-in MacBook trackpad can have a
  resting palm/thumb within sensing range; a 4-finger swipe spans much of the
  pad and may surface a momentary 5th contact. The `:2163` bail rejects the
  frame.
- **Under-count (count → N−1):** fingers rarely land and lift in perfect
  lockstep. One finger leaving a frame early drops the count to 3; the `:2176`
  guard rejects the frame.

For 2- and 3-finger gestures the same logic is far more forgiving: fewer
fingers means a much smaller chance of an incidental contact, and 2/3-finger
trackpad gestures are not claimed by macOS, so the stream is clean.

### B. macOS reserves 4-finger gestures by default (and perturbs the stream)

By default, System Settings → Trackpad → More Gestures maps 4-finger swipes to
Mission Control / App Exposé / switching Spaces (and 4-finger pinch to
Launchpad / Show Desktop). This has two effects:

1. **Competition:** even if nehir's matcher were perfect, the OS would
   simultaneously trigger its own action.
2. **Stream perturbation:** when macOS recognizes a system 4-finger gesture,
   the touch set it delivers to apps is unstable mid-gesture.

Point 2 is not speculation — it is documented by the direct analog in another
macOS app. AltTab (`lwouis/alt-tab-macos#4278`) reports that its **3-finger**
horizontal-swipe recognizer *mis-fires during a 4-finger system swipe* used to
switch Spaces. That is only possible if macOS is still delivering 4-finger
touch data to apps (so nehir's tap is receiving events — they are not
swallowed) **and** the delivered touch set can be momentarily indistinguishable
from a 3-finger gesture. For nehir, that exact "momentarily looks like 3
touches" condition would be fatal before commit: the strict-4 matcher returns
`nil`, the `.armed` gesture aborts, and the swipe does not commit.

This remains a plausible explanation for the reporter's "4-finger does nothing"
observation, but the maintainer trace above proves it is not universal: a clean
exact-four stream can commit and switch columns successfully.

---

## Diagnostic gap (independent finding)

`abortActiveGestureIfNeeded()` (`:1887`) and `resetGestureState()` (`:1924`)
write **no** trace. The only trackpad-gesture traces are emitted on the success
path (`touch_scroll_gesture_armed`, `touch_scroll_gesture_committed`, and
`touch_scroll_gesture_update`), all of which carry
`requiredFingers`/`activeTouches`.

Therefore, when this bug reproduces, the runtime trace simply shows an absence
of any `touch_scroll_gesture_armed` event — there is no record of *why* the
gesture was rejected (over-count? under-count? overlay suppression? matcher
nil?). This makes field triage of exactly this class of report guesswork.
Adding a one-line trace on the abort path is cheap and broadly useful; it is
called out separately because it is not required to fix #53 but would have
made #53 self-evident.

---

## Recommendation

Ranked by confidence after the non-reproduction trace. The successful 4-finger
trace means we should avoid landing a behavior-changing hysteresis fix as "the"
fix until we have a failing trace that shows the failure mode.

### 1. Trace the abort / skip path first (highest confidence)

Emit a `touch_scroll_gesture_abort` (or reuse `gesture.skip` as already used
for overlay suppression at `:1444`) with `requiredFingers`, `activeTouches`,
phase, and a short `reason` (`overCount` / `underCount` / `noScrollContext` /
`overlay` / `disabled` / `nonHorizontal`). Cheap, broadly useful, and now the
best next step because the maintainer trace only proves the success path.

Add regression tests asserting the reason string for over-count and under-count
cases alongside the existing gesture tests in
`Tests/NehirTests/MouseEventHandlerTests.swift` (e.g. near
`trackpadGestureStartsFromCurrentAnimationOffset`).

### 2. Ask for a reporter-side failing trace

After (1), ask the reporter to capture a trace while attempting the failing
4-finger gesture and include macOS Trackpad → More Gestures settings. A useful
trace should answer:

- Are any `.gesture` events reaching nehir?
- Does `activeTouches` ever reach 4?
- Is the failure an over-count, under-count, vertical/non-horizontal reset,
  overlay/no-scroll-context skip, or OS gesture competition?
- Does the reporter's stream ever commit and then snap back, or does it never
  arm/commit?

### 3. Consider hysteresis only if the failing trace shows count instability

If the failing trace shows an armed gesture aborting on transient 3/5-touch
frames, then keep **exact** matching for initial qualification, but add
*hysteresis* for maintenance: once a gesture is `.armed` or `.committed` at
`requiredFingers`, tolerate `requiredFingers ± 1` for a small number of
consecutive miss-frames, using the last good centroid, before aborting.

This would preserve the anti-cross-talk property while absorbing noisy streams,
but the current maintainer trace does not prove it is necessary.

### 4. User-facing workaround / docs (immediate)

Document that 4-finger mode can conflict with macOS's default 4-finger system
gestures: System Settings → Trackpad → More Gestures → set **Mission Control**,
**App Exposé**, and **Switch Between Spaces** to 3-finger (or off). This is no
longer presented as a guaranteed fix, but it is a low-risk workaround to remove
OS-level competition while collecting better diagnostics.

---

## Reproduction / verification commands

Re-verify the matcher and abort behavior before any change:

```bash
# The strict matcher (the potential fragility site)
rg -n 'func averageGestureTouchPosition|requiredFingers|touchCount > requiredFingers|touchCount == requiredFingers' \
   Sources/Nehir/Core/Controller/MouseEventHandler.swift

# How a nil matcher result aborts an armed gesture
rg -n 'averageGestureTouchPosition|abortActiveGestureIfNeeded|finalizeCommittedGestureAfterTouchRelease' \
   Sources/Nehir/Core/Controller/MouseEventHandler.swift

# Confirm the commit threshold a 4-finger gesture must survive for several frames
rg -n 'niriTouchpadGestureRecognitionThreshold|macNormalizedTouchPositionToNiriGestureUnits' \
   Sources/Nehir/Core/Controller/MouseEventHandler.swift

# Confirm 4 is a valid, fully-wired config value (not a parsing problem)
rg -n 'case four|gestureFingerCount|fingerCount' \
   Sources/Nehir/Core/Config/GestureFingerCount.swift Sources/Nehir/Core/Config/SettingsStore.swift Sources/Nehir/Core/Config/CanonicalTOMLConfig.swift

# Existing gesture tests to extend for the over/under-count regression
rg -n 'trackpadGesture' Tests/NehirTests/MouseEventHandlerTests.swift
```

The defining code evidence remains that `averageGestureTouchPosition` returns
`nil` unless the active touch count equals `requiredFingers` *exactly*, and
`:2163` bails on any over-count. The new runtime evidence shows that this path
can still commit when the stream stays exactly four touches. Treat exact-count
fragility as a hypothesis to verify with a failing trace, not as a closed root
cause.
