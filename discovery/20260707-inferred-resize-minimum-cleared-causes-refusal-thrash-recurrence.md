# Discovery: learned resize-minimum is cleared by identity-preserving lifecycle events, so min-width apps re-fight and re-thrash on the next animated resize

Groom 2026-07-07: resolved — landed on main `3afeec81` ("Keep learned window minimum size across float, fullscreen, and rekey"), covering all three identity-preserving clearing sites this discovery identified; see `completed/20260707-persist-inferred-resize-minimum-across-lifecycle.md`. The remaining `inferredResizeMinimumSize = nil` sites (`registerWindow`, cross-token `rekeyWindow`) are intentional identity-destroying clears, out of scope by design.

Status: root cause found and source-confirmed. This is a follow-up to the M1
refused-frame-feedback work
(`completed/20260619-m1-refused-frame-feedback-characterization.md`,
`discovery/20260618-refused-frame-feedback-characterization.md`). That work
concluded the refusal→learn→clamp loop "converges via the existing learner" and
filed **Gap C (learned-minimum non-persistence / stickiness)** as a *residual
risk, not a task, "no implementation unless a real repro appears."* This
discovery is that repro: the learned minimum does **not** persist across routine
window-lifecycle events within a single session, so the refusal-thrash the M1
work believed was a one-time-per-window cost **recurs**.

This is a *different* dance from
`discovery/20260706-summon-right-cross-display-size-dance.md`. That one is a
cross-monitor size-reconciliation flash during a Summon Right reveal. This one is
a window visibly *fighting/jittering its own width* during an animated
proportional relayout, on a single display, because the WM keeps re-writing a
width below the app's true minimum until it re-learns the minimum it already
knew.

All source references verified against `main` @ `4f9e5682` on 2026-07-07.
Re-verify before editing; line numbers drift. Paths are repository-relative.

## Summary

An app with a hard minimum window width (here: Helium, `net.imput.helium`, real
minimum width `740`) is placed in a proportional multi-column layout that assigns
it a column narrower than `740`. During the animated relayout the spring drives
the target width below `740`; the app refuses every sub-minimum write; each
refusal produces a `failed reason=verificationMismatch` + `retry-scheduled` +
forced retry that also fails — i.e. a burst of AX frame writes per animation tick
— until the resize-minimum learner fires and pins `minimum=740`, after which the
column is clamped and only the x-position keeps animating.

The learner works. The bug is that the pinned minimum is **thrown away** by
ordinary lifecycle churn (AX-ref self-rekey, float/unfloat, native-fullscreen
enter/exit) that does not change the app's physical minimum. Once the pin is
cleared, the next animated shrink re-runs the whole refusal-thrash and re-learns
the same `740`. This is the repeated "window dancing" the user observes,
especially around moves/relayouts that involve differently sized displays (where
proportional column widths differ and a window is more likely to be re-assigned a
sub-minimum width).

## Topology (inlined)

```text
ID(displayId: 1) isMain=true frame=(0.0, 0.0, 2056.0, 1329.0) visibleFrame=(0.0, 0.0, 2056.0, 1290.0)  Built-in Retina Display
ID(displayId: 2)              frame=(-1171.0, 1329.0, 2560.0, 1440.0) visibleFrame=(-1171.0, 1329.0, 2560.0, 1410.0) DELL P2423D
```

Window `215` is a Helium window (`net.imput.helium`, pid `28651`) tiled on the
built-in display. Its physically enforced minimum width is `740` (the value the
app clamps to and the value the learner ultimately records).

## Evidence (inlined)

### 1. The refusal-thrash, one representative animation tick

