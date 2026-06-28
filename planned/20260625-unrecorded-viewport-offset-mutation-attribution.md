# Unrecorded viewport offset mutation — attribution & fix — Plan

Picks up and promotes `discovery/20260625-precommitted-viewport-shifts-before-trackpad-gesture.md`.
That discovery proved the viewport was already shifted *before* a trackpad gesture
committed, and showed the shifted value was already in `ViewportState` before any
user scroll delta was applied. It stopped short of naming the mutation site because
the capture had no record for the move itself. This plan adds a second capture that
narrows the repro to the **focus-reveal / column-transition / window-arrival** path,
and confirms in source that every mutation on that path writes the viewport offset
with **no trace record and no provenance**.

All source references were verified against the main Nehir source tree at `f4adb75f`
on 2026-06-25 (`git log -1 --format='%h %s'` → `f4adb75f Add shift+click, preview pills,
and workspace bar settings improvements`). The discovery was validated at `8887adcb`,
which is an ancestor of `f4adb75f`. Line numbers will drift; function names are
included so the code stays findable.

---

## Status (updated 2026-06-28)

Phases 1 and 2 have landed; Phase 3's fix site is now source-attributed and ready.

- **Phase 1 — centralized audit + provenance: done.** `ViewportState.withRecordedViewportMutation`
  and the `lastViewportMutation*` fields are in tree (earlier commits on this branch).
  Every direct `viewOffsetPixels` write routes through it.
- **Phase 2 — make unrecorded mutations attributable: done.** An observer in
  `WorkspaceManager.updateNiriViewportState` (the single live-write chokepoint)
  emits `reason=relayout.viewportOffsetChanged` whenever the committed offset
  target moves beyond a half-pixel, carrying the `lastViewportMutation*` caller.
  This catches relayout rebases, removal shifts, focus-activation reveals, and
  restores that previously vanished. (An initial `!isAnimating` gate clause was
  removed because it suppressed the focus-activation spring-retarget case.)
- **Phase 3 — behavioral fix: site confirmed, ready to implement.** The
  "viewport moves with no trackpad input" repros are confirmed by a live hook
  capture to the relayout path's selection reconciliation (`resolveSelection` →
  `ensureSelectionVisible` → `scrollToReveal` → `animateToOffset`), which
  snap-recenters a fully-visible, unchanged-selection viewport. `dad2e63a` already
  suppressed this recenter on the focus-confirmation path (`revealForFocusActivation`
  no-ops when fully visible) but not on the relayout path. The trigger is any
  settled-viewport relayout — typing (transient surfaces) or display topology change
  — and a confirmed repro proves the recentered value is not a geometry correction
  (display frame and column layout unchanged). The fix extends the
  `dad2e63a` rule into relayout-driven reconciliation. See
  `discovery/20260628-relayout-path-recenters-fully-visible-unchanged-selection.md`
  for the three inlined repros and exact call sites. No additional trace capture is
  required to implement the fix.
- **Residual attribution gap (separate follow-up, not blocking Phase 3):** when a
  single relayout pass applies multiple offset mutations to the planning copy, the
  single-slot audit collapses the intermediate step. See
  `discovery/20260628-relayout-commit-collapses-intermediate-viewport-mutations.md`.

---

## TL;DR

- **Symptom.** Between a settled `scroll_animation_stop` and the next user-driven
  interaction (`touch_scroll_gesture_armed`, or a focus-triggered
  `scroll_animation_start`), the viewport `currentViewStart` is at a value that the
  previous `scroll_animation_stop` never produced. The shift is visible to the user
  as a viewport slide/jump they did not initiate with the trackpad.
- **Root cause (class).** Several viewport mutation entry points write
  `viewOffsetPixels` directly — `ViewportOffset.offset(delta:)`, the column-transition
  helpers, the window-arrival path — without emitting a runtime trace record and
  without recording any "last mutation" provenance. Animations that run *after* these
  writes (`scroll_animation_start`) are correctly traced, but they animate *from* the
  silently-shifted offset, so the trace shows an animation starting at an offset that
  has no recorded origin.
- **Why existing traces can't see it.** `WMController.recordRuntimeViewportTrace`
  (`Sources/Nehir/Core/Controller/WMController.swift:2578`) only snapshots viewport
  state at call sites that already trace (gesture, animation, focus-confirm). There is
  no centralized mutation hook, and `ViewportState` carries no
  `lastViewportMutationReason`. The grep for `recordViewportMutation` /
  `lastViewportMutationReason` / `viewportMutationReason` across `Sources/Nehir`
  returns zero matches — the instrumentation the discovery recommended was never added.
