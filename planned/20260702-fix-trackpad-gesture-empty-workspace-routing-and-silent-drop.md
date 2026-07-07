# Fix trackpad gesture empty-workspace routing and silent frame drop — Plan

Re-verified against main 7a025b78 on 2026-07-07.

**Status:** planned. Derived from
`discovery/20260702-trackpad-gesture-silent-noop-on-empty-workspace-under-cursor.md`,
which carries the full runtime evidence and source walk-through.

Validated against the main Nehir source tree on 2026-07-07 at commit `7a025b78`.

**Open product decision:** Phase 2 (fallback routing) implements the recommended
behavior — retarget an empty-workspace gesture at the interaction workspace. It was
recommended but not yet explicitly confirmed by the user. Phase 1 is unconditional
under any answer. If the decision comes back "keep strict cursor routing", ship
Phase 1 alone and move Phase 2 to `noop/` with that verdict.

---

## Problem

With two monitors, all windows on monitor A, and the cursor parked on monitor B whose
visible workspace is empty, three-finger scroll swipes are recognized, armed, and
committed — and then do nothing, invisibly. In the 2026-07-02 capture the user
retried **nine times over ~3.5 seconds** before moving the cursor to monitor A, where
the same swipe immediately worked. Two distinct defects compound:

1. **Routing never checks content.** The gesture targets the active workspace on the
   monitor under the cursor, even when that workspace has zero columns and the
   interaction workspace (where the user is actually working) is scrollable.
2. **The drop is untraced.** Every committed movement frame on the empty workspace is
   discarded with no trace record, so the capture shows a healthy-looking
   armed→committed→end cycle for a gesture that was 100% swallowed.

Representative evidence (workspace 6 = empty external-display workspace; trailing
always-`nil` fields trimmed; full records in the discovery doc):

```text
13:06:45Z workspace=6 reason=touch_scroll_gesture_armed … idleAdmissionKind=began activeTouches=3 columns=0 layout=no-columns
13:06:45Z workspace=6 reason=touch_scroll_gesture_committed … cumulativeX=-15.876 cumulativeY=-7.040 threshold=16.000 columns=0
13:06:45Z workspace=6 reason=touch_scroll_gesture_end … snap=true columns=0
```

9 armed / 9 committed / **0 update** records on the empty workspace; 111 update
records on workspace 1 once the cursor crossed displays.

---

## Source analysis (cites refreshed at `7a025b78`)

- `Sources/Nehir/Core/Controller/MouseEventHandler.swift:2289-2308` —
  `resolveScrollContext(at:)` picks `location.monitorApproximation(in:)` then
  `WorkspaceManager.activeWorkspaceOrFirst(on:)`
  (`Sources/Nehir/Core/Workspace/WorkspaceManager.swift:2445-2452`). No column check,
  no fallback.
- `MouseEventHandler.swift:1660-1717` (`.idle` arm) and `:1764-1806` (commit
  threshold) never consult workspace content.
- `MouseEventHandler.swift:1829-1877` — `applyTrackpadViewportScrollDelta` calls
  `vstate.beginGesture(isTrackpad:columns:)` at `:1860-1862`;
  `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:37` rejects empty
  columns (`guard !columns.isEmpty else { return false }`); the closure returns
  early, `didApply` stays `false`, and the update trace at `:1877-1879` is gated on
  `didApply` — the frame vanishes untraced.
- `MouseEventHandler.swift:1254` — the modifier+wheel column-scroll path uses the
  same `resolveScrollContext(at:)`, so wheel scrolling over an empty workspace no-ops
  identically. Any routing change made inside `resolveScrollContext` covers both
  inputs; keep them consistent.
- `Sources/Nehir/Core/Controller/WMController.swift:1114-1117` —
  `interactionWorkspace()` returns `activeWorkspaceOrFirst` on
  `monitorForInteraction()`; this is the natural fallback target (in the capture it
  was exactly the workspace the user went on to scroll manually).

---

## Fix strategy

### Phase 1 — close the observability holes (unconditional)

1. **Arm-time skip for unscrollable targets.** In the `.idle` branch, after
   `resolveScrollContext` (post-Phase-2: after fallback resolution), if the resolved
   workspace has no columns (`engine.columns(in: wsId).isEmpty`), do not arm. Emit
   `gesture.skip reason=emptyWorkspace` via the existing `traceGestureSkip` helper
   and return without `abortActiveGestureIfNeeded()` (nothing is active from idle —
   same reasoning as the `changedWithoutBegin` guard shipped in
   `completed/20260701-fix-trackpad-idle-changed-admission-and-contact-ramp.md`).
