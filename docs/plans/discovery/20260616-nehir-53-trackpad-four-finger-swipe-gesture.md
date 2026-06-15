# nehir issue #53 — "4 finger swipe gestures on built-in trackpad don't work in 0.5.0rc10" — Discovery

Source issue: <https://github.com/Guria/nehir/issues/53>
Originally reported (as a discussion comment) by `@axburgess-godaddy` in
<https://github.com/Guria/nehir/discussions/25#discussioncomment-17312660>,
filed as an issue by the maintainer.

Scope of this doc: determine **why** a 4-finger trackpad swipe fails to switch
columns in nehir, while 2- and 3-finger gestures work; confirm it is not a
config-parsing problem; and scope a fix. This is a discovery/analysis doc — no
code is changed here.

All file/line references were verified against `worktree-calm-meadow-6229`
at `b7ac7e5` ("Add more issues dicoveries"). Re-verify before implementing;
line numbers drift.

---

## TL;DR

- **The config is parsed correctly.** `fingerCount = 4` round-trips through
  the TOML decoder, `SettingsStore.gestureFingerCount`
  (`SettingsStore.swift:281`), and lands as `requiredFingers = 4` inside the
  gesture handler (`MouseEventHandler.swift:1459`). The reporter's config is
  valid; the problem is downstream of parsing. (Default is `.three`, so the
  reporter deliberately chose 4 — `SettingsExport.swift:147`.)
- **Root cause (code, deterministic): an exact-match finger-count gate.**
  `averageGestureTouchPosition(requiredFingers:touches:)`
  (`MouseEventHandler.swift:2146`) qualifies a frame only when the **currently
  active** (non-ended, non-cancelled) touch count equals `requiredFingers`
  *exactly*, and hard-bails as soon as the count exceeds it
  (`:2163` `if touchCount > requiredFingers { return nil }`; `:2176`
  `guard touchCount == requiredFingers, ... else { return nil }`).
- **Why 4 specifically:** a 4-finger multitouch stream on a large built-in
  trackpad is inherently noisy — transient palm/thumb contacts push the count
  to 5, and fingers lifting a frame early (or macOS's *own* recognition of a
  system 4-finger gesture) drop it to 3. Either deviation makes the matcher
  return `nil`. While the gesture is still in the `.armed` phase (before it
  has crossed the horizontal commit threshold), a single `nil` frame calls
  `abortActiveGestureIfNeeded()` (`:1491`–`:1509`), killing the gesture
  before it ever commits. 2- and 3-finger gestures work because fewer fingers
  mean far fewer incidental over-counts **and** 2–3 finger trackpad gestures
  are not system-reserved, so their streams stay clean.
- **Corroborating evidence (macOS behavior):** the equivalent bug in another
  macOS gesture-driven app, AltTab (`lwouis/alt-tab-macos#4278`), documents
  that its **3-finger** recognizer mis-fires *during* a 4-finger system swipe.
  That proves macOS still delivers 4-finger touch data to apps (the events are
  not swallowed) — the touch set is simply unstable mid-gesture, which is
  precisely what defeats nehir's exact matcher.
- **Secondary (environmental):** macOS reserves 4-finger gestures by default
  (System Settings → Trackpad → More Gestures: Mission Control / App Exposé /
  switching Spaces). Even with a perfect matcher, the OS would simultaneously
  fire its own action unless the user disables those.
- **Diagnostic gap:** `abortActiveGestureIfNeeded()` / `resetGestureState()`
  (`:1887`, `:1924`) emit **no** trace. The only gesture traces are on
  *success* (`touch_scroll_gesture_armed`, `touch_scroll_gesture_committed`).
  So today there is no in-app evidence of *why* a gesture failed — the
  arming trace simply never appears. Fixing this is independently worthwhile.

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
rejects 4.** The defect is in how `requiredFingers` is *enforced*, not how it
is *read*.

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
four active touches. For a noisy 4-finger stream that window is vanishingly
small, so the gesture almost always aborts at `:1502` before committing.

---

## Why 4 fails and 2/3 succeed

### A. Exact-match semantics are hostile to high finger counts

