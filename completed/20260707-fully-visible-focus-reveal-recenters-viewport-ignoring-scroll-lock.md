# Focusing a fully visible window re-centers the viewport, ignoring scroll lock

**Date:** 2026-07-07
**Status:** Completed; fixed on `main` by `c6eaafb9` (2026-07-08).
**Area:** Niri viewport reveal on AX focus confirm.

**Final state:** `c6eaafb9` keeps automatic focus confirmation from moving
an already fully visible column, even when scroll lock is off, and makes the
fully-visible arm honor scroll lock for automatic triggers. Explicit navigation
keeps its ability to center/reveal visible targets. Regression coverage landed in
`Tests/NehirTests/ViewportSnapContextTests.swift`; the changeset is
`.changeset/20260708145017-stop-focusing-an-already-fully-visible-window-fr.md`.

Cross-link cluster: [`VR-1` in `20260708-cross-discovery-relevance-clusters.md`](../discovery/20260708-cross-discovery-relevance-clusters.md#vr-1--automatic-revealrecentersnap-movement-bypasses-user-intent-or-visibility-checks) groups the high-confidence automatic reveal/recenter/snap bugs.

## Symptom

Clicking into (focusing) a window that is already **fully visible** scrolls the
viewport to re-center that window's column — even with **viewport scroll lock
enabled**. With two visible windows on screen, alternating focus between them
makes the viewport ping-pong between each column's center snap on every focus
change, despite neither window ever being off-screen.

A later capture with scroll lock **disabled** reduced the case further: two
windows were fully visible at the moment focus changed, and the automatic focus
confirm still moved the viewport to the target column's center snap. So the
primary policy is not lock-dependent: focusing a fully visible window is already
satisfied and should be a no-op; scroll lock is an additional guard for every
automatic reveal.

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

Fresh confirmation from a later capture (Nehir runtime `9ac0b9`, 2026-07-08)
uses a smaller two-window topology and proves the same unlocked policy breach.
At capture start on workspace 2, both windows were fully visible in the
2040 px-wide viewport:

- `w26358` (pid 82494) was at screen x=218, width=808.
- `w26356` (pid 82494) was at screen x=1031, width=1011.
- The viewport x-range was approximately 8...2048, so both windows were wholly
  inside the viewport.
- The engine state was `currentViewStart=-209.4`, `targetViewStart=-209.4`,
  active/selected column 1 (`w26356`).

Click/focus-confirm of `w26358` while **fully visible and unlocked** produced:

```
11:42:32 reason=ax_focus_confirm_reveal_candidate token=(pid 82494, windowId 26358)
         columnIndex=0 revealStyle=auto locked=false visibility=fullyVisible
         viewStart=-209.4 closest=-6.0:leftEdge closestFills=false
         center=-616.2:center centerFills=false snapCount=3
         columns=2 activeColumnIndex=1 currentViewStart=-209.4 targetViewStart=-209.4
11:42:32 reason=ax_focus_confirm_reveal_result   didReveal=true
11:42:32 reason=relayout.viewportOffsetChanged   currentViewStart=-209.7 targetViewStart=-616.2
         lastViewportMutation=animateToOffset.spring
         beforeTargetOffset=-209.4 afterTargetOffset=-616.2
11:42:32 reason=scroll_animation_stop            currentViewStart=-616.2 targetViewStart=-616.2
```

The target `-616.2` exactly equals the logged center snap. This capture has no
scroll-lock ambiguity (`locked=false`): the bug is that an automatic focus
confirm of an already fully visible window chose a center snap at all. The
policy should be "fully visible + automatic ⇒ no viewport movement" whether
scroll lock is enabled or disabled.

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

## Original root cause (verified against `main` on 2026-07-07, d953d4d3)

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

## Fix shipped

In `scrollToReveal`'s `.fullyVisible` branch
(`NiriLayoutEngine+ViewportCommands.swift`), `c6eaafb9`:

1. Gates the entire `.fullyVisible` branch (both filling-group maintenance and
   the `autoSnap()` fall-through) with the same scroll-lock guard as the clipped
   path.
2. Stops automatic focus confirmation from re-centering a fully visible,
   non-filling column. The final implementation allows that recentering only
   for `.explicitNavigation` or for a caller that deliberately opts in via
   `allowFullyVisibleAutomaticRecenter`.

Explicit-navigation behavior (reveal while locked / deliberate centering) was
preserved; automatic focus-confirm behavior became a no-op for fully visible
targets.

## Verification hooks / final verification

- Shipped in `c6eaafb9`:
  `scrollToRevealSuppressesFullyVisibleAutomaticRecenter`,
  `scrollToRevealAllowsFullyVisibleExplicitNavigationRecenter`, and
  `scrollToRevealSkipsFullyVisibleAutomaticWhenLocked` cover the unlocked
  automatic no-op, explicit-navigation recenter, and locked automatic no-op
  cases.
- The existing `ax_focus_confirm_reveal_candidate` / `_result` diagnostics
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:3534-3568`) already log
  `locked`, `visibility`, snap candidates, and `didReveal`; a fixed build should
  show `didReveal=false` for `visibility=fullyVisible` on the `.automatic` path
  (locked or not), with no subsequent `relayout.viewportOffsetChanged` retarget.
- Regression tests now live next to the engine tests for viewport commands and
  cover fully-visible + locked, fully-visible + unlocked + auto style +
  non-filling closest snap, and explicit navigation preservation. Existing
  clipped + locked suppression stayed covered.
