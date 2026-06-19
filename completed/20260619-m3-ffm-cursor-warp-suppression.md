# M3 (narrow) — Suppress cursor warp on focus-follows-mouse confirmations

**Status:** completed — shipped on `main` in `51f86e84` ("Suppress cursor warp for FFM AX confirmations")
**Source discovery:** `discovery/20260618-focus-request-origin-ffm-cursor-warp.md`
**Upstream commit:** `fce3a2c` — "Fix cursor warp for focus follows mouse"

## Completion evidence

`origin/main` contains `51f86e84` with the plan's intended source change: `AXEventHandler.handleManagedAppActivation` hoists the existing `isFFM` signal into a `confirmationIsFFM` flag and adds `&& !confirmationIsFFM` to the cursor-warp gate. The `ConfirmationLoop`/origin model was correctly left out (deferred to A4/M6).

Test landed: `AXEventHandlerTests.ffmFocusConfirmationDoesNotWarpCursorWhenMoveMouseToFocusedWindowEnabled` (negative case — FFM confirmation does not warp). The positive non-FFM-warp case is covered by existing `AXEventHandlerTests` confirm coverage rather than a new explicit test. `swift test --filter AXEventHandlerTests` is green (163 tests).

## TL;DR

With **Move mouse to focused window** enabled, a focus-follows-mouse (hover)
confirmation warps the cursor to the focused window — the annoyance upstream
fixed in #147. Nehir **already computes an `isFFM` signal** at the focus-confirm
site (`AXEventHandler.handleManagedAppActivation`) that means exactly "this
confirmation is FFM-driven." The minimal fix is to gate the warp on `!isFFM`.

This is a **narrow bug fix**, not the discovery doc's full `ManagedFocusOrigin`
model. The origin-model groundwork (for hiro-317 / A4 / M6) is **deferred** — it
is separable from the warp bug. M6, when it lands, will introduce
`ManagedFocusOrigin` itself; its "depends on M3" edge becomes "depends on this
warp fix landing first" only loosely.

## Scope

- `Sources/Nehir/Core/Controller/AXEventHandler.swift` — `handleManagedAppActivation`:
  hoist the existing `isFFM` computation out to the gate; add one condition.
- `Tests/NehirTests/AXEventHandlerTests.swift` — focused warp tests.

### Non-goals

- Do **not** add a `ManagedFocusOrigin` enum / field to `ManagedFocusRequest`
  (that is A4/M6 groundwork).
- Do **not** change `WMController.focusWindow` signature or any of its ~30 call
  sites.
- Do **not** touch `shouldSuppressMouseMoveToFocusedWindow` (token-based
  backstop for other suppression cases) — the FFM gate is **additive**.
- Do **not** reintroduce Dwindle (upstream `fce3a2c` touches `DwindleLayoutHandler`,
  absent from nehir).

## The fix

`isFFM` is computed inside the `if let engine = controller.niriEngine, let node = …`
block (~`AXEventHandler.swift:2204`) and consumed there for viewport reveal /
relayout decisions. The warp gate sits just **after** that block closes
(~`:2362`), so `isFFM` is not yet in scope at the gate.

1. Declare `var confirmationIsFFM = false` immediately **before** the
   `if let engine = …` block.
2. Inside that block, after `isFFM` is computed, set
   `confirmationIsFFM = isFFM`.
3. At the warp gate, add `&& !confirmationIsFFM`:

```swift
if shouldConfirmRequest,
   controller.moveMouseToFocusedWindowEnabled,
   controller.workspaceManager.confirmedManagedFocusToken == entry.token,
   !controller.workspaceManager.isNonManagedFocusActive,
   !controller.shouldSuppressMouseMoveToFocusedWindow(for: entry.token),
   !confirmationIsFFM   // M3: FFM/hover confirmations must not warp the cursor
{
    controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame, reason: "axFocusConfirmed")
}
```

The no-engine `else` branch leaves `confirmationIsFFM = false` (preserves current
behavior where there is no niri viewport/FFM tracking). Safe default.

## Tests

Add to `Tests/NehirTests/AXEventHandlerTests.swift`, mirroring the existing
`handleAppActivation` confirm harness (e.g. the test near `:1600`):

- `moveMouseToFocusedWindowEnabled` set to `true`.
- Injectable `controller.warpMouseCursorPosition = { captured = $0 }`
  (`WMController.swift:190`).
- Track a managed window, set managed focus, provide `focusedWindowRefProvider`
  returning the target.

1. `ffmFocusConfirmationDoesNotWarpCursorWhenEnabled` — preload the viewport
   state's `pendingFFMFocusToken`/`pendingFFMFocusTimestamp` for the target (via
   `applySessionPatch`), drive `handleAppActivation`; assert
   `warpMouseCursorPosition` was **not** invoked.
2. `nonFFMFocusConfirmationWarpsCursorWhenEnabled` — same setup, no FFM marker;
   assert warp **was** invoked.

Existing FFM coverage (`MouseEventHandlerTests` `focusFollowsMouse…`, 10+ tests)
exercises the `isFFM` path heavily and must stay green.

## Validation

```bash
swift build
swift test --filter AXEventHandlerTests
swift test --filter MouseEventHandlerTests
swift test --filter OptimizationCompletionTests
```

Changeset (patch): "Focus-follows-mouse activations no longer warp the cursor to
the focused window when 'Move mouse to focused window' is enabled."

## Risks

- **No-engine path** keeps warp enabled (no FFM tracking there) — intended,
  matches current behavior.
- **FFM marker timing** — `isFFM` requires the marker fresh within 1.0 s; if the
  marker has already been consumed/stale by confirm time the confirmation is
  treated as non-FFM and warps. The existing
  `shouldSuppressMouseMoveToFocusedWindow` token-based backstop still covers
  related suppression cases.
- This fixes the **warp symptom** only; the rapid-focus revert race (hiro-317)
  remains (separate A4 work).

## Deferred (out of scope here)

The `ManagedFocusOrigin` enum + `ManagedFocusRequest.origin` field + threading
through `FocusBridgeCoordinator.beginManagedRequest` / `WMController.focusWindow`.
That model is the groundwork A4 (hiro-317 grace window) and M6 (revision guard)
will build on; it is not required to fix the warp bug because the `isFFM` signal
already exists at the confirm site.