The spring is walking window `215`'s target width down (…`709.5 → 708.5 → 708 →
707.5`…), all below the app's `740` minimum. Each tick:

```text
enqueue id=215 target={{679.0,7.0},{709.5,1251.0}} cached={{682.0,7.0},{740.0,1251.0}} recentFailure=verificationMismatch force=false retry=false
failed  id=215 target={{679.0,7.0},{709.5,1251.0}} observed={{679.0,7.0},{740.0,1251.0}} hint={{682.0,7.0},{740.0,1251.0}} reason=verificationMismatch sizeError=0 positionError=0 order=sizeThenPosition
retry-scheduled id=215 target={{679.0,7.0},{709.5,1251.0}} remaining=0
enqueue id=215 target={{679.0,7.0},{709.5,1251.0}} ... recentFailure=verificationMismatch force=true retry=true
failed  id=215 target={{678.5,7.0},{708.5,1251.0}} observed={{678.0,7.0},{740.0,1251.0}} ... reason=verificationMismatch
```

`observed` width stays pinned at the app's real `740` while the WM keeps trying
`709.5 / 708.5 / 708 / 707.5`. The app never yields; the WM keeps writing and
retrying — visible thrash.

### 2. The learner then pins the minimum and the thrash stops

```text
resizeMin.learn id=215 source=refusal target=(677,7 708x1251) observed=(677,7 740x1251) minimum=740.0x100.0
enqueue id=215 target={{677.0,7.0},{740.0,1251.0}} ... force=true retry=false
confirmed id=215 target={{677.0,7.0},{740.0,1251.0}} observed={{677.0,7.0},{740.0,1251.0}} ...
```

After the learn, the width is fixed at `740` (`force=true` write confirms) and
subsequent ticks only move x (`resizeMin.skipQuantization id=215 …`). Consistent
refusal across all seven sub-minimum writes → this is a real physical minimum,
not a racy oversized readback (M1 Gap E does not apply here).

### 3. The pin does not persist within the same session

Runtime-state counter `inferredResizeMinimums` (count of managed entries with a
non-nil `inferredResizeMinimumSize`) over four consecutive same-session captures,
chronologically (WM not restarted; ~90 s span):

| capture (start) | `inferredResizeMinimums` | `cachedConstraints` | `failed verificationMismatch` in window |
| --- | --- | --- | --- |
| 23:28 | 0 | 0 | 5 (thrash, pre-learn) |
| 23:29:00 | **1** (learned `215`→`740`) | 4 | 7 (thrash, then `resizeMin.learn` fires) |
| 23:29:xx (later) | **0** (pin gone) | 4 | 0 |
| 23:31 | 0 | 3 | 0 |

The pin went `0 → 1 → 0` **while `cachedConstraints` stayed at 4**. Two distinct
refusal-thrash episodes on the same window (5 failures, then 7 failures) were
captured, separated by a successful learn — the recurrence itself. With the pin
back at `0`, the next animated shrink of `215` will thrash a third time.

## Source confirmation

### The store cannot decay on its own — a clear was executed

`Sources/Nehir/Core/Workspace/WindowModel.swift`

- `:809-824` `setInferredResizeMinimumSize` only ever **max-merges** (monotonic
  grow); there is no TTL/decay (unlike `cachedConstraints`, which has a time
  stamp). So `inferredResizeMinimums` can only drop when some site explicitly
  assigns `entry.inferredResizeMinimumSize = nil`.

### The clear sites, and which one matches the counter behaviour

`Sources/Nehir/Core/Workspace/WindowModel.swift` — every explicit clear:

- `:420` `registerWindow(...)` when `ruleEffects` change — clears **both**
  `cachedConstraints` *and* `inferredResizeMinimumSize`.
- `:457` `rekeyWindow(...)` **self-rekey branch** (`oldToken == newToken`, i.e. a
  pure AX-ref refresh with identical window identity) — clears **both**.
- `:481` `rekeyWindow(...)` cross-token branch — clears **both**.
- `:597` `setMode(...)` when the new mode is not `.tiling` (float / scratchpad) —
  clears **only** `inferredResizeMinimumSize`.
- `:729` `setLayoutReason(...)` when the reason is not `.standard` (native
  fullscreen etc.) — clears **only** `inferredResizeMinimumSize`.

The observed transition — `inferredResizeMinimums` `1 → 0` **with
`cachedConstraints` unchanged at 4** — rules out the sites that also clear
`cachedConstraints` (`:420`, `:457`, `:481`) and points at the two sites that
clear the inferred minimum *alone*: `setMode` → non-tiling (`:597`) and
`setLayoutReason` → non-standard (`:729`). A transient float or native-fullscreen
flip of window `215` during the intervening cross-display move/relayout is the
most consistent trigger. (A self-rekey at `:457` is also latent and equally
wrong; it just would have shown up as a `cachedConstraints` dip too.)

### Why every one of these clears is unjustified for this field

The learner records a **physical, app-enforced minimum window size** — the size
the app *refuses to go below*. That is an invariant of the app/window, not of:

- the AX element reference (self-rekey `:457` refreshes the handle, same app,
  same physical minimum);
- the tiling vs. floating mode (`:597` — a floated window still has the same
  physical minimum when it returns to tiling);
- the layout reason (`:729` — exiting native fullscreen returns the same window
  with the same physical minimum).

Clearing it on these events conflates the *physical minimum* with the
*time-sensitive `cachedConstraints`*, which legitimately should be re-read after
such transitions. The learner and counter live at:

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3954-3986`
  (`handleResizeMinimumFrameApplyResult` — pins via
  `setInferredResizeMinimumSize`, pushes to the solver, force-applies tiled
  siblings, requests a relayout).
