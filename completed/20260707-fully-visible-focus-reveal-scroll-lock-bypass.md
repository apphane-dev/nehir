# Stop automatic focus reveals from re-centering fully visible columns and bypassing scroll lock

Originally verified against main `d953d4d3` on 2026-07-07; final shipped state verified against `main` at `c6eaafb9` on 2026-07-08.

**Status:** completed; merged to `main` as `c6eaafb9` (`Keep the viewport still when focusing an already visible window`).
**Symptom:** Clicking into a window that is already fully visible scrolls the
viewport to that column's center snap — even with viewport scroll lock enabled.
With two visible windows, alternating clicks makes the viewport ping-pong
between the two columns' center snaps on every focus change.
**Desired behavior:** an automatic (non-navigation) focus confirm of a fully
visible column never moves the viewport; scroll lock suppresses **all**
automatic reveals, fully-visible ones included. Explicit navigation commands
(`focus-column-*`, workspace-bar clicks) keep their current behavior, including
revealing while locked.

Root cause and full runtime evidence: see
`20260707-fully-visible-focus-reveal-recenters-viewport-ignoring-scroll-lock.md`.

Source references in the original plan were verified against the main Nehir
source tree at `d953d4d3` on 2026-07-07. The final merged commit is
`c6eaafb9` on 2026-07-08.

## Final shipped state

`c6eaafb9` implemented the policy in the engine and landed regression tests:

- `scrollToReveal` now has an `allowFullyVisibleAutomaticRecenter` escape hatch
  defaulting to `false`, so generic automatic callers cannot re-center a fully
  visible non-filling column.
- The `.fullyVisible` arm now honors the trigger's scroll-lock contract before
  either filling-group maintenance or non-filling recentering can move the
  viewport.
- Non-filling fully-visible recentering is allowed only for
  `.explicitNavigation` or for callers that deliberately pass
  `allowFullyVisibleAutomaticRecenter: true`.
- AX focus confirmation explicitly passes
  `allowFullyVisibleAutomaticRecenter: false`, making the runtime policy
  unambiguous: fully visible + automatic focus confirm ⇒ no viewport movement,
  whether locked or unlocked.
- Explicit-navigation paths that should preserve centering behavior pass
  `.explicitNavigation` through the selection/column-width helpers.
- Regression tests landed in `Tests/NehirTests/ViewportSnapContextTests.swift`
  for automatic fully-visible no-op, explicit-navigation recenter preservation,
  and locked automatic fully-visible suppression.
- Changeset:
  `.changeset/20260708145017-stop-focusing-an-already-fully-visible-window-fr.md`.

## Root cause (inline recap)

`scrollToReveal` in
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70-143`
checks `state.isScrollLocked` (via `trigger.respectsScrollLock`) **only** in the
`case .parked, .clipped:` arm (~:126). The `case .fullyVisible:` arm (~:100-123)
has two exits that animate the viewport and consult neither the trigger nor the
lock:

1. ~:104-121 — filling-group re-centering ("viewport-position maintenance").
2. ~:122-123 — non-filling group with `revealStyle == .auto`:
   `targetSnap = autoSnap()`. `autoSnap()` returns `closest` only when the
   closest snap *fills* the viewport; otherwise it returns `center` — so a
   focus confirm of an already-fully-visible column re-centers it.

The AX focus-confirm caller
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:3551`) passes no `trigger`,
so it gets the default `.automatic` — exactly the class of reveal that
`RevealTrigger.respectsScrollLock`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:16-18`) says scroll lock
must suppress. All genuine navigation call sites
(`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:103,305,330,418,557,588,653,684`,
`Sources/Nehir/Core/Controller/WindowActionHandler.swift:508`) pass
`.explicitNavigation`.

Traced proof (inlined in the discovery): `locked=true visibility=fullyVisible
closest=4773.9:rightEdge closestFills=false center=5434.9:center` →
`didReveal=true`, viewport `5079.0 → 5434.9`; whereas
`locked=true visibility=clipped` → `didReveal=false` (lock works there).
A later two-window capture on Nehir `9ac0b9` confirms this is not merely a
scroll-lock bypass: with lock disabled, both windows initially fully visible
(`w26358` at x=218 width=808; `w26356` at x=1031 width=1011 in an x≈8...2048
viewport), an automatic focus confirm of `w26358` logged
`visibility=fullyVisible locked=false closest=-6.0:leftEdge closestFills=false
center=-616.2:center centerFills=false`, then `didReveal=true` and animated
`targetViewStart=-209.4 → -616.2`. The chosen target was the center snap even
though no reveal was needed.

## Fix (approach A — gate inside `scrollToReveal`; shipped)

The planned core policy shipped, with one final implementation detail added to preserve explicit/navigation call-site intent:

1. **Honor scroll lock for the whole arm.** At the top of
   `case .fullyVisible:`, add the same guard the clipped arm uses:

   ```swift
   case .fullyVisible:
       guard !trigger.respectsScrollLock || !state.isScrollLocked else { return false }
   ```

   This covers both the filling-group maintenance exit and the `autoSnap()`
   fall-through. Explicit navigation (`respectsScrollLock == false`) is
   unaffected.

2. **Stop automatic re-centering of fully visible non-filling groups.** Restrict
   the ~:122-123 fall-through to explicit navigation:

   ```swift
   guard revealStyle == .auto, trigger == .explicitNavigation else { return false }
   targetSnap = autoSnap()
   ```

   Rationale: a `.automatic` focus confirm of a fully visible column is already
   satisfied — moving it is the reported bug even when unlocked. The 2026-07-08
   two-window capture makes this the primary acceptance rule: fully visible +
   automatic must be a no-op even with `isScrollLocked == false`. A deliberate
   `focus-column-*` command may still center per `revealStyle == .auto`.

   Deliberately **kept**: the filling-group maintenance exit (~:104-121) for
   unlocked automatic triggers. That branch enforces the proportional-slack /
   lone-column-centering contract after resizes; the traced bug never entered
   it (`centerFills=false` implies `fillsViewport(at: viewStart)` was false).
   Narrowing it is out of scope.

Alternative rejected: gating at the caller
(`AXEventHandler.swift:3551`) — would fix only this call site and leave the
engine primitive violating its own `RevealTrigger` contract for any future
`.automatic` caller.

### Step 1 — edit `scrollToReveal` (completed)

File: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`,
function `scrollToReveal(columnIndex:isFFM:state:context:motion:scale:animationConfig:allowFullyVisibleAutomaticRecenter:trigger:)`.