2. **Drop record for discarded committed frames.** In
   `applyTrackpadViewportScrollDelta`, when the closure completes with
   `didApply == false`, record a runtime viewport trace
   (`reason=touch_scroll_gesture_frame_dropped`, fields: `columns=<n>`,
   `delta=<…>`, whether `beginGesture` or `updateGesture` refused). After Phase 1's
   arm guard this should only fire in mid-gesture races (columns removed while
   committed), so it stays low-volume; if paranoid, latch it to once per gesture via
   a state flag. This guarantees committed frames can never vanish untraced again.

### Phase 2 — empty-workspace fallback routing (recommended; the product decision)

In `resolveScrollContext(at:)`: after resolving the cursor monitor's workspace, if
`engine.columns(in: wsId).isEmpty`, attempt fallback to the interaction context —
`controller.interactionWorkspace()` and its monitor (`monitorForInteraction()`) — and
use it **only if** that workspace has columns and differs from the cursor workspace.
Return the fallback pair `(engine, interactionWsId, interactionMonitor)` so the
locked gesture context carries the **fallback monitor id too** — viewport geometry
(`insetWorkingFrame`, `gapSize`, `backingScale`) must come from the monitor that owns
the target workspace, not the monitor under the cursor.

Diagnostics for the new path: when fallback engages, append to the armed record
`routedFrom=<cursor wsId>` and `routedReason=emptyWorkspaceFallback` so captures can
distinguish fallback gestures from direct ones.

Behavior matrix after both phases:

| Cursor workspace | Interaction workspace | Result |
| --- | --- | --- |
| has columns | — | unchanged: scroll under cursor |
| empty | has columns | gesture scrolls interaction workspace (`routedReason=emptyWorkspaceFallback`) |
| empty | empty or same | `gesture.skip reason=emptyWorkspace`, no arm |

The wheel path inherits the same fallback automatically because it resolves through
the same function; verify tick accumulation still keys off the resolved context and
note the shared behavior in the commit message.

### Phase 3 — validation capture, then regression tests

Per the main repo's AGENTS.md rule, **do not touch tests until the runtime fix is
confirmed by the user in a real capture** (the reproduction in "Validation" below).
After confirmation, add regression tests in
`Tests/NehirTests/MouseEventHandlerTests.swift` (gesture entry via
`handleGestureTapCallbackForTests`, `MouseEventHandler.swift:490`):

1. swipe over empty workspace with populated interaction workspace → locked context
   targets the interaction workspace/monitor; updates mutate its viewport;
2. swipe when both are empty → no arm, `emptyWorkspace` skip recorded;
3. swipe over populated cursor workspace → routing unchanged (no fallback fields);
4. modifier+wheel over empty workspace → column scroll acts on interaction workspace.

---

## Scope fences

- Do not change admission logic (`.began` guard, finger counting, over/under-count
  handling) — recently fixed and validated; this plan is downstream of admission.
- Do not change snap/release projection, scroll sensitivity, or wheel tick
  accumulation semantics.
- Do not introduce general "route gestures to focused monitor" behavior — fallback
  applies **only** when the cursor workspace has zero columns.
- No settings/UI surface in this pass; if the product decision later wants strict
  routing configurable, that is a separate plan.

---

## Validation

Reproduce the capture topology: two monitors, all windows on monitor A's workspace,
empty visible workspace on monitor B, cursor parked on monitor B. Capture a runtime
trace while swiping. The fix is validated when:

1. a three-finger swipe over the empty workspace produces
   `touch_scroll_gesture_update` records for monitor A's workspace with
   `routedReason=emptyWorkspaceFallback` on the armed record (Phase 2), and windows
   visibly scroll on monitor A;
2. with a fully empty session (or Phase 2 declined), the same swipe produces
   `gesture.skip reason=emptyWorkspace` instead of a bare armed→committed→end cycle;
3. no capture contains a committed cycle with zero updates and no drop/skip record —
   grep: every `touch_scroll_gesture_committed` is followed by an update, a
   `touch_scroll_gesture_frame_dropped`, or was preceded by an `emptyWorkspace` skip;
4. regression: swipes and modifier+wheel on populated workspaces behave exactly as
   before (no `routedFrom` fields present); single-monitor empty workspace still
   no-ops without crash.
