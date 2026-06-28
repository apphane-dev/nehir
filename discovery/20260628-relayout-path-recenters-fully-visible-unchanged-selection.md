# Discovery: relayout path recenters a fully-visible, unchanged-selection viewport

Status: root cause found and source-attributed. Two user-reported "viewport moved
when I typed in a window" captures, plus source analysis, pin the mover to the
relayout selection-reconciliation path — the same recenter that `dad2e63a` ("Do
not recenter viewport on activation of fully visible windows") suppressed for the
focus-confirmation path, but which the relayout path still performs.

Validated against the `patch/unrecorded-viewport-offset-mutation-attribution`
branch on 2026-06-28. Source paths are repository-relative.

## Summary

When typing in a tiled window spawns transient child surfaces (menus, completions,
popovers), Nehir admits/rejects those surfaces, which drives a relayout of the
parent workspace. The relayout's `resolveSelection` step recenters the viewport
even when the selection, the active column, and the column count are all unchanged
and the selected window is already fully visible. The result is an unexpected
viewport slide/jump with no trackpad input.

This is the same behavior `dad2e63a` removed from the **focus-confirmation** path
by introducing `revealForFocusActivation` (which no-ops when the target is fully
visible). The **relayout** path was left calling `ensureSelectionVisible` →
`scrollToReveal`, which still snap-recenters a fully-visible target. So the
fully-visible-no-op rule established for focus-activation is not yet applied to
relayout-driven selection reconciliation.

## Evidence — two repros, same signature

Both repros are the Helium app (pid 13175) on a two-column workspace. In both,
the viewport is settled (`gesture=false animating=false`) at a left-edge snap, the
user types, transient child surfaces appear and are rejected/destroyed, a relayout
runs, and the viewport recenters — with the selection, active column, and column
count unchanged throughout. Values are quoted from the captured records; no trace
files are referenced.

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

### The distinguishing signature

Across both repros the move shares these properties:

- `activeColumnIndex`, `selectedNode`, and `columns` are **unchanged** across the
  move — only the offset recenters.
- The viewport was settled (`gesture=false animating=false`) before the move.
- The move is a spring (`animating=true` after) with no corresponding
  `scroll_animation_start` record.
- The trigger is a transient-surface burst (typing) that drives a relayout; the
  focus-confirmation reveal was skipped with `preserveActiveViewport=true`, so the
  focus-confirm path is explicitly **not** the mover.

### Observability note

Repro B was captured with the emit-at-chokepoint hook already present but still
gated by a `!isAnimating` clause, which suppressed exactly the spring-retarget
case; the hook fired zero times. The clause was subsequently removed
(commit "Record spring-retarget viewport mutations, not just static ones"), so a
re-capture on the current binary would emit a `reason=relayout.viewportOffsetChanged`
record carrying `lastViewportMutationCaller` naming the exact recenter site. That
record is not needed to fix the bug — the source attribution below is sufficient —
but it is the clean confirmation.

## Source attribution

### The mover: `resolveSelection` recentering on the relayout path

`Sources/Nehir/Core/Controller/NiriLayoutHandler.swift` — `resolveSelection`
(around `:570`) runs two recentering blocks whenever the viewport is settled on the
active workspace:

- `:642` `pass.engine.ensureSelectionVisible(...)` — gated on
  `!isGestureOrAnimation && !preservesUnsnappedGestureOffset && isActiveWorkspace`.
- `:685` `state.setStaticViewOffsetPixels(..., reason: "resolveSelection.centeredViewportCorrection")`
  — a static recenter to the centered fill start, same gate.

`ensureSelectionVisible` (`Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173`)
rebases the active column and then delegates to `scrollToReveal`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`).
`scrollToReveal`'s `.fullyVisible` branch snap-recenters the target when the
viewport is not already at a filling snap — i.e. it moves an already fully-visible
window. Because both repros are springs (`animating=true`), the active mover is the
`ensureSelectionVisible → scrollToReveal → animateToOffset` path, not the static
`centeredViewportCorrection`.

### The asymmetry `dad2e63a` left behind

`dad2e63a` added `revealForFocusActivation`
(`Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:158`),
which returns `false` (no movement) when the target is `.fullyVisible`, and routed
the **focus-confirmation** call site
(`Sources/Nehir/Core/Controller/AXEventHandler.swift`) through it. That is why Repro
B's `ax_focus_confirm_reveal_skipped preserveActiveViewport=true` correctly did not
move the viewport. The **relayout** path (`resolveSelection` →
`ensureSelectionVisible`) was not changed and still calls `scrollToReveal` directly,
so it still recenters a fully-visible, unchanged-selection target. That recenter,
triggered by the transient-surface relayout, is the unexpected move.

## Root cause

Relayout-driven selection reconciliation does not yet honor the
"do not move a fully-visible, unchanged-selection viewport" rule that
`dad2e63a` established for focus-activation. A relayout triggered by an unrelated
cause (transient child surfaces being admitted/rejected/destroyed during typing)
runs `resolveSelection`, whose `ensureSelectionVisible → scrollToReveal` snap-recenters
the viewport to a filling/centered snap even though nothing about the user's
selection or the column layout actually changed.

## Fix direction

Extend the `dad2e63a` principle into the relayout path:

1. In `resolveSelection`, gate the `ensureSelectionVisible` call (and the
   `centeredViewportCorrection` block) on an actual change that justifies a
   recenter — e.g. the selected node changed, the active column changed, the column
   set changed, or a removal shifted visibility. When the selection, active column,
   and columns are all unchanged and the selection is fully visible, skip the
   recenter (no-op), mirroring `revealForFocusActivation`'s `.fullyVisible` early
   return.
2. Alternatively (or additionally), have `ensureSelectionVisible` itself take a
   fully-visible/unchanged-selection fast-path that returns without calling
   `scrollToReveal`, so every `ensureSelectionVisible` caller benefits rather than
   only `resolveSelection`.

The fix must preserve the legitimate recenter cases: genuine selection change,
window arrival/removal that changes visibility, and lone-window centering
(`resetViewportForCenteredLoneWindow`), all of which must still move the viewport.

## Out of scope

- The display-connect column-collapse attribution gap (single-slot audit collapse)
  is a separate finding — see
  `discovery/20260628-relayout-commit-collapses-intermediate-viewport-mutations.md`.
- Snap targeting and fling momentum on `touch_scroll_gesture_end` are intentional
  snap behavior, not this bug.

## References

- Established fully-visible no-op (focus-confirm path):
  `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:158`
  (`revealForFocusActivation`, added by `dad2e63a`).
- Mover (relayout path): `Sources/Nehir/Core/Controller/NiriLayoutHandler.swift:570`
  (`resolveSelection`), `:642` (`ensureSelectionVisible` call),
  `:685` (`centeredViewportCorrection`).
- Underlying recenter: `Sources/Nehir/Core/Layout/Niri/NiriNavigation.swift:173`
  (`ensureSelectionVisible`), `Sources/Nehir/Core/Layout/Niri/NiriLayoutEngine+ViewportCommands.swift:70`
  (`scrollToReveal` `.fullyVisible` → `defaultSnap`).
- Parent plan: `planned/20260625-unrecorded-viewport-offset-mutation-attribution.md`.