The merged code applies the scroll-lock guard at the top of `.fullyVisible`,
keeps the filling-group maintenance path for unlocked automatic triggers, and
requires explicit navigation (or an explicit caller opt-in) before the
non-filling `autoSnap()` fall-through can center a fully visible target.

### Step 2 — regression tests (completed)

File: `Tests/NehirTests/ViewportSnapContextTests.swift`, suite
`ScrollToRevealTests` (~:524). Reuse `makeRevealFixture(viewportWidth:)`.

Note the existing gap: `scrollToRevealDoesNotMoveFullyVisibleTarget` (~:558)
passes today only because its fixture's snaps coincide with the current
position; it never exercises a fully visible column whose closest snap does
**not** fill the viewport with a center snap elsewhere. New tests must build
that geometry (wide viewport, columns narrower than it, viewStart at a
non-center snap of the target column — mirror the traced shape: closest snap ≠
center snap ≠ current viewStart, `closestFills == false`).

Final coverage added in `c6eaafb9`:

1. `scrollToRevealSuppressesFullyVisibleAutomaticRecenter` — automatic + fully
   visible + non-filling closest + unlocked does not move, and the fixture proves
   the old auto target would have differed from the current offset.
2. `scrollToRevealSkipsFullyVisibleAutomaticWhenLocked` — automatic + fully
   visible + locked does not move.
3. `scrollToRevealAllowsFullyVisibleExplicitNavigationRecenter` — explicit
   navigation with the same geometry may still center.
4. Existing clipped + locked and simple fully-visible no-op coverage stayed in
   place.

The new tests cover the previously false-positive geometry where the target is
fully visible, closest snap does not fill, and the center snap is elsewhere.

### Step 3 — runtime verification hook (post-merge expectation)

No new diagnostics needed. The existing
`ax_focus_confirm_reveal_candidate` / `_result` records
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:3534-3568`) should show
`didReveal=false` for `visibility=fullyVisible` on the automatic path (locked
or not), with no subsequent `relayout.viewportOffsetChanged` retarget.

## Do-not-touch fences / final deviations

- Do **not** modify `RevealTrigger` / `respectsScrollLock`
  (`NiriLayoutEngine.swift:10-19`) — semantics are correct as documented.
- Final implementation did touch `NiriNavigation.swift` and related helper
  plumbing only to preserve explicit-navigation behavior after adding
  `allowFullyVisibleAutomaticRecenter`. `WindowActionHandler.swift` was not
  changed.
- Final implementation touched the AX focus-confirm caller only to pass
  `allowFullyVisibleAutomaticRecenter: false`; diagnostics were not redesigned.
- `snapCandidates`, `fillsViewport`, `centeredFillingViewportStart`,
  `ViewportState+Geometry.swift`, and `ViewportState+Gestures.swift` stayed
  untouched, preserving the parallel snap-grid fence
  (`../planned/20260707-lone-column-fling-snaps-offscreen-overscroll-bound.md`).
- Final change set included helper signature propagation through
  explicit-navigation paths plus tests and changeset; the behavior core remained
  in `NiriLayoutEngine+ViewportCommands.swift`.

## Gate

- Worker and supervisor builds passed with `mise run build`.
- Merge commit includes regression tests; run `mise run check` before release if this branch is used as the release-readiness record.

## Changeset (completed)

```bash
mise run changeset patch "Stop focusing an already fully visible window from scrolling the viewport, and make viewport scroll lock suppress these automatic reveals"
```

(Reference a nehir issue number only if one exists — none is known at plan
time. Do not cite upstream tickets.)

## Commit

`c6eaafb9` — `Keep the viewport still when focusing an already visible window`

## Completion token

`PLAN_DONE_fully_visible_reveal_lock_gated`
