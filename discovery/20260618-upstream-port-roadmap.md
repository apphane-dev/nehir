# Upstream 0.4.9.7–0.4.9.9 Port Roadmap — canonical index

Source upstream range: `BarutSRB/OmniWM` after `ee9b4f0707668d43f73e4af8c9a4f3581b8c11ce` through current upstream `main` observed on 2026-06-18.

**This doc is the single source of truth** for tier, verdict, deliverability, sequencing, and status of every port candidate. Per-cluster discovery docs carry the detail; this carries the priority/categorization.

Counting note: this roadmap has 13 rows because M4 is split into Stage 1/Stage 2 and A2–A5 are grouped into one architecture row. M2 is retained as a decided-no row so the upstream candidate is accounted for.

## Per-cluster discovery docs (canonical)

- Patch track:
  - P1 — [`20260618-upstream-rescan-eviction-hysteresis.md`](20260618-upstream-rescan-eviction-hysteresis.md)
  - P2 — [`20260618-upstream-refresh-coalescing.md`](20260618-upstream-refresh-coalescing.md)
  - P3 — [`20260618-upstream-monitor-orientation-override.md`](20260618-upstream-monitor-orientation-override.md)
  - P4 — [`20260618-upstream-frame-write-failure-suppression.md`](20260618-upstream-frame-write-failure-suppression.md)
- Minor track:
  - M1 — [`20260618-refused-frame-feedback-characterization.md`](20260618-refused-frame-feedback-characterization.md)
  - M2 — [`noop/20260618-upstream-size-quantum-rejected.md`](../noop/20260618-upstream-size-quantum-rejected.md) (rejected)
  - M3 — [`20260618-focus-request-origin-ffm-cursor-warp.md`](20260618-focus-request-origin-ffm-cursor-warp.md)
  - M4 Stage 1 — [`20260618-displays-separate-spaces-mode-detection.md`](20260618-displays-separate-spaces-mode-detection.md)
  - M4 Stage 2 — [`20260618-space-topology-eviction-exemption.md`](20260618-space-topology-eviction-exemption.md)
  - M5 — [`20260618-raw-multitouch-gesture-source.md`](20260618-raw-multitouch-gesture-source.md)
  - M6 — [`20260618-stale-session-selection-revision-guard.md`](20260618-stale-session-selection-revision-guard.md)
- Major track:
  - Analysis (A1–A5 framing) — [`20260618-worldstore-pure-engine-reuse.md`](20260618-worldstore-pure-engine-reuse.md)
  - A1 spike — [`20260618-pure-niri-engine-extraction.md`](20260618-pure-niri-engine-extraction.md)

**Context:**

- Separate Spaces / arrangement analysis: [`20260618-separate-spaces-and-monitor-arrangement.md`](20260618-separate-spaces-and-monitor-arrangement.md)
- Historical fanout log (superseded by this doc for sequencing): [`20260618-upstream-port-fanout-synthesis.md`](20260618-upstream-port-fanout-synthesis.md)
- ⚠️ Superseded combined summaries (kept for history): [`20260618-upstream-port-patch-fixes.md`](20260618-upstream-port-patch-fixes.md), [`20260618-upstream-port-minor-candidates.md`](20260618-upstream-port-minor-candidates.md)

## Canonical table

Verdict legend: 🔴 Open/Applies (defect present, fix indicated) · 🟡 Conditional (applies with nuance / investigate / product-gated / architecture spike) · 🟢 Not a port (already exists / rejected / noop).
Status: `not started` · `planned` · `in progress` · `landed` · `decided-no` · `deferred`.