- **Fix direction.** (1) Add one centralized viewport-mutation audit entry point plus
  `lastViewportMutation*` provenance on `ViewportState`, and route every offset write
  through it. (2) Capture repros and attribute the exact site. (3) Fix the stale-offset
  read that lets a transition/arrival compound an offset a prior pass left un-settled,
  with regression tests.

---

## Runtime evidence to preserve

Evidence is inlined from two captures on 2026-06-25 (display `ID(displayId: 1)`,
workspace `58C54F3B-7995-4A9D-9F2E-436B0E3C5006`). No trace files are referenced; the
values below are quoted from the captured records.

### Manifestation A — pre-gesture drift (from the discovery)

Settled state, `gesture=false animating=false`:

```text
reason=scroll_animation_stop activeColumnIndex=0 currentOffset=-8.0 currentViewStart=-8.0 targetViewStart=-8.0
```

Next viewport-bearing record for the same workspace:

```text
reason=touch_scroll_gesture_armed currentOffset=-58.8 currentViewStart=-58.8 targetViewStart=-58.8 gesture=false animating=true
```

The viewport moved `-8.0 → -58.8` (−50.8 pt) with no record in between, and the armed
record already shows `animating=true`. The first accepted scroll delta after this was
`delta=36.936`, proving `-58.8` pre-existed any user scroll input. (Full details and a
second `-8.0`-style shift at `1211.2 → ~1566.8` are in the discovery.)

### Manifestation B — focus-reveal + column transition (new)

Settled state after the previous fling settled, `gesture=false animating=false`:

```text
reason=scroll_animation_stop activeColumnIndex=1 currentOffset=-516.0 currentViewStart=500.0 targetViewStart=500.0
selectedNode=DE38E555-045D-49D8-994B-DBD4FC6E22C9 confirmedFocus=WindowToken(pid: 87556, windowId: 23711)
```

First viewport-bearing record after a ~4-minute idle gap, when focus confirmed a
different window on the same workspace (`WindowToken(pid: 1618, windowId: 24677)`):

```text
reason=scroll_animation_start activeColumnIndex=2 currentOffset=-1374.9 currentViewStart=616.0 targetViewStart=1008.0 gesture=false animating=true
selectedNode=E003D34A-F28C-48BF-AF8C-31619CC39A10 confirmedFocus=WindowToken(pid: 1618, windowId: 24677)
```

Two things changed with **no intervening record**: `activeColumnIndex 1 → 2`, and
`currentOffset -516.0 → -1374.9` (`currentViewStart 500.0 → 616.0`). The subsequent
focus-confirm records then run while that animation plays toward `1008.0`:

```text
reason=ax_focus_confirm_before_activate currentViewStart=730.7 ...
reason=ax_focus_confirm_reveal_skipped   preserveActiveViewport=true ...
reason=ax_focus_confirm_request_relayout ...
reason=scroll_animation_stop currentViewStart=1008.0 gesture=false animating=false
```

Note `ax_focus_confirm_reveal_skipped` with `preserveActiveViewport=true`: the reveal
itself was skipped, yet the `616.0 → 1008.0` animation was already running before the
focus-confirm records. So the mutation is **not** `scrollToReveal`; it is whatever set
the active column to 2 and based the animation at `616.0` immediately before. A second
instance of the same pattern fires shortly after: animation `currentViewStart=1136.3 →
targetViewStart=1834.0` where the prior settled value was `1008.0` (+128.3 pt
unaccounted).

### What is *not* the bug

In the afternoon capture, every `touch_scroll_gesture_armed` whose `currentViewStart`
differed from the prior `scroll_animation_stop` fell into one of two explained
classes: (a) it matched the last stop exactly, or (b) it was `gesture=false
animating=true` with `currentViewStart != targetViewStart` — i.e. a new gesture
interrupting a still-running snap. Those are not the bug. The bug is the third class:
a settled viewport (`gesture=false animating=false`) whose offset silently changes
before the next traced event, including the focus-reveal/arrival case above where the
active column also changes.

---

## Source analysis — unrecorded viewport mutation sites

### The raw offset write has no audit

`Sources/Nehir/Core/Layout/Niri/ViewportState.swift:121` — `ViewportOffset.offset(delta:)`.
This is the lowest-level offset mutation; it handles `.static`, `.spring`, and
`.gesture` and shifts each by `delta`. It is called by the column-transition helpers
below and emits nothing.

### Column transitions flip column + offset atomically, unrecorded

`Sources/Nehir/Core/Layout/Niri/ViewportState+ColumnTransitions.swift`:

- `setActiveColumn` — `viewOffsetPixels.offset(delta:)` at line 29 (rebases offset by
  `oldActiveColX - newActiveColX`), then `animateToOffset` at line 44.
- `transitionToColumn` — `viewOffsetPixels.offset(delta:)` at line 70, then
  `animateToOffset` at line 91.
- `snapToColumn` — `viewOffsetPixels = .static(targetOffset)` at line 120.
- `scrollByPixels` — `viewOffsetPixels = .static(newOffset)` at line 143.

`transitionToColumn` is the strongest match for Manifestation B: it changes
`activeColumnIndex` **and** offsets `viewOffsetPixels` in one call, exactly the
`1 → 2` + offset jump seen at the focus confirm.

### Callers of the transition path

- `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:752` — inside
  `handleNewWindowArrival`, the `wasEmpty` branch calls `state.transitionToColumn(0, …,
  animate: false, …)`; the non-empty branch calls `ensureSelectionVisible` /
  `resetViewportForCenteredLoneWindow`. A window arrival for pid 1618 (the
  focus-confirmed token above) is consistent with this path firing.
- `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+InteractiveMove.swift:45` —
  `state.transitionToColumn(…)` during interactive move.

### Animation helpers animate *from* the silently-shifted offset

`Sources/Nehir/Core/Layout/Niri/ViewportState+Animation.swift`:

- `animateToOffset` at line 65 — starts a `.spring` toward a target, reading the
  current offset as the animation start. This is the call whose `scroll_animation_start`
  trace records the post-shift `currentViewStart` (e.g. `616.0`), making the shift look
  like it came from the animation rather than the preceding unrecorded write.
- `settleAtCurrentOffset` at line 107 — used by the gesture path to fold an interrupted
  animation into the next gesture.
- `offsetViewport(by:)` at line 120 — another direct offset write.

### Reveal + relayout trigger

