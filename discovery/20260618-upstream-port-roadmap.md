# Upstream 0.4.9.7–0.4.9.9 Port Roadmap — Patch / Minor / Major split

Source upstream range: `BarutSRB/OmniWM` after `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce` through current upstream `main` observed on 2026-06-18.

This is an index for fan-out work. It intentionally separates **small patch fixes**, **minor/runtime hardening**, and **major architecture/product decisions** so implementation agents can work independently without importing upstream's whole post-divergence runtime rewrite.

**Per-cluster discovery docs** (canonical — read these, not the combined summaries):

- Patch track:
  - P1 — [`20260618-upstream-rescan-eviction-hysteresis.md`](20260618-upstream-rescan-eviction-hysteresis.md)
  - P2 — [`20260618-upstream-refresh-coalescing.md`](20260618-upstream-refresh-coalescing.md)
  - P3 — [`20260618-upstream-monitor-orientation-override.md`](20260618-upstream-monitor-orientation-override.md)
  - P4 — [`20260618-upstream-frame-write-failure-suppression.md`](20260618-upstream-frame-write-failure-suppression.md)
- Minor track:
  - M1 — [`20260618-refused-frame-feedback-characterization.md`](20260618-refused-frame-feedback-characterization.md)
  - M2 — [`noop/20260618-upstream-size-quantum-rejected.md`](noop/20260618-upstream-size-quantum-rejected.md) (rejection)
  - M3 — [`20260618-focus-request-origin-ffm-cursor-warp.md`](20260618-focus-request-origin-ffm-cursor-warp.md)
  - M4 Stage 1 — [`20260618-displays-separate-spaces-mode-detection.md`](20260618-displays-separate-spaces-mode-detection.md)
  - M4 Stage 2 — [`20260618-space-topology-eviction-exemption.md`](20260618-space-topology-eviction-exemption.md)
  - M5 — [`20260618-raw-multitouch-gesture-source.md`](20260618-raw-multitouch-gesture-source.md)
  - M6 — [`20260618-stale-session-selection-revision-guard.md`](20260618-stale-session-selection-revision-guard.md)
- Major track:
  - Analysis — [`20260618-worldstore-pure-engine-reuse.md`](20260618-worldstore-pure-engine-reuse.md)
  - A1 spike — [`20260618-pure-niri-engine-extraction.md`](20260618-pure-niri-engine-extraction.md)

**Context / superseded:**

- Separate Spaces / arrangement analysis: [`20260618-separate-spaces-and-monitor-arrangement.md`](20260618-separate-spaces-and-monitor-arrangement.md)
- Fanout synthesis (sequencing for agents): [`20260618-upstream-port-fanout-synthesis.md`](20260618-upstream-port-fanout-synthesis.md)
- ⚠️ Superseded combined summaries (kept for history): [`20260618-upstream-port-patch-fixes.md`](20260618-upstream-port-patch-fixes.md), [`20260618-upstream-port-minor-candidates.md`](20260618-upstream-port-minor-candidates.md)

## Executive summary

Upstream's post-divergence history is not one thing. It contains:

1. **Patch-level bug fixes** that match nehir code almost exactly and can be delivered as small changesets.
2. **Minor ports** where the concept is valuable, but nehir has different file boundaries or a partial local approach.
3. **Major architecture/product work** where upstream's WorldStore/EventIntake/IntentLedger/Secure topology rewrite is a direction to learn from, not a diff to transplant.

## Patch track — deliverable as small bug-fix changesets

See the patch doc for details and exact file references. Recommended first fan-out:

| ID | Upstream source | Nehir location | Deliverability |
| --- | --- | --- | --- |
| P1 | `ba9d1e2` Require two consecutive rescan misses | `LayoutRefreshController.swift:1424` | one-line behavior change + tests |
| P2 | `631caa9` Coalesce same-kind refreshes without cancelling | `LayoutRefreshController.swift:1636-1651` | two-case scheduling fix + tests |
| P3 | `8338d97` Preserve monitor orientation override | `NiriMonitor.swift:50`, `IPCQueryRouter.swift:415` | small direct port + IPC test |
| P4 | closed Hiro PR #403 concept | `AXManager.shouldSuppressFrameChangeRelayout` | one-branch fix + unit tests |

These can be implemented in parallel if each subagent owns one ID.

## Minor track — valuable but requires adaptation

See the minor doc for details. Recommended fan-out:

| ID | Concern | Why minor, not patch |
| --- | --- | --- |
| M1 | Refused frame-size feedback / min-size constraints | upstream uses `AXFrameApplicationLedger`; nehir has inline `AXManager`/`LayoutRefreshController` learner |
| M2 | Learned per-window size quantum | overlaps nehir's terminal/cell-quantization fixes; compare before port |
| M3 | Focus request origin for FFM cursor-warp policy | concept clean; touches focus lifecycle and mouse-warp behavior |
| M4 | Space mode detection + diagnostics | product-sensitive; nehir has partial SkyLight Spaces helper but no topology/runtime mode model |
| M5 | Raw multitouch source for trackpad gestures | potentially useful, but not a direct fix for current non-repro `nehir-53` |

## Major track — architecture/product design, not cherry-pick work

See the major doc. Main idea:

> Do not port upstream `WorldStore` wholesale. Extract a nehir-shaped pure model/reducer/effect-plan core that can run both real windows and fake onboarding/demo windows.

Major fan-out areas:

| ID | Concern | Deliverable |
| --- | --- | --- |
| A1 | Pure Niri model shared by runtime and onboarding | design + extraction plan from `InteractiveMoveDemo.MoveDemoModel` and real Niri engine |
| A2 | Effect-plan interpreter boundary | design real AX interpreter vs SwiftUI fake interpreter |
| A3 | Runtime revision/sequence stamps | plan to drop stale async layout/focus/session effects |
| A4 | Optional focus intent ledger | nehir-sized replacement for upstream's full `IntentLedger`/`DeadlineWheel` |
| A5 | Space-aware runtime mode | decide if nehir supports macOS Spaces coexistence or keeps it diagnostic/advisory |

## Why not wholesale WorldStore?

Upstream's WorldStore cluster is a replacement runtime, not a patch stack. It moves ownership of window model, focus state, viewport/session state, layout engines, surface derivation, event ingress, deadlines, and topology into one store. That direction has good ideas, but importing it directly would also import upstream product assumptions that nehir intentionally removed or reshaped.

Nehir already has a lighter reconcile vocabulary:

- `RuntimeStore`
- `ReconcileTxn`
- `Planner`
- `StateReducer`
- `InvariantChecks`
- `FocusPolicyEngine`

The major work should build on those, not delete them in favor of upstream's runtime shape.

## Subagent execution guidance

For implementation fan-out, hand each subagent one ID from the patch/minor/major docs. Require each subagent to return:

1. Changed files.
2. Tests added/updated.
3. Commands run.
4. Whether the upstream diff was ported directly, concept-ported, or rejected.
5. Residual risks.

Do **not** ask one subagent to port the full upstream range. The range is too heterogeneous and includes intentionally removed features.
