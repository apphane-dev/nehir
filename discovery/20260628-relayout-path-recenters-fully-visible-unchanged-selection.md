# Discovery: relayout path recenters a fully-visible, unchanged-selection viewport

Groom 2026-07-08: in flight (partially resolved) — the stronger focus-confirmation fully-visible no-op and scroll-lock guard shipped in `c6eaafb9`, superseding the earlier narrower `0602387d` focus-confirmation slice. Config-change parked-viewport stabilization landed (`9dd0f777`). The residual relayout selection-reconciliation scope remains under `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`, but should be revalidated against `c6eaafb9` because non-filling fully-visible automatic `scrollToReveal` now no-ops by default.

Status: root cause found and source-attributed. Three user-reported "viewport
moved with no trackpad input" captures, plus source analysis, pinned the mover to
the relayout selection-reconciliation path. After `c6eaafb9`, the
focus-confirmation variant is fixed and automatic non-filling fully-visible
`scrollToReveal` no-ops by default; the relayout evidence remains open only for
revalidation of active-column rebases, filling-group maintenance, and static
`centeredViewportCorrection` movement.

Validated against the `patch/unrecorded-viewport-offset-mutation-attribution`
branch on 2026-06-28. Source paths are repository-relative.

## Summary

Any relayout that runs while the viewport is settled — whether triggered by typing
(transient child surfaces being admitted/rejected/destroyed) or by a display
topology change (an external display connecting) — re-runs the relayout's
`resolveSelection` step. That step's `ensureSelectionVisible → scrollToReveal` path
snap-recenters the viewport even when the selection, the active column, and the
column count are all unchanged and the selected window is already fully visible.
The result is an unexpected viewport slide/jump away from a position the system
itself had settled at.

The **common factor** across every repro is the *mover*, not the trigger: the
recenter runs for any settled-viewport relayout, regardless of what caused it.
Typing and display-connect are simply two of many ways a relayout fires while the
viewport is settled.

This is the same behavior earlier focus-confirmation work tried to remove from
the **focus-confirmation** path. That boundary was strengthened by `c6eaafb9`,
which makes fully-visible non-filling automatic `scrollToReveal` calls no-op by
default and preserves centering only for explicit navigation / explicit caller
opt-in. The **relayout** path still deserves separate revalidation because it
also performs active-column rebases and can enter the filling-group maintenance
path; this document remains open for those non-config relayout cases until a new
capture proves they are gone or still reachable.

## Evidence — three repros, one signature

Two repros are the Helium app (pid 13175) on a two-column workspace where typing
spawns transient child surfaces. A third is a three-column workspace hit by a
display topology change (external DELL display connecting). In all three the
viewport is settled (`gesture=false animating=false`) at a snap the system chose,
the relayout runs, and the offset re-centers — with the selection, active column,
and column count unchanged throughout. Values are quoted from the captured records;
no trace files are referenced.

### Repro A — typing, transient surface then relayout

Settled state (`scroll_animation_stop`):

```text
activeColumnIndex=1 columns=2 currentOffset=-32.0 currentViewStart=972.0 targetViewStart=972.0
gesture=false animating=false selectedNode=NodeId(…39B7CBB6…) confirmedFocus=WindowToken(pid: 13175, windowId: 353)
```

Transient child surface appears and is rejected as a non-standard AX surface
(parented to window 353):

```text
workspace=… rejected reason=nonStandardAXSurface token=WindowToken(pid: 13175, windowId: 368) parentWindowId=353
frame={{193.0, 959.0}, {530.0, 307.0}} transientWindowServerEvidence=true
```

The surface is destroyed and the managed windows are re-placed in the same
relayout (353 to a visible target, 284 to a hidden offscreen target).

Final snapshot of the same workspace — only the offset moved:

```text
activeColumnIndex=1 columns=2 currentOffset=-534.0 currentViewStart=470.0 targetViewStart=470.0
gesture=false animating=true selectedNode=NodeId(…39B7CBB6…) preferredFocus=WindowToken(pid: 13175, windowId: 353)
```

`currentViewStart` moved `972.0 → 470.0` (`currentOffset -32.0 → -534.0`, Δ −502)
with `activeColumnIndex`, `selectedNode`, and `columns` unchanged, and
`animating=true` (a spring retarget) with no `scroll_animation_start` for it.

### Repro B — typing, burst of transient surfaces, then relayout

Settled state (`scroll_animation_stop`):

```text
activeColumnIndex=1 columns=2 currentOffset=-1288.0 currentViewStart=1098.4 targetViewStart=1098.4
gesture=false animating=false selectedNode=NodeId(…126A3473…) confirmedFocus=WindowToken(pid: 13175, windowId: 2279)
```

A burst of transient surfaces is created and rejected (`reason=existing_entry` /
`missing_ax_ref`, windows 2275–2280), one is destroyed (2277), and a relayout
activates the already-focused window:

