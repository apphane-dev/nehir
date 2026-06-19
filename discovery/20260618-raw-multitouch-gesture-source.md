# M5 — Raw MultitouchSupport gesture source — Investigation

Source upstream commit: [`06eb42d`](https://github.com/BarutSRB/OmniWM/commit/06eb42d) — "Fix stuck trackpad workspace gestures" (0.4.9.9 line, behind "Swipes used to occasionally get 'eaten' by the focused app").
Related: [`20260616-nehir-53-trackpad-four-finger-swipe-gesture.md`](20260616-nehir-53-trackpad-four-finger-swipe-gesture.md) (authoritative #53 source; maintainer non-repro).

Scope: **investigation, not a production change.** Evaluate whether a raw `MultitouchSupport`-based gesture source is worth prototyping, behind an internal flag, **without** replacing the production path. Produce a go/no-go decision.

---

## TL;DR

- **Upstream `06eb42d` is not vendored anywhere in the tree** (grep for `MTDeviceCreate`, `MTRegisterContactFrameCallback`, `Multitouch.framework` returns only this doc). Only its description is available; any prototype must be designed from documented intent, not ported line-for-line.
- **Nehir's production gesture path uses a CGEvent/NSEvent `.gesture` tap with `NSEvent.allTouches()` and exact-count matching.** #53 (4-finger swipe) could **not** be reproduced as globally broken; a 10.3 s trace shows clean exact-4 commits. The leading hypothesis is exact-count fragility on noisy streams, not input-source starvation.
- **Verdict:** 🟡 Investigate. Do **not** port raw multitouch as a blind #53 fix. Land the missing **abort/skip trace first** (independent hardening), then evaluate the raw source behind an internal diagnostic flag.
- **Distribution gating:** MultitouchSupport is a PrivateFramework. If nehir's distribution channel is (or may become) the App Store, this is a non-starter — confirm before building anything.

## Current architecture (verified)

1. **Tap install** — `MouseEventHandler.setup()` (`:227`). The **gesture tap** (`:285`) is `.cghidEventTap`, `.headInsertEventTap`, `.listenOnly`, mask `NSEvent.EventTypeMask.gesture` only (`:270`, `:289`). Re-armed on `.tapDisabledByTimeout`/`.tapDisabledByUserInput` (`:274`).
2. **Tap → snapshot** — `processGestureTapCallback` (`:2133`) → `makeGestureEventSnapshot(from:)` (`:2206`) materializes `NSEvent(cgEvent:)` then `nsEvent.allTouches()` (`:2198`). This is where MultitouchSupport would substitute.
3. **Dispatch** — `receiveTapGestureEvent(_:)` (`:550`) (also the test seam).
4. **Matcher** — `averageGestureTouchPosition(requiredFingers:touches:)` (`:2146`): bails on `touchCount > requiredFingers` (`:2163`), requires `touchCount == requiredFingers` exact equality (`:2176`).
5. **Abort/skip** — `abortActiveGestureIfNeeded()` (`:1887`) and `resetGestureState()` (`:1924`) **emit no trace.** Only `gesture.skip reason=unmanagedOverlay` (`:1444`) and success-path `touch_scroll_gesture_{armed,committed,update,end}` traces exist.

### Onboarding mirror (must stay in sync)

`Sources/Nehir/UI/Onboarding/InteractiveMoveDemo.swift:685` — `ThreeFingerGestureTapController` is a **near-duplicate** of the production gesture tap: same `CGEvent.tapCreate(.cghidEventTap, .headInsertEventTap, .listenOnly, .gesture)` (`:725`), same `NSEvent(cgEvent:).allTouches()` (`:759`), same exact-count filter (`activeTouches.count == 3`, `:763`). Its doc comment says it "Mirrors Nehir's real gesture input path for the onboarding demo." Any source change must decide whether the mirror follows.

### Lifecycle (matches one of upstream's motivations)

`ServiceLifecycleManager.stop` → `MouseEventHandler.cleanup()` (`:309`) **destroys** `state.gestureTap`. So the listener does **not** survive service stop. The wake observer (`ServiceLifecycleManager.setupSleepWakeObservation` `:309`) only calls `recordReconcileEvent(.systemWake)` + `requestRefresh(.unlock)` — it does **not** re-arm the gesture tap. If macOS disables the HID tap on sleep, nehir relies on the in-callback re-arm, which only fires if events are still flowing. This is a real gap independent of the raw-source question.

## Recommendation

### Step 1 — Add the missing abort/skip trace (do first, independent of M5)

In `handleGestureEvent` (`:1398`+) and `abortActiveGestureIfNeeded` (`:1887`), emit `traceMouseFocus("gesture.skip reason=<…> requiredFingers=<n> activeTouches=<m> phase=<p>")` with reason strings (`overCount`/`underCount`/`nonHorizontal`/`noScrollContext`/`overlay`/`disabled`/`emptyTouches`/`suppressed`), plus a `touch_scroll_gesture_abort` viewport trace when an `.armed` gesture dies. This is the "safest next fix" per the #53 doc and is a **hard prerequisite** for comparing sources on a failing stream. Land as a standalone hardening patch.

### Step 2 — Define a source abstraction (additive)

Introduce a `GestureEventSource` abstraction with `cgEventGestureTap` (current) and `rawMultitouch` (prototype) producers, both feeding `receiveTapGestureEvent(_:)`. No behavior change with the flag off; the existing test seam stays the only entrypoint `handleGestureEvent` sees.

### Step 3 — Prototype raw MultitouchSupport (flag-gated, diagnostic-only)

New `Sources/Nehir/Core/Controller/RawMultitouchGestureSource.swift`: `dlopen` the framework, enumerate devices via `MTDeviceGetDeviceIDs`, register a contact-frame callback via `MTRegisterContactFrameCallback`, translate `Finger` records into `GestureTouchSample` (mapping private phase flags to `NSTouch.Phase`), forward a `GestureEventSnapshot`. Hard requirements:

- All private symbols resolved via `dlopen`/`dlsym`; no build-time link. Fail closed on any missing symbol.
- Internal flags (`experimentalRawMultitouchGestureSource` + `…Actuate`), default false, **not** exported to `SettingsExport`/TOML/UI.
- Default **diagnostic-only**: emit `traceMouseFocus("gesture.rawMultitouch …")` but do **not** call `receiveTapGestureEvent` unless the separate actuate flag is on. Run both sources in parallel; never double-actuate (actuate mode suppresses the `.gesture` tap path or guards with a single-source selector).
- `start()`/`stop()` mirroring the service lifecycle; a `handleWake()` hook so step 4 can re-arm.

### Step 4 — Investigate the "survives stop/restart, sleep/wake" claim independently

Confirm whether the `.gesture` HID tap actually dies across sleep. If so, add `rearmGestureTapIfNeeded()` on `MouseEventHandler` called from the wake observer, idempotent with the existing in-callback re-arm. Capture as a **separate** hardening patch, not bundled into the raw-source decision.

### Step 5 — Capture runbook + go/no-go

Runbook: enable the diagnostic flag, start a runtime trace, perform 2/3/4-finger horizontal swipes plus a deliberate over-count case, collect paired `touch_scroll_gesture_*` and `gesture.rawMultitouch` records. Rubric (per finger count): does the raw source report stable exact-N where `.gesture` shows transient N±1; does it survive focused-app starvation / sleep-wake where `.gesture` does not; latency comparison.

## Explicit go / no-go criteria

**GO** (promote toward production, behind continued internal flag) — **all of:**
- Distribution channel tolerates private-framework use.
- Rubric shows raw source delivers stable exact-N on ≥1 machine where `.gesture` shows N±1, **or** survives focused-app starvation / sleep-wake where `.gesture` does not.
- No double-commit regression in actuate mode; fallback path verified; abort traces landed.

**NO-GO** (reject / keep diagnostic-only) — **any of:**
- Distribution channel prohibits private-framework use (App Store).
- Raw source shows the same transient count instability as `.gesture` (instability originates upstream of both, in macOS; raw solves nothing nehir-specific).
- ABI risk cannot be bounded to supported macOS versions in CI.
- A reporter-side **failing** trace arrives and shows the failure is not input-source-related (matcher exact-count, OS gesture competition) — fix belongs in the matcher/trace work, not the source.

**Default if inconclusive:** keep diagnostic-only; land Step 1 (abort trace) and Step 4 (sleep/wake re-arm) as standalone hardening; re-evaluate when a reporter-side failing trace is captured.

## Risks

- **Private-framework ABI drift** — the `Finger`/`MTContactPoint` struct layout has changed across macOS versions; wrong offsets yield garbage centroids or crashes. Pin a minimum OS, validate field offsets at runtime, fail closed on mismatch.
- **Notarization/distribution** — private-framework use is fine for direct distribution but is an App Store hard blocker. **Confirm before building.**
- **Duplicate commits / double actuation** running both sources in parallel — mitigate with diagnostic-only default and an exclusive actuate mode.
- **Onboarding drift** — if production moves to raw multitouch and the onboarding `ThreeFingerGestureTapController` is not updated, the demo stops mirroring the real path. Track as an explicit follow-up.
- **The raw source may not fix #53.** The maintainer non-repro shows the `.gesture` tap works for 4 fingers on at least one machine; if the reporter's failure is matcher/OS-competition-related, a source switch is the wrong fix.

## Non-goals

- Making the raw source the production default.
- Replacing the `.gesture` tap or `makeGestureEventSnapshot`.
- Touching the matcher's exact-count semantics (`:2146`) — count hysteresis is a separate, trace-gated decision (per the #53 doc).
- Exposing any user-facing setting.
- Porting upstream `06eb42d` code directly (not vendored; only described).