Every additional finger raises the probability that some frame's active count
is not exactly N:

- **Over-count (count → N+1):** a large built-in MacBook trackpad almost
  always has a resting palm/thumb within sensing range; a 4-finger swipe spans
  most of the pad and routinely surfaces a momentary 5th contact. The `:2163`
  bail rejects the frame.
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
swallowed) **and** the delivered touch set is momentarily indistinguishable
from a 3-finger gesture. For nehir, that exact "momentarily looks like 3
touches" condition is fatal: the strict-4 matcher returns `nil`, the `.armed`
gesture aborts, and the swipe never commits.

This is why the reporter observes "4-finger does nothing in nehir" while the
same trackpad works fine at 2/3 fingers.

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

Ranked by impact. (1) is the actual fix; (2) is a correctness cleanup that
enables (1); (3) is the diagnostic improvement; (4) is the immediate user
workaround / documentation.

### 1. Tolerate transient count deviations once a gesture is armed (primary fix)

Keep **exact** matching for *qualification* (so a 3-finger config and a
4-finger config don't both fire — the strictness is an intentional anti-cross-
talk measure, and the AltTab bug shows what happens without it), but add
*hysteresis* for *maintenance*: once a gesture is `.armed` or `.committed` at
`requiredFingers`, do not abort on a single frame whose active count is
`requiredFingers ± 1`. Concretely, in the `nil` branch at `:1491`:

- If `state.gesturePhase` is `.armed`/`.committed` and the active count is
  within `[requiredFingers - 1, requiredFingers + tolerance]` (tolerance ≥ 1,
  configurable or fixed), hold the gesture using the last good centroid
  (`state.gestureLastAverageX/Y`) instead of aborting; require **N consecutive**
  miss-frames before aborting.
- Reuse the existing commit threshold so a held-but-not-yet-committed gesture
  still must prove horizontal intent before it affects the viewport.

This directly absorbs the over-/under-count transients that the AltTab analog
proves occur, without loosening which gesture qualifies.

### 2. Remove the premature over-count bail at `:2163`

`if touchCount > requiredFingers { return nil }` is an optimization (early
exit) that is also the most common reason 4-finger frames die. Let the loop
complete and let the caller (with the hysteresis from (1)) decide based on the
actual active count. This is a small change but it must ship *with* (1) so the
strict qualification is still enforced by the caller rather than silently
dropped.

### 3. Trace the abort path

Emit a `touch_scroll_gesture_abort` (or reuse `gesture.skip` as already used
for overlay suppression at `:1444`) with `requiredFingers`, `activeTouches`,
phase, and a short `reason` (`overCount` / `underCount` / `noScrollContext` /
`overlay` / `disabled`). Cheap, broadly useful, and would have made #53
self-diagnosing. Add a regression test asserting the reason string for the
over-count and under-count cases alongside the existing gesture tests in
`Tests/NehirTests/MouseEventHandlerTests.swift` (e.g. near
`trackpadGestureStartsFromCurrentAnimationOffset`).

### 4. User-facing workaround / docs (immediate)

Until (1)–(2) ship, document that 4-finger mode requires disabling macOS's
default 4-finger system gestures, otherwise the OS competes and (per the
evidence above) destabilizes the delivered touch set: System Settings →
Trackpad → More Gestures → set **Mission Control**, **App Exposé**, and
**Switch Between Spaces** to 3-finger (or off). This does not fully fix the
strict-matcher abort on built-in trackpads (palm over-counts remain), but it
removes the OS-level competition and is the only thing the reporter can do
today.

---

## Reproduction / verification commands

Re-verify the matcher and abort behavior before any change:

```bash
# The strict matcher (the defect site)
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

The defining evidence: `averageGestureTouchPosition` returns `nil` unless the
active touch count equals `requiredFingers` *exactly*, and `:2163` bails on any
over-count; combined with the abort at `:1502` for an `.armed` gesture, a noisy
4-finger stream cannot survive the multi-frame commit window. As long as that
holds — and the AltTab analog confirms macOS does deliver noisy 4-finger data
to apps — 4-finger mode cannot commit on a built-in trackpad without
hysteresis.