```text
relayout_activated_window token=WindowToken(pid: 13175, windowId: 2279) workspace=…
```

The focus-confirmation path correctly does **not** move the viewport:

```text
ax_focus_confirm_reveal_skipped token=WindowToken(pid: 13175, windowId: 2279) preserveActiveViewport=true
```

Final snapshot — again, only the offset moved:

```text
activeColumnIndex=1 columns=2 currentOffset=-660.0 currentViewStart=1726.4 targetViewStart=1726.4
gesture=false animating=true selectedNode=NodeId(…126A3473…) preferredFocus=WindowToken(pid: 13175, windowId: 2279)
```

`currentViewStart` moved `1098.4 → 1726.4` (`currentOffset -1288.0 → -660.0`,
Δ +628) with `activeColumnIndex`, `selectedNode`, and `columns` unchanged, again a
spring retarget with no `scroll_animation_start`.

### Repro C — display topology change (no typing)

Repro C proves the trigger is not typing/transient surfaces but any settled-viewport
relayout. It was captured on the current binary, so the emit-at-chokepoint hook fired
and named the mover directly.

A three-column workspace (Helium windows in columns 0–2, `activeColumnIndex=2`) is
settled after a trackpad fling completed at its chosen snap:

```text
scroll_animation_stop activeColumnIndex=2 currentOffset=-32.0 currentViewStart=1976.0 animating=false
tickAnimation.complete
```

Four seconds later, an external DELL display connects (`event=topology_changed
displays=2 plan=topology=1->2`), a burst of `window_admitted` /
`hidden_state_changed` / `managed_replacement_metadata_changed` events fires, and a
relayout runs. The hook emits:

```text
reason=relayout.viewportOffsetChanged
activeColumnIndex=2 columns=3 currentOffset=-33.3 currentViewStart=1975.4 targetViewStart=1474.0 animating=true
lastViewportMutation=animateToOffset.spring
lastViewportMutationCaller=Nehir/ViewportState+Animation.swift:98 animateToOffset(_:motion:config:scale:)
lastViewportMutationBeforeKind=static lastViewportMutationBeforeActiveColumnIndex=2
lastViewportMutationAfterTargetOffset=-534.0 lastViewportMutationAfterActiveColumnIndex=2
```

`currentViewStart` moved `1976.0 → 1474.0` (`targetOffset -32.0 → -534.0`) with
`activeColumnIndex`, `selectedNode`, and `columns` unchanged. The key point: the
recentered value (`-534`) is **not a geometry correction** — display 1's frame
(`(0.0, 0.0, 2056.0, 1329.0)`) and the three-column layout (column x = 0.0 / 1004.0
/ 2008.0, width 972) were byte-identical before and after. `-32` was the canonical
snap for `activeColumnIndex=2` (six other trackpad snaps in the same capture land on
it). The recenter moved *away* from a correct, system-settled position.

### The distinguishing signature

Across all three repros the move shares these properties:

- `activeColumnIndex`, `selectedNode`, and `columns` are **unchanged** across the
  move — only the offset recenters.
- The viewport was settled (`gesture=false animating=false`) before the move.
- The move is a spring (`animating=true` after) with no corresponding
  `scroll_animation_start` record.
- The trigger is **any** relayout that runs while the viewport is settled —
  transient-surface burst from typing (A/B) or a display topology change (C). In A
  and B the focus-confirmation reveal was skipped with `preserveActiveViewport=true`,
  so the focus-confirm path is explicitly **not** the mover.
- In C the recentered value is provably not a geometry correction (frame and column
  layout unchanged), so the recenter is moving away from a legitimate settled
  position, not correcting drift.

### Observability note

Repro B was captured with the emit-at-chokepoint hook already present but still
gated by a `!isAnimating` clause, which suppressed exactly the spring-retarget
case; the hook fired zero times. The clause was subsequently removed
(commit "Record spring-retarget viewport mutations, not just static ones"), so a
re-capture on the current binary would emit a `reason=relayout.viewportOffsetChanged`
record carrying `lastViewportMutationCaller` naming the exact recenter site. **Repro
C is exactly that re-capture** and confirms the attribution directly:
`lastViewportMutationCaller=Nehir/ViewportState+Animation.swift:98 animateToOffset`,
`lastViewportMutationBeforeKind=static`, `before`/`after` `activeColumnIndex=2`.
Because the audit is a single slot, it captures the innermost caller
(`animateToOffset`) rather than the higher-level `ensureSelectionVisible`/
`scrollToReveal` entry; that innermost caller with `beforeKind=static`, unchanged
`activeColumnIndex`, and no gesture is only reachable via the reveal/recenter path
(see source attribution).

## Source attribution

