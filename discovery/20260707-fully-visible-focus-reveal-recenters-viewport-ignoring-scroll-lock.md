# Focusing a fully visible window re-centers the viewport, ignoring scroll lock

**Date:** 2026-07-07
**Status:** Root cause confirmed in source; actionable.
**Area:** Niri viewport reveal on AX focus confirm.

Cross-link cluster: [`VR-1` in `20260708-cross-discovery-relevance-clusters.md`](20260708-cross-discovery-relevance-clusters.md#vr-1--automatic-revealrecentersnap-movement-bypasses-user-intent-or-visibility-checks) groups the high-confidence automatic reveal/recenter/snap bugs.

## Symptom

Clicking into (focusing) a window that is already **fully visible** scrolls the
viewport to re-center that window's column — even with **viewport scroll lock
enabled**. With two visible windows on screen, alternating focus between them
makes the viewport ping-pong between each column's center snap on every focus
change, despite neither window ever being off-screen.

Expected: focusing a fully visible window is not a reveal; nothing should move.
With scroll lock on, even a clipped window should not trigger an automatic
reveal (only explicit navigation may).

## Reproduction topology

Single active workspace (workspace 1) on a 2056×1329 display
(visibleFrame 1978×1290), 10 tiled columns, `revealStyle=auto`, three snap
candidates per column (`snapCount=3`). Two adjacent columns both at least
partially in view:

- Column 5: window `w215` (pid 28651, Helium browser), wide column
  (frame width ≈ 1926.5 px on screen; layout width 1011 at column x=5085).
- Column 6: window `w1815` (pid 41491), width 706–1011 at column x=6102.

Steps: click `w1815` while it is fully visible, then click `w215` while it is
fully visible, repeat. Each click scrolls the viewport. Enabling viewport scroll
lock does not stop it.

## Runtime evidence (inlined from a captured viewport trace, 2026-07-07)

The viewport trace attributes each movement. The mover is the AX focus-confirm
reveal path (`ax_focus_confirm_reveal_candidate` / `_result` records). Key
records, quoted with the fields that matter:

Focus confirm of `w1815` (column 6) while **fully visible and locked**:

```
09:21:42 reason=ax_focus_confirm_reveal_candidate token=(pid 41491, windowId 1815)
         columnIndex=6 revealStyle=auto locked=true visibility=fullyVisible
         viewStart=5079.0 closest=4773.9:rightEdge closestFills=false
         center=5434.9:center centerFills=false snapCount=3
09:21:42 reason=ax_focus_confirm_reveal_result   didReveal=true
09:21:42 reason=relayout.viewportOffsetChanged   currentViewStart=5081.5 targetViewStart=5434.9
```

The viewport animated from 5079.0 to 5434.9 — exactly the `center` snap of the
already-fully-visible column, with `locked=true`.

Focus confirm of `w215` (column 5), same pattern:

```
09:21:55 reason=ax_focus_confirm_reveal_candidate token=(pid 28651, windowId 215)
         columnIndex=5 revealStyle=auto locked=true visibility=fullyVisible
         viewStart=4773.9 closest=4570.5:center center=4570.5:center centerFills=false
09:21:55 reason=ax_focus_confirm_reveal_result   didReveal=true
```

Viewport moved 4773.9 → 4570.5 (again the `center` snap; this was the final
resting `currentViewStart=4570.5` of the session). The identical pair recurred
at 09:22:03. An earlier occurrence at 09:21:36 with `locked=false` shows the
same fully-visible re-center, so the movement happens regardless of lock state
— the lock simply never enters the decision.

For contrast, the lock **does** work in the clipped path:

```
09:21:44 reason=ax_focus_confirm_reveal_candidate token=(pid 28651, windowId 215)
         columnIndex=5 locked=true visibility=clipped(Nehir.AxisHideEdge.minimum)
09:21:44 reason=ax_focus_confirm_reveal_result   didReveal=false
```

Clipped + locked → correctly suppressed, viewport stayed at 5434.9.

Summary of the contradiction: `didReveal=true` exactly when
`visibility=fullyVisible` (movement least justified), `didReveal=false` when
`visibility=clipped` (lock correctly honored). Ordinary user scrolls in the same
capture are separately attributed (`touch_scroll_gesture_*`,
`scroll_animation_*`) and are not involved.

## Root cause (verified against `main` on 2026-07-07, d953d4d3)

`NiriLayoutEngine.scrollToReveal` —
`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70-143`.

The scroll-lock guard exists **only** in the `.parked, .clipped` case
(line 126):

```swift
case .parked,
     .clipped:
    guard !trigger.respectsScrollLock || !state.isScrollLocked else { return false }
```

The `case .fullyVisible` branch (lines 100–123) has two exits that move the
viewport and **neither consults the trigger or the lock**:

1. Lines 104–121 — "re-centering a fully visible filling group is
   viewport-position maintenance, not a reveal": animates to
   `centeredFillingViewportStart` with no lock check.
2. Lines 122–123 — when the group does not fill the viewport and
   `revealStyle == .auto`, it falls through to `targetSnap = autoSnap()`.
   `autoSnap()` returns `closest` only if `closest` *fills* the viewport;
   in the traced layout `closestFills=false`, so it returns `center` — and the
   function animates the already-fully-visible column to its center snap.

The traced movements match exit 2: the observed targets (5434.9, 4570.5) equal
the logged `center` snap candidates, and `centerFills=false` rules out the
filling-group maintenance branch.

The caller is the AX focus-confirm path —
`Sources/Nehir/Core/Controller/AXEventHandler.swift:3551` — which calls
`scrollToReveal` **without** a `trigger` argument, so it gets the default
`trigger: .automatic` (`NiriLayoutEngine+ViewportCommands.swift:78`).
Per `RevealTrigger` (`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine.swift:10-19`),
`.automatic` reveals are exactly the ones scroll lock is documented to suppress
("Background maintenance/layout reveals should be suppressed by viewport scroll
lock"), and every explicit navigation call site
(`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:103,305,330,418,557,588,653,684`,
`Sources/Nehir/Core/Controller/WindowActionHandler.swift:508`) passes
`.explicitNavigation`. The intent is unambiguous; the `.fullyVisible` branch
just never implements it.

So two invariants are violated by the same branch:

- **Fully visible ⇒ no reveal needed**: `revealStyle == .auto` with a
  non-filling closest snap converts a no-op focus confirm into a re-center.
- **Locked ⇒ no automatic movement**: `state.isScrollLocked` is checked only
  for `.parked`/`.clipped`, never for `.fullyVisible`.

## Fix direction

In `scrollToReveal`'s `.fullyVisible` branch
(`NiriLayoutEngine+ViewportCommands.swift:100-123`):

1. Gate the entire `.fullyVisible` branch (both the filling-group maintenance
   exit and the `autoSnap()` fall-through) with the same guard the clipped path
   uses: `guard !trigger.respectsScrollLock || !state.isScrollLocked else { return false }`.
2. Decide whether an `.automatic` focus-confirm should re-center a fully
   visible, non-filling column at all (lines 122–123). The niri-style
   expectation is no: a focus confirm of a fully visible column is already
   satisfied. Restricting the `autoSnap()` fall-through to
   `.explicitNavigation` triggers would stop the unlocked ping-pong as well,
   while keeping deliberate `focus-column-*` commands free to center.

Explicit-navigation behavior (reveal while locked) must be preserved — only the
`.automatic` trigger's fully-visible behavior changes.

## Verification hooks

- The existing `ax_focus_confirm_reveal_candidate` / `_result` diagnostics
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3534-3568`) already log
  `locked`, `visibility`, snap candidates, and `didReveal`; a fixed build must
  show `didReveal=false` for `visibility=fullyVisible` on the `.automatic` path
  (locked or not), with no subsequent `relayout.viewportOffsetChanged` retarget.
- Regression tests belong next to the engine tests for viewport commands
  (after user-confirmed fix, per repo test policy): fully-visible + locked,
  fully-visible + unlocked + auto style + non-filling closest snap, and
  clipped + locked (existing correct suppression must not regress).
