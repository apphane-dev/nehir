# Make workspace-bar window clicks static — No-op decision

Verified against `main` plus the diagnostics branch `gesture-traces` on 2026-07-01
(`a67afc14 Add runtime diagnostics for gesture, navigation, and frame issues`, based on
`07ce4168 Reconcile stale hidden-window live frames`). This investigation covered
**direct window selection from the workspace bar**. It did not change hotkey, command
palette, overview, or workspace-switch animation policy.

---

## Original problem confirmed

Directly clicking a far-away window item in the workspace bar used animated viewport
navigation. On a wide workspace this visibly scrolled through many intermediate columns
even though the user selected an exact target.

The improved navigation diagnostics confirmed that direct bar window clicks were recorded
as `source=workspaceBarWindow` with `requestedMotion=enabled` and
`motionAnimationsEnabled=true`.

Examples from runtime captures:

```text
reason=navigate.window source=workspaceBarWindow fromColumn=0 targetColumn=13 columnDelta=13 motionAnimationsEnabled=true requestedMotion=enabled directSelection=true
reason=navigate.window source=workspaceBarWindow fromColumn=13 targetColumn=0 columnDelta=-13 motionAnimationsEnabled=true requestedMotion=enabled directSelection=true
reason=navigate.window source=workspaceBarWindow fromColumn=4 targetColumn=8 columnDelta=4 motionAnimationsEnabled=true requestedMotion=enabled directSelection=true
```

The source comparison was also correct: `focusWindowFromBar(...)` passed
`source: .workspaceBarWindow`, while the shared `navigateToWindowInternal(...)` path called
`engine.ensureSelectionVisible(... motion: .enabled ...)`.

---

## Attempted implementation and runtime lessons

### Attempt 1 — fully static direct bar-window clicks

The first attempted implementation passed `.disabled` motion for all
`source=workspaceBarWindow` direct window clicks.

Runtime diagnostics showed the expected mechanical result:

```text
source=workspaceBarWindow columnDelta=13 requestedMotion=disabled motionAnimationsEnabled=false
source=workspaceBarWindow columnDelta=-13 requestedMotion=disabled motionAnimationsEnabled=false
lastViewportMutation=animateToOffset.staticFallback
```

However, this degraded adjacent-window selection. Immediate sibling clicks also became
static:

```text
source=workspaceBarWindow columnDelta=1 requestedMotion=disabled motionAnimationsEnabled=false
lastViewportMutation=animateToOffset.staticFallback
```

User feedback: this felt worse, especially when clicking immediate siblings. That invalidated
the blunt “all direct bar window clicks are static” plan.

### Attempt 2 — column-delta threshold

A follow-up heuristic animated immediate siblings and made farther clicks static. That was
rejected as conceptually wrong: the number of columns is not a stable UX unit because monitor
widths, column widths, and workspace layouts vary widely.

Lesson: do **not** base this decision on sibling count or column count.

### Attempt 3 — geometry-based bounded viewport animation

A more general attempt used actual viewport distance:

- compute current and final viewport starts in pixels;
- animate the full transition when the distance fits within a screen-sized budget;
- collapse excess distance and animate only the final screen-sized approach when farther.

Runtime diagnostics confirmed the intended collapse from general geometry into special
cases:

```text
columnDelta=2 requestedMotion=enabled motionPlan=full
columnDelta=1 requestedMotion=enabled motionPlan=full
columnDelta=2 requestedMotion=enabled motionPlan=bounded
columnDelta=-7 requestedMotion=enabled motionPlan=bounded
columnDelta=13 requestedMotion=enabled motionPlan=bounded
```

The important observation is that a `columnDelta=2` click could be either `full` or
`bounded` depending on actual viewport distance, proving the decision was no longer based on
column count.

Even so, user feedback remained that far clicks still had undesirable perceived “windows
flying”. The likely remaining issue is not only viewport spring length; layout/window-frame
animation and visibility changes can still create motion artifacts during direct selection.

---

## Decision

Mark this plan **no-op**.

No workspace-bar window-click behavior change should land from this plan. The current source
tree should keep the existing behavior until a deeper design is chosen.

The rejected approaches are:

1. disable animation for every direct bar-window click;
2. use column/sibling count as the threshold;
3. land the screen-distance bounded viewport animation without also addressing perceived
   window-frame motion.

A future plan should start from the geometry-based observation but explicitly handle visual
motion of windows, not just viewport offset. Candidate directions:

- bound viewport travel by screen distance while suppressing or constraining intermediate
  window-frame animations;
- animate only source/target visible windows and avoid animating offscreen/intermediate
  columns during direct selection;
- design a direct-selection transition distinct from keyboard navigation, preserving spatial
  continuity without showing a long scroll-through.

---

## Validation notes for any future replacement plan

A future fix should be considered valid only when all of these hold:

1. immediate nearby bar-window selections still feel continuous;
2. far direct selections avoid long scroll-through animations;
3. far direct selections also avoid perceived intermediate “windows flying”;
4. diagnostics expose source, requested motion, and the chosen transition plan using geometry
   fields rather than column-count thresholds;
5. workspace item clicks remain governed by workspace navigation policy;
6. command/hotkey navigation still animates unless intentionally changed by a separate plan.

No tests were added for this no-op investigation.