### The mover: `resolveSelection` recentering on the relayout path

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` — `resolveSelection`
(around `:570`) runs two recentering blocks whenever the viewport is settled on the
active workspace:

- `:642` `pass.engine.ensureSelectionVisible(...)` — gated on
  `!isGestureOrAnimation && !preservesUnsnappedGestureOffset && isActiveWorkspace`.
- `:685` `state.setStaticViewOffsetPixels(..., reason: "resolveSelection.centeredViewportCorrection")`
  — a static recenter to the centered fill start, same gate.

`ensureSelectionVisible` (`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift`)
rebases the active column and then delegates to `scrollToReveal`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`). Before
`c6eaafb9`, `scrollToReveal`'s `.fullyVisible` branch snap-recentered the target
when the viewport was not already at a filling snap — i.e. it moved an already
fully-visible window. Because both repros were springs (`animating=true`), the
active mover was the `ensureSelectionVisible → scrollToReveal → animateToOffset`
path, not the static `centeredViewportCorrection`.

### Post-`c6eaafb9` boundary

`c6eaafb9` changed `scrollToReveal` so automatic non-filling fully-visible calls
no-op by default, and it preserved recentering only for explicit navigation or an
explicit caller opt-in. That closes the focus-confirmation variant and may also
remove some relayout-driven non-filling recenters. This discovery remains open
because the relayout path still performs active-column rebases before reveal and
can still enter filling-group maintenance / `centeredViewportCorrection` paths.
Those residual paths need a fresh capture before implementing another behavior
change.

## Root cause

Relayout-driven selection reconciliation may still violate the broader "do not
move a fully-visible, unchanged-selection viewport" rule, but the exact
non-filling `scrollToReveal` mechanism documented here was narrowed by
`c6eaafb9`. A relayout triggered by an unrelated cause — transient child surfaces
from typing, a display topology change, or any other refresh that fires while the
viewport is settled — still runs `resolveSelection`; remaining suspicious movers
are active-column rebases, filling-group maintenance, and static centered-viewport
correction when nothing about the user's selection or column layout changed.
Repro C proves the recentered value need not even be a geometry correction:
display frame and column layout were unchanged, so the move was away from a
legitimate settled position.

## Fix direction

Revalidate and then extend the `c6eaafb9` principle into any relayout path still
moving a fully-visible unchanged selection:

1. First capture the residual behavior on a build containing `c6eaafb9`. If the
   old non-filling `scrollToReveal` recenter is gone, narrow this discovery to the
   remaining mover (`moveSelectionToContainer.rebaseActiveColumn`, filling-group
   maintenance, or `centeredViewportCorrection`).
2. If `resolveSelection` still moves without a real selection/layout/removal
   change, gate the `ensureSelectionVisible` call (and the
   `centeredViewportCorrection` block) on an actual change that justifies a
   recenter — e.g. the selected node changed, the active column changed, the
   column set changed, or a removal shifted visibility.
3. Alternatively (or additionally), have `ensureSelectionVisible` itself take a
   fully-visible/unchanged-selection fast-path for automatic relayout callers, so
   every relevant caller benefits rather than only `resolveSelection`.

The fix must preserve the legitimate recenter cases: genuine selection change,
window arrival/removal that changes visibility, and lone-window centering
(`resetViewportForCenteredLoneWindow`), all of which must still move the viewport.

## Out of scope

- The display-connect column-collapse attribution gap (single-slot audit collapse)
  is a separate finding — see
  `discovery/20260628-relayout-commit-collapses-intermediate-viewport-mutations.md`.
- Snap targeting and fling momentum on `touch_scroll_gesture_end` are intentional
  snap behavior, not this bug.
- The emit-at-chokepoint hook double-counts legitimate trackpad-fling snaps: in
  Repro C's capture it fired 12 times, of which 9 were `endGesture.spring` from
  `ViewportState+Gestures.swift:157` (each a correct fling snap that also records a
  `scroll_animation_start`). Only the two `animateToOffset` records on a settled
  (`beforeKind=static`), unchanged-selection viewport were the bug; the rest were
  redundant echoes of gesture/animation paths that already emit their own records.
  This is a hook-precision nit (the hook could skip when `lastViewportMutationCaller`
  is itself a gesture/animation-emitting path), separate from the recenter bug.

## References

- Strengthened fully-visible automatic no-op (focus-confirm path and generic
  non-filling automatic `scrollToReveal`):
  `../completed/20260707-fully-visible-focus-reveal-scroll-lock-bypass.md`
  (`c6eaafb9`).
- Mover (relayout path): `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570`
  (`resolveSelection`), `:642` (`ensureSelectionVisible` call),
  `:685` (`centeredViewportCorrection`).
- Residual mover candidates after `c6eaafb9`:
  `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift` (`ensureSelectionVisible`
  active-column rebase), `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift`
  (`scrollToReveal` `.fullyVisible` filling-group maintenance), and
  `NiriLayoutHandler.swift` `centeredViewportCorrection`.
- Parent plan: `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`.