- `Sources/Nehir/Core/Workspace/WorkspaceManager.swift:381` — the
  `inferredResizeMinimums` counter used in the evidence above.

### Why the solver assigns a sub-minimum width in the first place

The proportional layout assigns column widths before the physical minimum is
known; the solver can only clamp to a minimum it has (`clampColumnWidthToBounds`
consumes `node.constraints.minSize`). Cross-display moves make this more likely:
differently sized displays yield different proportional column widths, so a
window re-assigned to a narrower proportional slot re-encounters the
below-minimum condition — exactly when the pin has just been cleared. See the
noop `noop/20260616-omniwm-384-respect-window-min-size-in-niri-column-width.md`
for the pre-learn transient framing.

## Verdict

Actionable. Upgrades M1 **Gap C** from "residual risk, no repro" to a confirmed,
same-session repro. The fix is to stop discarding a physical-minimum invariant on
identity-preserving lifecycle events. See
`planned/20260707-persist-inferred-resize-minimum-across-lifecycle.md`.

## Risks / watch-outs

- **Stickiness (the reason the clears may have existed).** The inferred minimum
  is monotonic with no decay. Keeping it across more events increases exposure to
  M1 Gap C: if an app's *real* minimum ever shrinks, a stale-too-large pin
  over-constrains the column. This is a pre-existing property, not introduced by
  the fix; if it becomes real, the principled answer is a bounded TTL/decay on
  the minimum, not incidental clears on unrelated lifecycle events.
- **Cross-token rekey (`:481`).** A genuinely different window id (structural
  replacement across an app relaunch) is the one clear with a defensible
  identity-changed rationale. Keeping the pin there is beneficial (same app, same
  physical minimum) but is a larger behavioural claim; treat it as optional and
  keep the first fix to the identity-preserving sites (`:457`, `:597`, `:729`).
- **Acceptance is runtime-visual, not test-first** (per `AGENTS.md`). Do not add
  or edit tests until the user confirms the fix on a real repro: learn a
  min-width app's minimum once, then float/unfloat it, toggle native fullscreen,
  and trigger an AX-ref refresh — `inferredResizeMinimums` must stay `>= 1` and
  the next animated shrink must produce **no** second `resizeMin.learn` and **no**
  `verificationMismatch` refusal burst.
