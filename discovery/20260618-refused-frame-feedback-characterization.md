# M1 — Refused frame-size feedback already exists in nehir (characterization + optional hardening) — Discovery

Source upstream commit: [`40934c5`](https://github.com/BarutSRB/OmniWM/commit/40934c5) — "Feed terminally refused frame sizes back into layout constraints" (0.4.9.8 line, behind "apps that flat-out refuse a size … are handled gracefully").
Related: [`20260618-upstream-frame-write-failure-suppression.md`](20260618-upstream-frame-write-failure-suppression.md) (P4), [`20260614-ax-frame-write-verification-race.md`](20260614-ax-frame-write-verification-race.md) (readback race / Option D), [`20260616-omniwm-403-…`](20260616-omniwm-403-frame-write-race-min-size-suppression.md).

Scope: re-evaluate whether M1 is a *port* after direct code inspection. **It is not.** This doc records the finding and scopes the actual remaining work.

---

## TL;DR

- **Correction to the earlier minor-candidates framing: nehir already implements the full refused-frame → constraint feedback loop that upstream `40934c5` introduced.** The dataflow upstream adds — refusal observed → extract minimum → store per-window constraint → push to solver → schedule relayout → solver respects constraint — exists end-to-end in nehir today.
- **The remaining #403 thrash loop is the P4 suppression gap**, not a missing feedback path. With P4 landed, the loop converges via the existing learner.
- **Verdict:** 🟢 Not a port. Do **not** introduce upstream's `AXFrameApplicationLedger` file shape. The actual M1 work is: (a) test coverage for the untested learner/loop, (b) optional cascade hardening (require two stable oversized observations before pinning), (c) sequence after P4.

## The dataflow, verified end-to-end in nehir

| Stage | Upstream file shape | Nehir site (verified 2026-06-18) | Status |
| --- | --- | --- | --- |
| Terminal refusal observed | `AXFrameApplicationLedger` | `AXManager.handleFrameApplyResults` — `Sources/Nehir/Core/Ax/AXManager.swift:804-866`; failure recorded `:839`; terminal observer notified on exhausted retry `:848` | ✅ present |
| Refusal routed to learner | `AXManager` → `LayoutRefreshController` | Terminal observer registered on the probe path: `LayoutRefreshController.swift:3668-3676` (`applyFramesParallel(..., terminalObserver: handleResizeMinimumFrameApplyResult)`) | ✅ present |
| Extract observed minimum | (upstream internals) | `inferredResizeMinimumSize(for:result:)` — `LayoutRefreshController.swift:3212-3256` (handles `.sizeWriteFailed` and `.verificationMismatch`) | ✅ present |
| Store per-window constraint | `WindowModel` | `WorkspaceManager.setInferredResizeMinimumSize` → `WindowModel.Entry.inferredResizeMinimumSize` (`WindowModel.swift:189-191`, accessor `:803-814`, monotonic `max`-merge) | ✅ present |
| Push to solver | `LayoutRefreshController` | `engine.updateWindowConstraints(for:constraints:)` + `clampColumnWidthToBounds` (`NiriLayoutEngine+Windows.swift:83-99`); re-merged into every snapshot `LayoutRefreshController.swift:512-516` | ✅ present |
| Schedule relayout | `RefreshReason` | `requestRefresh(reason: .layoutCommand, ...)` (`LayoutRefreshController.swift:3196-3198`) + `forceApplyNextFrame` for tiled siblings (`:3192-3194`) | ✅ present |
| Solver respects constraint | solver | `resolveSpan` / `widthBounds` / `clampHeight` consume `node.constraints.minSize` (`NiriNode.swift:551`, `:170+`); `buildWindowSnapshots` merges inferred min into `mergedConstraints.minSize` (`LayoutRefreshController.swift:482-540`) | ✅ present |

This is independently confirmed by `docs/ARCHITECTURE.md:377`, which documents the learner, and by the noop `20260616-omniwm-384-respect-window-min-size-in-niri-column-width.md` framing: *"#403's loop is fueled by a constraint-discovery transient on early layouts … closed by the resize-minimum learner after the first failed write — not by a missing propagation gap."*

## The genuine remaining gaps

### Gap B — Test coverage (required)

Zero tests cover the learner, the loop, or the quantization detector. `grep` for `handleResizeMinimumFrameApplyResult|inferredResizeMinimum|isCellQuantizationOvershoot|setInferredResizeMinimumSize` across `Tests/` returns no matches. `NiriLayoutEngineTests` set `window.constraints` directly but never exercise the *learning* path. **This is the primary M1 deliverable.**

### Gap E — Cascade hardening (recommended)

`20260614-ax-frame-write-verification-race.md` §3a/§6.1 (Option D) flags that a single racy oversized readback can poison solver constraints via the learner and force a workspace-wide relayout. Recommended fix: require **two stable oversized observations** before pinning. The existing bounded retry (`retryBudgetByWindowId` seeded to 1, `AXManager.swift:623`) provides partial second-observation filtering for the probe path (the learner only fires after retry exhausts), but the gate is implicit and untested, and does not cover both-readbacks-racy-under-churn.

### Gap A — Futile-retry skip (optional/defer)

The retry path (`AXManager.swift:855-866`) re-enqueues the identical refused target. Skipping the retry when a learned/inferred minimum already exceeds the target would save one redundant write. Defer: retry budget is 1, and the check crosses the `AXManager` ↔ `LayoutRefreshController` boundary (AXManager has no access to `inferredResizeMinimumSize`). Cost/benefit unfavorable.

### Gap C — Stickiness (residual risk, not a task)

`setInferredResizeMinimumSize` (`WindowModel.swift:803-814`) is monotonic (only grows) with no TTL/decay (unlike `cachedConstraints`, 5 s TTL, `:779`). If an app's effective minimum shrinks, nehir won't unlearn. Document; no implementation unless a real repro appears.

### Gap D — Probe-path coverage (residual risk, not a task)

`shouldObserveResizeMinimumRefusal` (`LayoutRefreshController.swift:3126-3131`) gates the learner to `layoutReason == .standard` && `hiddenState == nil`. The `forceApply` and `forceNativeFullscreenRestoreApply` paths bypass the probe and never feed the learner. For native fullscreen this is intentional. Documented explicit non-coverage.

## Recommendation

**Do not port upstream's file shape.** The loop already exists. Deliver:

1. **Characterization tests (Gap B):**
   - Refused frame pins an inferred minimum and the next layout respects it — drive via `frameApplyAsyncOverrideForTests` returning `.verificationMismatch` with an oversized observed size (overshoot > the cell-quantization threshold so the learner, not the quant branch, runs); assert `inferredResizeMinimumSize(for:)` non-nil and `>=` observed, and that a subsequent snapshot build / emitted `frameChange` respects the minimum.
   - Cell-quantization overshoot is accepted and does **not** pin a minimum (this is also the M2 evidence test — see `20260618-upstream-size-quantum-rejected.md`).
   - `isCellQuantizationOvershoot` boundary matrix (pure unit): height overshoot 12pt → `true`; width overshoot 31pt → `true`; 33pt → `false`; pure shrink → `false`; origin shift 33pt → `false`; origin shift 12pt + overshoot → `true`; both axes 20pt → `true`. Locks the `32.0` threshold (`LayoutRefreshController.swift:3288`).

2. **Optional cascade hardening (Gap E):** add `pendingResizeMinimumCandidate` + `consecutiveOversizedMismatchCount` to `WindowModel.Entry` (reset at all sites that clear `inferredResizeMinimumSize`: `:409`, `:446`, `:470`, `:588`, `:720`, `:824`); in `handleResizeMinimumFrameApplyResult`, pin only on the second stable observation. Applies to both `.verificationMismatch` and `.sizeWriteFailed`. Test the gate.

## Sequencing

**P4 is a hard prerequisite for the Gap B "no recompute of impossible target" assertions.** Without P4 the snap-back notification triggers an unsuppressed relayout masking convergence. Sequence: **P4 → M1 Gap B → (optional) M1 Gap E.**

## Suggested validation

```bash
swift test --filter LayoutRefreshControllerTests
swift test --filter ResizeMinimumLearnerTests   # if a dedicated suite is created
mise run test                                   # full suite (CI parity)
mise run changeset:check
```

## Risks

- **P4 not yet landed** in this worktree — Gap B/E assertions that depend on convergence are flaky/failing until P4 lands.
- **Test determinism** — the learner's real input is a racy AX readback (structurally untestable in CI). All proposed tests inject synthetic `AXFrameApplyResult`s via `frameApplyAsyncOverrideForTests`, which bypasses the real readback. This tests the *loop logic* deterministically; the residual readback-race risk is only mitigated by Gap E, not eliminated.
- **Candidate-state reset completeness** — the new Gap E fields must be cleared at all seven `inferredResizeMinimumSize` reset sites or stale candidates suppress pinning across workspace/replacement transitions.
