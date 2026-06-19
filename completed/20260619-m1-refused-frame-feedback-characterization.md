# M1 — Refused-frame feedback characterization tests

**Status:** completed (Gap B landed on `main` as `3bee984e` — "Characterize refused-frame resize-minimum learner")
**Source discovery:** `discovery/20260618-refused-frame-feedback-characterization.md`
**Upstream commit:** `40934c5` — "Feed terminally refused frame sizes back into layout constraints"
**Depends on:** P4 (`patch/p4-frame-write-suppression`) — hard prereq; this branch is based on it.

## TL;DR

Nehir already implements the full refused-frame → constraint feedback loop
upstream `40934c5` introduced. **M1 is not a port.** With P4 landed, the loop
converges. The only required deliverable is **test coverage (Gap B)** for the
untested learner/loop/quantization detector. Optional cascade hardening (Gap E)
is explicitly deferred (roadmap decision #2: land P4 + Gap B first).

## Scope (Gap B only)

- `Sources/Nehir/Core/Controller/LayoutRefreshController.swift` — visibility bump
  of `isCellQuantizationOvershoot(target:observed:)` (`:3451`, currently
  `private`) to `internal` so the boundary matrix is unit-testable via
  `@testable import Nehir`. No behavior change.
- `Tests/NehirTests/ResizeMinimumLearnerTests.swift` — new suite.

### Non-goals

- Do **not** introduce upstream's `AXFrameApplicationLedger` file shape.
- Do **not** implement Gap E (two-stable-observation gate) — deferred.
- Do **not** change learner/quantization behavior; characterization only.

## Current code (verified)

- `LayoutRefreshController.swift:3272` — `shouldObserveResizeMinimumRefusal(entry:)`
  (gate: `layoutReason == .standard` && `hiddenState == nil`).
- `LayoutRefreshController.swift:3278` — `handleResizeMinimumFrameApplyResult(_:workspaceId:)`;
  pins via `setInferredResizeMinimumSize` (`:3330`), pushes to engine
  (`engine.updateWindowConstraints`, `:3326`), force-applies tiled siblings,
  requests `.layoutCommand` refresh when the minimum grew (`:3354`).
- `LayoutRefreshController.swift:3366` — `inferredResizeMinimumSize(for:entry:)`;
  handles `.sizeWriteFailed` and `.verificationMismatch`.
- `LayoutRefreshController.swift:3442` — `cellQuantizationOvershootThreshold = 32.0`.
- `LayoutRefreshController.swift:3451` — `isCellQuantizationOvershoot(target:observed:)`.
  Semantics (re-derived from source): true iff at least one size axis **overshoots**
  (observed > target + 0.5) AND every component — both sizes (via `abs` ≤
  threshold) AND origin x/y (`abs` ≤ threshold) — stays within `32.0`. A pure
  shrink, a pure origin shift, or any axis exceeding `32.0` → false.
- `WindowModel.swift:796` / `:800` — `inferredResizeMinimumSize(for:)` accessor and
  `setInferredResizeMinimumSize(_:for:)` (monotonic `max`-merge upstream).

### Test-injection template (existing)

`Tests/NehirTests/RefreshRoutingTests.swift:3466` injects a `.verificationMismatch`
result via `controller.axManager.frameApplyOverrideForTests = { requests in ... }`
(see also `:3483`). Reuse this shape for Gap B tests #1/#2.

## Tests

New `Tests/NehirTests/ResizeMinimumLearnerTests.swift` (`@testable import Nehir`).

### #1 — `isCellQuantizationOvershootBoundaryMatrix` (pure unit) — SHIPPED FIRST

Direct unit test of the predicate (after the `private`→`internal` bump). Matrix
(target → observed → expected), locking `32.0`:

| Case | target | observed | expected | why |
| --- | --- | --- | --- | --- |
| height overshoot in threshold | 100×100@(0,0) | 100×112@(0,0) | `true` | height overshoots 12 ≤ 32 |
| width overshoot in threshold | 100×100@(0,0) | 131×100@(0,0) | `true` | width overshoots 31 ≤ 32 |
| width overshoot past threshold | 100×100@(0,0) | 133×100@(0,0) | `false` | width overshoots 33 > 32 |
| pure shrink | 100×100@(0,0) | 90×90@(0,0) | `false` | no overshoot axis |
| pure origin shift in threshold | 100×100@(0,0) | 100×100@(33,0) | `false` | no size overshoot |
| origin shift + overshoot | 100×100@(0,0) | 100×112@(12,0) | `true` | overshoot + origin ≤ 32 both axes |
| both axes overshoot in threshold | 100×100@(0,0) | 120×120@(0,0) | `true` | both 20 ≤ 32 |

This also serves as the M2 rejection evidence (`noop/20260618-upstream-size-quantum-rejected.md`).

### #2 — refused frame pins an inferred minimum and the next layout respects it (Gap B, harness)

Drive via `frameApplyAsyncOverrideForTests` returning `.verificationMismatch` with
an observed size that overshoots **past** the 32 pt threshold (so the learner, not
the quant branch, runs). Assert `inferredResizeMinimumSize(for:)` is non-nil and
`>=` the observed size, and that a subsequent relayout respects it (no recompute
of the impossible smaller target — relies on P4 being present in this worktree).

### #3 — cell-quantization overshoot is accepted and does NOT pin a minimum (Gap B, harness)

Drive `.verificationMismatch` with an observed size within the 32 pt threshold on
each axis; assert `inferredResizeMinimumSize(for:)` stays nil (quantization is
absorbed, not learned as a minimum).

## Validation

```bash
swift build
swift test --filter ResizeMinimumLearnerTests
swift test --filter LayoutRefreshControllerTests
swift test --filter RefreshRoutingTests
```

## Risks

- **Visibility bump** (`private`→`internal`) is the only production touch; negligible.
- Tests #2/#3 inject synthetic `AXFrameApplyResult`s via the override hook, which
  bypasses the real racy AX readback — they test loop logic deterministically,
  not the readback race (that residual risk is only mitigated by deferred Gap E).
- Tests #2/#3 depend on P4 being present (this branch is based on P4); without P4
  the convergence assertions are flaky.
