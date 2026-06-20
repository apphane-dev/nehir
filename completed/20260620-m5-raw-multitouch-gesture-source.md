# M5 — Raw MultitouchSupport gesture source

**Status:** completed — shipped on `main` in `b92a1b04` ("Implement raw multitouch input for trackpad gestures")
**Source discovery:** [`discovery/20260618-raw-multitouch-gesture-source.md`](../discovery/20260618-raw-multitouch-gesture-source.md)
**Upstream commit:** [`06eb42d`](https://github.com/BarutSRB/OmniWM/commit/06eb42d) — "Fix stuck trackpad workspace gestures"
**Related issue:** [#53](https://github.com/Guria/nehir/issues/53) — see [`discovery/20260616-nehir-53-trackpad-four-finger-swipe-gesture.md`](../discovery/20260616-nehir-53-trackpad-four-finger-swipe-gesture.md)

## Completion evidence

`origin/main` contains `b92a1b04`. The investigation's GO decision was made and
the prototype was promoted straight to the **production** trackpad-gesture source
rather than the diagnostic-only default the discovery recommended.

What landed (all source references are repo-relative; re-verify before editing,
line numbers drift):

- `Sources/Nehir/Core/Multitouch/MultitouchBinding.swift` — `dlopen`s
  `/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport`
  and resolves `MTDeviceCreateList`, `MTDeviceStart`, `MTDeviceStop`, and
  `MTRegisterContactFrameCallback` via `dlsym`, failing closed on any missing
  symbol. This is exactly the private-symbol binding prescribed in discovery
  Step 3.
- `Sources/Nehir/Core/Multitouch/MultitouchGestureSource.swift` — translates the
  contact-frame callbacks into the existing gesture path (the Step 3 producer).
- `Sources/Nehir/Core/Controller/MouseEventHandler.swift` — consumes raw
  multitouch data for gesture recognition and preserves the unsnapped viewport
  offset across snap-bypassed (modifier-held) gestures.
- **Discovery Step 1 hardening landed in the same commit:** a
  `gesture.skip reason=<…>` mouse-trace record at every trackpad-gesture
  skip/abort site (`MouseEventHandler.swift:792`/`:806`), plus a
  `reason=touch_scroll_gesture_abort` viewport trace. This also satisfies the
  #53 discovery's first recommendation.
- `.changeset/20260619203917-use-raw-multitouch-input-for-trackpad-workspace-.md`
  frames the switch as the upstream-`06eb42d` / #53 motivation: "swipes are no
  longer eaten by the focused app."

Tests landed in `Tests/NehirTests/MouseEventHandlerTests.swift` under
"MARK: - M5 step 1: gesture skip/abort trace capture":

- `gestureSkipTraceRecordsOverCountReason` — over-count frame emits
  `gesture.skip reason=overCount`.
- `gestureAbortTraceRecordsArmedAbortReason` — an armed gesture dying on a
  non-horizontal frame emits `gesture.skip reason=nonHorizontal` and a
  `reason=touch_scroll_gesture_abort` viewport trace.

## Deviation from the recommendation (accepted)

The discovery proposed shipping raw multitouch **diagnostic-only** behind an
internal flag, running both sources in parallel, and warned explicitly that "the
raw source may not fix #53." The maintainer chose to make it the production
source directly. The distribution-gating caveat (private-framework use is an App
Store hard blocker) is now load-bearing for whatever channel ships this build.

## Follow-ups still open (out of scope here)

- Re-validate open issue **#53** against the new raw source. The #53 discovery's
  core loop (collect a reporter-side failing trace, then decide on matcher
  exact-count hysteresis) is unchanged in principle but now applies to the raw
  stream rather than `NSEvent.allTouches()` over the `.gesture` tap.
- Onboarding mirror: confirm whether
  `Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift`'s
  `ThreeFingerGestureTapController` still mirrors the real input path, or has
  now drifted (the discovery called this out as an explicit follow-up if
  production moved to raw multitouch).
- Sleep/wake re-arm of the gesture source (discovery Step 4) — verify whether
  the raw contact-frame path survives sleep/wake any better than the old HID
  tap, and add `rearmGestureTapIfNeeded()` if not.