`Sources/Nehir/Core/Controller/AXEventHandler.swift:2483` (`reveal_skipped`),
`:2501` (`request_relayout`), and the following `requestRefresh(reason:
.layoutCommand)` around `:2505`. The relayout request is what can run the
`NiriLayoutHandler` arrival/transition path above. `scrollToReveal` itself lives at
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:68` and emits
no `recordRuntimeViewportTrace` of its own.

### Why no current trace sees it

`recordRuntimeViewportTrace` (`Sources/Nehir/Core/Controller/WMController.swift:2578`)
is called only at sites that already have a reason string. None of the raw offset
writes (`offset(delta:)`, `.static(...)` assignments, `transitionToColumn`'s
`offset(delta:)`) pass through a shared mutation hook, and `ViewportState` has no
`lastViewportMutationReason` / timestamp. So a move made by a column transition or a
window arrival is invisible until the *next* traced event reads the already-shifted
state.

---

## Plan

### Phase 1 — Centralized viewport-mutation audit + provenance (no behavior change)

Goal: make the missing mutation self-identifying on the next capture.

1. Add a debug-only audit helper on `ViewportState`, e.g.
   `mutating func recordViewportMutation(reason:caller:before:after:)`, that stores:
   - `lastViewportMutationReason: String`
   - `lastViewportMutationCaller: String` (function/file)
   - `lastViewportMutationTimestamp: TimeInterval`
   - compact before/after: `currentOffset`, `targetOffset`, offset kind
     (`static`/`spring`/`gesture`), `activeColumnIndex`.

2. Route the raw offset writes through it:
   - `ViewportOffset.offset(delta:)` (`ViewportState.swift:121`)
   - every `.static(...)` assignment and `animateToOffset` in
     `ViewportState+ColumnTransitions.swift` (`setActiveColumn`, `transitionToColumn`,
     `snapToColumn`, `scrollByPixels`)
   - `ViewportState+Animation.swift` (`animateToOffset`, `settleAtCurrentOffset`,
     `offsetViewport`)
   - the single-window seed/centering paths (`resetViewportForCenteredLoneWindow`,
     `prepareSingleWindowViewport`, `NiriLayout.swift` centering)

3. Augment the existing trace lines so the gap becomes attributable. Append
   `lastViewportMutation`, `lastViewportMutationAgeMs`, and before/after offset values
   to every `reason=scroll_animation_start`, `reason=scroll_animation_stop`, and
   `reason=touch_scroll_gesture_armed` record. Emit one explicit anomaly record,
   `reason=touch_scroll_gesture_armed_with_preexisting_animation`, when arming finds
   `gesture=false animating=true` (the discovery's signature).

4. Gate all of the above behind the existing trace-capture flag so there is zero
   overhead when tracing is off, and no behavior change when it is on.

**Exit criteria:** a capture of the same scenario shows a named record for every
offset change between `scroll_animation_stop` and the next traced event; no
`currentViewStart` change lacks a preceding mutation record.

### Phase 2 — Capture and attribute

Goal: turn "a class of sites" into "the site".

1. Reproduce Manifestation B: focus a window on an already-settled workspace such that
   a column transition or window arrival runs (app activation / dock click / new window
   on a multi-column workspace). Capture with Phase 1 instrumentation on.
2. Reproduce Manifestation A: a trackpad three-finger scroll armed after the workspace
   has been idle, to confirm the gesture-arm drift is the same site or a second one.
3. From the new `lastViewportMutation*` values, identify the exact caller(s). Current
   prime suspects, in order: `transitionToColumn` from `handleNewWindowArrival`
   (`NiriLayoutHandler.swift:752`), `setActiveColumn`, and a stale
   `viewOffsetPixels.current()` read feeding `animateToOffset`.

**Exit criteria:** a written attribution naming the function and the call stack for at
least Manifestation B, with the before/after offset values inlined.

### Phase 3 — Fix + regression tests

Goal: eliminate the unexplained shift. The concrete fix depends on Phase 2's
attribution, but the expected shape is:

1. The stale-offset read: `transitionToColumn` / `setActiveColumn` call
   `viewOffsetPixels.offset(delta:)` on whatever offset is currently held. If a prior
   layout/reconcile pass left the offset un-settled (e.g. mid-spring, or a `.static`
   value from a removed column), the rebase compounds the error. Fix by settling /
   re-clamping to a valid snap for the current column before rebasing, or by basing the
   rebase on `stationary()` rather than the live offset where appropriate.
2. If attribution lands on the window-arrival path, ensure arrivals on an already-settled
   workspace do not move the viewport unless the new selection is actually off-screen
   (align with `preserveActiveViewport` semantics already used by the reveal path).
3. Regression tests:
   - Unit test on `ViewportState`: after a settled `scroll_animation_stop` equivalent,
     driving a column transition / arrival must not change `currentViewStart` beyond the
     intended snap target, and must emit a mutation record.
   - Integration-style test mirroring Manifestation B: settle, then focus-confirm a
     window whose column differs from active; assert the only offset change is the
     recorded transition to the target snap, with no unrecorded delta.

**Exit criteria:** the repro from Phase 2 no longer produces an unrecorded offset
change; the trace shows at most `settled → recorded transition → recorded snap`; tests
green.

### Phase 4 — Rollout

- Keep the Phase 1 audit in tree behind the trace flag (cheap, reusable for future
  viewport regressions).
- Update `discovery/20260625-precommitted-viewport-shifts-before-trackpad-gesture.md`
  status to "resolved / promoted" and link this plan once Phase 3 lands.

---

## Acceptance criteria

- A capture of the focus-reveal/column-transition scenario shows **no** `currentViewStart`
  change between a `scroll_animation_stop` and the next traced event that lacks a
  preceding named mutation record.
- The user-visible symptom (viewport slides when no trackpad input was given) does not
  reproduce after Phase 3.
- `transitionToColumn` / `setActiveColumn` / window-arrival paths emit a mutation record
  with before/after offsets and a caller label.
- Regression tests cover both the gesture-arm drift and the focus-reveal transition.

---

## Out of scope / risks

- **Do not** change snap targeting or momentum thresholds here. The afternoon capture's
  large snap-on-`touch_scroll_gesture_end` overshoots (releases snapping to the next
  column edge) are intentional snap behavior, not this bug; they are tracked separately
  if at all.
- **Do not** remove the `preserveActiveViewport` / `reveal_skipped` path; it is correct.
  The bug is upstream of it (the offset was already shifted before the reveal decision).
- Phase 1 is deliberately additive and flag-gated; if any production path shows overhead
  from provenance storage, store only the last mutation (single-slot), not a log.
- If Phase 2 attributes Manifestation A and B to *different* sites, split Phase 3 into
  3a/3b and fix independently; do not couple them.

---

## References

- Discovery being promoted: `discovery/20260625-precommitted-viewport-shifts-before-trackpad-gesture.md`
- Trace emission: `Sources/Nehir/Core/Controller/WMController.swift:2578`
  (`recordRuntimeViewportTrace`), viewport field computation referenced by the discovery
  at the same file.
- Gesture path (unchanged, for context): `Sources/Nehir/Core/Controller/MouseEventHandler.swift`
  (`.idle` armed branch and `applyTrackpadViewportScrollDelta`),
  `Sources/Nehir/Core/Layout/Niri/ViewportState+Gestures.swift:14` (`beginGesture`
  preserves current offset).
