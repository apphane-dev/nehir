# Stop automatic focus reveals from re-centering fully visible columns and bypassing scroll lock

Re-verified against main d953d4d3 on 2026-07-07.

**Status:** planned.
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
`discovery/20260707-fully-visible-focus-reveal-recenters-viewport-ignoring-scroll-lock.md`.

Source references verified against the main Nehir source tree at HEAD
`d953d4d3` ("Float zero-frame Gecko transient dialogs that the first #142 fix
still tiled") on 2026-07-07. **Re-verify line numbers before editing; they
drift.**

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

## Fix (approach A — gate inside `scrollToReveal`; recommended)

Two changes inside the `case .fullyVisible:` arm of `scrollToReveal`, nothing
else:

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

### Step 1 — edit `scrollToReveal`

File: `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`,
function `scrollToReveal(columnIndex:isFFM:state:context:motion:scale:animationConfig:trigger:)`.

Apply the two guards above. Keep the existing comment about filling-group
maintenance; extend it with one sentence noting the arm is lock-gated. Match
surrounding style; no other logic changes.

### Step 2 — regression tests

File: `Tests/NehirTests/ViewportSnapContextTests.swift`, suite
`ScrollToRevealTests` (~:524). Reuse `makeRevealFixture(viewportWidth:)`.

Note the existing gap: `scrollToRevealDoesNotMoveFullyVisibleTarget` (~:558)
passes today only because its fixture's snaps coincide with the current
position; it never exercises a fully visible column whose closest snap does
**not** fill the viewport with a center snap elsewhere. New tests must build
that geometry (wide viewport, columns narrower than it, viewStart at a
non-center snap of the target column — mirror the traced shape: closest snap ≠
center snap ≠ current viewStart, `closestFills == false`).

Add, at minimum:

1. **Automatic + fully visible + non-filling closest ⇒ no movement, unlocked.**
   `trigger` defaulted (`.automatic`), `isScrollLocked = false`,
   target column fully visible, `revealStyle = .auto`. Assert `!revealed` and
   `viewOffsetPixels.target()` unchanged. (Encodes the reported bug directly;
   fails on current main.)
2. **Automatic + fully visible + locked ⇒ no movement** — same fixture with
   `isScrollLocked = true`, including a variant where
   `fillsViewport(at: viewStart)` is true (filling-group maintenance must also
   be suppressed while locked).
3. **Explicit navigation + fully visible ⇒ may still center.** Same geometry,
   `trigger: .explicitNavigation`, `revealStyle = .auto`: assert `revealed` and
   the target offset equals the center snap's offset (preserves command
   centering).
4. **No regression on existing suppressions:** `scrollToRevealSkipsWhenLocked`
   (clipped + locked) and `scrollToRevealDoesNotMoveFullyVisibleTarget` must
   stay green unmodified.

Per repo policy, do **not** add or modify tests until the user confirms the fix
in their real repro. The first implementation pass should land the code fix and
changeset only; add the regression tests as a follow-up after real-world
confirmation.

### Step 3 — runtime verification hook

No new diagnostics needed. The existing
`ax_focus_confirm_reveal_candidate` / `_result` records
(`Sources/Nehir/Core/Controller/AXEventHandler.swift:3534-3568`) must show
`didReveal=false` for `visibility=fullyVisible` on the automatic path (locked
or not), with no subsequent `relayout.viewportOffsetChanged` retarget.

## Do-not-touch fences

- Do **not** modify `RevealTrigger` / `respectsScrollLock`
  (`NiriLayoutEngine.swift:10-19`) — semantics are correct as documented.
- Do **not** modify any `NiriNavigation.swift` or `WindowActionHandler.swift`
  call sites — explicit navigation behavior is preserved by construction.
- Do **not** modify the AX focus-confirm caller
  (`AXEventHandler.swift:3513-3579`) or its diagnostics.
- Do **not** touch `snapCandidates`, `fillsViewport`,
  `centeredFillingViewportStart`, or anything in
  `ViewportState+Geometry.swift` / `ViewportState+Gestures.swift` — parallel
  work owns the snap-grid area
  (`planned/20260707-lone-column-fling-snaps-offscreen-overscroll-bound.md`).
- This change is two files (`NiriLayoutEngine+ViewportCommands.swift`,
  `ViewportSnapContextTests.swift`) plus a changeset.

## Gate

- **Between steps (fast):** `mise run build`.
- **Once at the end (full):** `mise run check` (format + lint + build + test).
  New tests pass; existing `ScrollToRevealTests` stay green.

## Changeset (required — user-visible bug fix)

```bash
mise run changeset patch "Stop focusing an already fully visible window from scrolling the viewport, and make viewport scroll lock suppress these automatic reveals"
```

(Reference a nehir issue number only if one exists — none is known at plan
time. Do not cite upstream tickets.)

## Commit message shape

Plain-English subject, no Conventional-Commits prefix, e.g.:

```
Keep the viewport still when focusing an already visible window

Focusing a fully visible column re-centered the viewport whenever the closest
snap did not fill the viewport, and the fully-visible arm of scrollToReveal
never consulted scroll lock — so alternating focus between two visible windows
ping-ponged the viewport even while locked. Gate the fully-visible arm on the
reveal trigger's scroll-lock contract and reserve fully-visible re-centering
for explicit navigation.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

## Completion token

On success, after the full gate is green, print exactly:

`PLAN_DONE_fully_visible_reveal_lock_gated`
