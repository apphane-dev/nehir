# M2 — Reject upstream per-window size-quantum learner — Discovery (rejection memo)

Source upstream commit: [`6eb9ba0`](https://github.com/BarutSRB/OmniWM/commit/6eb9ba0) — "Converge frame writes to a learned per-window size quantum" (0.4.9.8 line, behind "frame writes now converge to a learned per-window size quantum, cutting jitter").
Filed against: `BarutSRB/OmniWM` (upstream of nehir — see `NOTICE.md`).
Scope: decide whether to port the quantum learner into nehir. **Recommendation: reject.**

---

## TL;DR

- **Nehir chose a different, simpler, safer strategy** (commit `3254244f` / #45): **post-write detection and acceptance.** When a `.verificationMismatch` is only a cell-quantization overshoot, nehir accepts the observed snapped frame and refuses to learn a minimum.
- **Upstream `6eb9ba0` is a pre-snap quantum learner**: learn a per-window cell width/height and pre-snap writes to the nearest quantum-aligned size before writing.
- **Verdict:** 🟢 **Reject the port.** Nehir's post-write acceptance is the safer of the two and directly avoids the over-constraint risk the port would re-introduce. This satisfies the minor-candidate acceptance criterion "evidence that existing nehir behavior already covers the upstream case."

## The two strategies compared

| Aspect | Upstream `6eb9ba0` (quantum learner) | Nehir `isCellQuantizationOvershoot` (post-write acceptance) |
| --- | --- | --- |
| Strategy | Pre-snap target to learned quantum before writing | Post-write: detect overshoot, accept observed |
| Per-window state | Learned quantum (cell w/h) | None — stateless per-write detection |
| Effect on solver | Targets become quantum-aligned → risks over-constraining siblings | Solver targets unchanged; observed accepted via `confirmFrameWrite` |
| Convergence model | Writes converge to grid lines | Each write accepted wherever it snapped; no fighting |
| Failure mode | Wrong/stale quantum → persistent mismatch | Overshoot > threshold → false minimum pin (the #45 regression) |

## Nehir's code (verified)

`isCellQuantizationOvershoot` at `Sources/Nehir/Core/Controller/LayoutRefreshController.swift:3296-3313`, threshold `cellQuantizationOvershootThreshold = 32.0` at `:3288`.

The detector requires: overshoot on ≥1 axis, **all** axes within `±32pt`, and origin within `±32pt` (bidirectional snap, no shift). On match: `confirmFrameWrite(observed)` + `focusBorderController.updateFrameHint` + `recordFrameApplyTrace("resizeMin.skipQuantization ...")`, and crucially **no** `setInferredResizeMinimumSize` and **no** relayout (`LayoutRefreshController.swift:3147-3171`).

The code comment at `:3148-3153` states the explicit reason nehir rejected the pre-snap approach:

> pinning it would over-constrain the solver and permanently break uniform fill heights among sibling windows in the same workspace.

Upstream's quantum learner would re-introduce exactly that risk.

## Why reject

1. **Nehir already handles the terminal-jitter case** (`3254244f` / #45) without per-window learned state — less state, fewer stale-state failure modes.
2. **The pre-snap approach fights the app on the solver side** (quantum-aligned targets can disagree with the app's own snap), whereas nehir's accept-the-observed path stops fighting.
3. **Over-constraint risk is the documented reason** nehir's current code refuses to pin a quantum minimum; porting upstream reverses a deliberate design decision.

## Residual gap (test-only, not a port)

The `32.0` threshold (`:3288`) is a magic number with **no test guarding it** and **no derivation** from observed geometry (tuned empirically for #45). Residual risk: a terminal with large cells (≥24pt font, row height ≈36pt) could produce a single-row overshoot >32pt ⇒ misclassified as a real minimum ⇒ false pin ⇒ cascade.

The deliverable is **test coverage** that locks the detector's boundary behavior and documents the threshold's assumption (see the boundary matrix in [`20260618-refused-frame-feedback-characterization.md`](../discovery/20260618-refused-frame-feedback-characterization.md) Gap B.3). Making the threshold derivable/configurable is **optional/defer** pending a real repro.

## Recommendation

- Record this rejection so a reader can see *why* M2 is not ported without re-deriving the comparison.
- Add the boundary tests as part of M1's characterization work.
- Do **not** introduce upstream's quantum learner, per-window learned quantum state, or pre-snap target adjustment.

## Open questions

- If a large-cell-terminal repro ever appears (overshoot >32pt misclassified), should the threshold become derivable from observed per-axis deltas or a settings knob? Defer until a repro exists; the boundary test will catch the regression if it occurs.