| Tier | ID | Title | Verdict | Deliverability | Depends on | Status | Doc |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Patch | P1 | Require two consecutive rescan misses before eviction | 🔴 | one-token port + 2 controller-test rewrites | — | landed | [discovery](20260618-upstream-rescan-eviction-hysteresis.md) · [completed](../completed/20260619-p1-rescan-eviction-hysteresis.md) |
| Patch | P2 | Coalesce same-kind refreshes without cancelling | 🔴 | two-case switch edit + 3 routing tests | — | landed | [discovery](20260618-upstream-refresh-coalescing.md) · [completed](../completed/20260619-p2-refresh-coalescing.md) |
| Patch | P3 | Preserve monitor orientation overrides + IPC effective orientation | 🟡 | small direct port; leaf = defensive, IPC = observable | — | landed | [discovery](20260618-upstream-monitor-orientation-override.md) · [completed](../completed/20260619-p3-monitor-orientation-override.md) |
| Patch | P4 | Suppress frame-change relayout after a recent AX write failure | 🔴 | one-branch fix + 2 AXManager tests | — | landed | [discovery](20260618-upstream-frame-write-failure-suppression.md) · [completed](../completed/20260619-p4-frame-write-suppression.md) |
| Minor | M1 | Refused-frame-size feedback → constraints | 🟢 not a port — **loop already exists** | characterization tests + optional 2-stable-observation hardening | **P4** (hard prereq for assertions) | landed | [discovery](20260618-refused-frame-feedback-characterization.md) · [completed](../completed/20260619-m1-refused-frame-feedback-characterization.md) |
| Minor | M2 | Learned per-window size quantum | 🟢 rejected | noop/rejection memo only | — | decided-no | [noop](../noop/20260618-upstream-size-quantum-rejected.md) |
| Minor | M3 | Focus-request origin for FFM cursor-warp | 🟡 | narrow FFM warp gate using existing `isFFM`; origin model deferred | — (soft sequencing before M6) | planned | [discovery](20260618-focus-request-origin-ffm-cursor-warp.md) · [plan](../planned/20260619-m3-ffm-cursor-warp-suppression.md) |
| Minor | M4-S1 | Displays-have-separate-Spaces mode detection + diagnostics | 🟡 | diagnostics-only; no layout/startup change | — | planned | [discovery](20260618-displays-separate-spaces-mode-detection.md) · [plan](../planned/20260619-m4s1-displays-separate-spaces-detection.md) |
| Minor | M4-S2 | Minimal Space topology eviction exemption | 🟡 | small value-type topology; OFF = true no-op; product-gated | **M4-S1** | not started | [M4-S2](20260618-space-topology-eviction-exemption.md) |
| Minor | M5 | Raw MultitouchSupport gesture source | 🟡 | **investigation first**; flag-gated prototype only after abort-trace | abort-trace (M5 step 1) | not started | [M5](20260618-raw-multitouch-gesture-source.md) |
| Minor | M6 | Cross-workspace stale focus/session revision guard | 🔴 | revision counter + apply guard + cross-ws clear; **high callsite risk** | **M3** (recommended sequence) | not started | [M6](20260618-stale-session-selection-revision-guard.md) |
| Major | A1 | Pure Niri model shared by runtime + onboarding (first spike) | 🟡 spike | pure addition + agreement tests first; no runtime/demo refactor yet | — (prereq for A2) | not started | [A1](20260618-pure-niri-engine-extraction.md) |
| Major | A2–A5 | Effect-plan boundary; revision stamps; focus ledger; Space runtime mode | 🟡 | framed in analysis doc, **no standalone discovery doc yet** | A1 | deferred | [analysis](20260618-worldstore-pure-engine-reuse.md) |

## Sequencing (DAG)

Dependency edges (→ = "lands before") and the recommended batches. The patch batch is already landed; remaining arrows are sequencing guidance unless noted as a hard prerequisite.

```
Patch (batch 1):
  P3   P4   P1   P2          (landed)

Frame sizing (batch 2):
  P4 ──▶ M1   (landed; M2 is decided-no and its boundary tests folded into M1)

Focus (batch 3, split):
  M3 ──▶ M6   (recommended review sequence; narrowed M3 does not supply M6's origin/revision model)

Spaces (batch 4, staged):
  M4-S1 ──▶ M4-S2

Gesture (batch 5):
  M5-step1 (abort trace) ──▶ M5-prototype (flag-gated, optional)

Architecture (parallel from the start):
  A1 ──▶ A2 ──▶ (A3 / A4 / A5, deferred)
```

**Batch 1 — safe patch cluster**: landed.
- P3, P4, P1, and P2 are on `main`. P4 remains the prerequisite behind M1's completed assertions.

**Batch 2 — frame-sizing hardening**: landed / decided.
- M1 characterization tests landed; M2 rejection memo is written. Optional 2-stable-observation hardening remains deferred. Do **not** port upstream `AXFrameApplicationLedger` or learned quantum.

**Batch 3 — focus work split:**
- M3 first (narrow FFM warp gate using the existing confirm-time `isFFM` signal). M6 after M3 for review sequencing; M6 must add its own revision/origin model if needed (the narrowed M3 plan intentionally does **not** add `ManagedFocusOrigin`).

**Batch 4 — Spaces mode (staged):**
- M4-S1 (diagnostics only). M4-S2 only after S1 is reviewed and manual mode detection works on a real host.

**Batch 5 — gesture input:**
- M5 step 1 (abort/skip tracing) as a standalone hardening patch first. Raw MultitouchSupport prototype only behind internal flags, only if abort traces + a reporter-side failing trace justify it.

**Architecture — A1 only:**
- Pure models/reducer/invariants + agreement tests (expose the 3 real/demo divergences). Do **not** refactor onboarding or runtime until A1 agreement tests are green and onboarding visuals are unchanged. A2 gated on A1.

## Decisions captured (recommendations; confirm before assigning writers)

1. **Patch PR shape:** split P3 and P4; P1/P2 together is acceptable (both touch refresh tests).
2. **M1 hardening:** do not approve the optional 2-stable-observation gate now — first land P4 + M1 characterization tests.
3. **M4-S1 mouse warp:** advisory copy only; do **not** auto-disable `MouseWarpHandler` when Separate Spaces is ON.
4. **M3 scope:** narrow FFM cursor-warp suppression only, using the existing confirm-time `isFFM` signal. Do **not** add `ManagedFocusOrigin` or the hiro-317 `createdAt`/grace-window in M3; those are deferred to A4/M6.
5. **A1 scope:** pure addition + agreement tests first; onboarding refactor only after the 3 divergences are decided.
6. **WorldStore:** do **not** port upstream `WorldStore`/`EventIntake`/`IntentLedger`/`DeadlineWheel`/`SurfaceReconciler` wholesale — see "Why not wholesale WorldStore" below and the analysis doc.

## Product-mode decision (Separate Spaces)

From the maintainer manual test (`20260618-separate-spaces-and-monitor-arrangement.md`):

- **Separate Spaces OFF:** keep the current vertical-arrangement diagnostic; allow nehir-controlled mouse warp. (Shared-desktop parking bleed is the reason for the vertical recommendation.)
- **Separate Spaces ON:** display surfaces appear isolated → suppress the bleed-based vertical warning; recommend matching physical arrangement; advise relying on system cursor movement (nehir's warp is not Space-aware). Diagnostics-first (M4-S1); topology/eviction exemption (M4-S2) only if nehir intends to tolerate macOS-Spaces coexistence.
- **No startup hard-requirement** for Separate Spaces in any current plan.

## Why not wholesale WorldStore?

Upstream's WorldStore cluster is a **replacement runtime, not a patch stack** — it moves ownership of window model, focus, viewport/session state, layout engines, surface derivation, event ingress, deadlines, and topology into one store. Good ideas; wrong transplant. It would also import upstream product assumptions nehir intentionally removed (Dwindle, Hyper/hotkey, scratchpad, surface rails, startup Spaces gate).

Nehir already has a lighter reconcile vocabulary to build on instead: `RuntimeStore`, `ReconcileTxn`, `Planner`, `StateReducer`, `InvariantChecks`, `FocusPolicyEngine`. The major track (A1–A5) takes upstream's *principles* (single authoritative state, explicit commits, invariant validation, stamped async plans, intent-aware focus, derived surfaces, deterministic replay) and re-expresses them in nehir's vocabulary. See the analysis doc's "what NOT to port" table.

## Validation by lane

```bash
# Patch lane
swift build
swift test --filter RefreshRoutingTests
swift test --filter AXManagerTests
swift test --filter IPCQueryRouterTests
swift test --filter NiriMonitorTests
swift test --filter WorkspaceManagerTests

# Spaces lane
swift build
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter DisplaySpacesMode
swift test --filter SpaceTopology        # Stage 2 only

# Architecture lane
swift test --filter PureLayoutReducerTests
swift test --filter PureLayoutAgreementTests
rg -n 'import AppKit|import ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|ViewportState' Sources/Nehir/Core/PureLayout
```

## Handing off to a worker

Each per-cluster discovery doc is a self-contained handoff (provenance, code in question, recommendation, suggested tests, validation commands, risks, open questions). Hand a worker one ID with:

> Implement **<ID>** per [`<doc path>`]. Scope only what that doc's Recommendation covers; honor its "What NOT to change" / "Non-goals". Return: changed files, tests added, commands run, whether the change was direct-port / concept-port / rejected, and residual risks. Do **not** expand scope to other IDs.

Dependencies to respect when assigning: P4 before M1 (already satisfied); M3 before M6 as a recommended review sequence only (narrowed M3 has no hard code dependency for M6); M4-S1 before M4-S2; M5 abort-trace before any raw-source prototype; A1 before A2. Do **not** ask one subagent to port the full upstream range — it is heterogeneous and includes intentionally removed features.
