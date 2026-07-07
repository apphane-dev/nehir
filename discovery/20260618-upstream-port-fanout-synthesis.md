# Upstream port fanout synthesis — historical log

Groom 2026-07-07: superseded — historical fanout log; canonical priority/sequencing now lives in 20260618-upstream-port-roadmap.md; all P-track and M-track items have landed.

> ⚠️ **SUPERSEDED for priority/sequencing.** The canonical tier/verdict/deliverability/dependency/status table and the sequencing DAG now live in [`20260618-upstream-port-roadmap.md`](20260618-upstream-port-roadmap.md). This doc is kept as the historical record of the 2026-06-18 read-only planner fanout: what the planners corrected, and the per-ID writer prompts they produced.

Date: 2026-06-18.

Inputs: read-only planner fanout outputs produced 2026-06-18 under a machine-local
temp dir (since expired). Those outputs were distilled into the per-cluster discovery
docs (P1–P4, M1, M3, M4-S1, M4-S2, M5, M6, A1) and the corrections below; they are
no longer needed as inputs.

## Executive summary (as of the fanout)

The corrections below were folded into the per-cluster discovery docs and the roadmap. Kept verbatim for provenance.

Patch work is ready, but not all patch items are equally tiny once tests are included:

1. **P1 + P2** are code-small but test-heavy in `RefreshRoutingTests`.
2. **P3** is straightforward and self-contained; likely the safest first writer task.
3. **P4** is a one-branch AXManager change with focused tests; should land before M1 hardening.
4. **M1/M2 changed materially after planner inspection:** nehir already has the refused-frame feedback loop upstream `40934c5` introduced. The remaining work is test coverage + optional cascade hardening. Upstream `6eb9ba0` size quantum should be rejected in favor of nehir's existing post-write quantization acceptance.
5. **M3/M6 is large and should be split:** M3 focus-origin warp gate can be a minor patch; M6 selection/session revision guard is larger and needs separate design/implementation.
6. **M4 should be staged:** Stage 1 diagnostics/mode detection first; Stage 2 minimal SpaceTopology eviction hardening later.
7. **M5 is investigation-first:** land gesture abort tracing before any raw MultitouchSupport prototype.
8. **A1 is the architecture spike:** pure core starts in-place under `Sources/Nehir/Core/PureLayout/`, not a new SwiftPM target; first target is onboarding/real Niri consume-or-expel agreement.

## Important corrections to earlier discovery framing

### M1 — refused-size feedback already exists

Earlier minor doc phrased M1 as if nehir needed to port upstream `40934c5`'s structural feedback loop. Planner inspection found nehir already implements the full loop:

```text
AX terminal refusal
  -> LayoutRefreshController.handleResizeMinimumFrameApplyResult
  -> inferredResizeMinimumSize
  -> WorkspaceManager/WindowModel inferred minimum
  -> engine.updateWindowConstraints
  -> relayout with constraint
```

Therefore M1 is **not** a port. It is:

- test coverage for the learner/loop;
- optional hardening requiring two stable oversized observations before pinning;
- sequencing after P4, because P4 breaks the snap-back relayout loop that masks convergence.

### M2 — learned size quantum should be rejected

Planner recommends rejecting upstream `6eb9ba0` for nehir. Nehir's existing approach accepts benign terminal/cell quantization *after* the write and deliberately avoids pinning a runtime minimum. Upstream's learned quantum could over-constrain the solver and reintroduce the risk nehir fixed in #45.

Action: record this as a noop/rejection or update the M2 section before assigning implementation.

### P3 — production monitor sync already passes effective orientation

The leaf bug still exists and IPC is observable, but production monitor-sync currently passes `effectiveOrientation` to every monitor. P3 remains worth doing as defensive hardening + IPC correctness, but the live clobber path is less severe than originally implied.

### M4 — nehir has partial managed-Spaces helper already

Nehir already resolves `copyManagedDisplaySpaces` for `displayId(forSpaceId:among:)`. Missing pieces are mode detection, per-window Space lookup, SpaceTopology, and eviction exemption.

## Recommended writer sequencing

### Writer batch 1 — safe patch cluster

Recommended first implementation batch, in one worker or isolated worktrees:

1. **P3 orientation overrides** — lowest coupling.
2. **P4 frame failure suppression** — prerequisite for frame-sizing hardening.
3. **P1/P2 rescan + refresh routing** — can be one PR but expect test edits.

If using one active worktree writer, order:

```text
P3 -> P4 -> P1/P2
```

If using isolated worktrees, P3, P4, and P1/P2 can be independent; parent later merges.

### Writer batch 2 — frame sizing hardening

After P4:

1. Add tests proving the existing refused-size learner and cell-quantization branch.
2. Add M2 rejection memo/noop doc.
3. Consider optional two-stable-observation hardening only after tests characterize current behavior.

Do **not** port upstream `AXFrameApplicationLedger` or learned quantum state.

### Writer batch 3 — focus work split

Split M3 and M6:

- **M3 first:** add focus-request origin and suppress cursor warp for FFM-origin confirmations.
- **M6 later:** selection/session revision guard and stale cross-workspace focus clear.

M6 has high callsite coverage risk (`selectedNodeId =` live mutations) and should get its own review loop.

### Writer batch 4 — Spaces mode

Split M4:

- **Stage 1:** mode detection + diagnostics/copy + mouse-warp advisory. No layout behavior.
- **Stage 2:** per-window Space lookup + minimal topology + miss-eviction exemption.

Stage 1 can proceed independently. Stage 2 should wait until Stage 1 is reviewed and manual mode detection works on a real host.

### Writer batch 5 — gesture input

Do not prototype raw MultitouchSupport first. First land:

- abort/skip tracing for gesture failures;
- optional wake re-arm investigation as separate patch.

Only then run raw source prototype behind internal flags.

### Architecture batch — A1 only

First architecture spike:

1. Add pure models/reducer/invariants under `Sources/Nehir/Core/PureLayout/`.
2. Add agreement tests that expose the three real/demo divergences:
   - vertical storage convention;
   - consume insertion policy;
   - edge wrapping.
3. Decide the divergences explicitly.
4. Refactor `InteractiveMoveDemo.MoveDemoModel` to delegate to the pure reducer.

Do not proceed to A2 until A1 agreement tests are green and onboarding visual behavior is unchanged.

## Ready-to-run worker prompts

> Note: the expired per-cluster handoff files these prompts reference are no longer available. The per-cluster discovery docs (linked from [`20260618-upstream-port-roadmap.md`](20260618-upstream-port-roadmap.md)) are now the canonical handoffs — use the roadmap's "Handing off to a worker" template against those instead. The prompt bodies below are kept for the scope wording.

### Worker prompt — P3

Use output: `P3-orientation-overrides.md`.

> Implement P3 orientation override preservation using `P3-orientation-overrides.md` as the handoff. Scope only: update `NiriMonitor.updateOutputSize` to preserve existing orientation when `orientation` is nil; update IPC display orientation to report `settings.effectiveOrientation(for:)`; add `NiriMonitorTests`, IPC tests, and a patch changeset. Run the focused validation listed in the handoff. Do not broaden monitor orientation behavior beyond the plan.

### Worker prompt — P4

Use output: `P4-frame-failure-suppression.md`.

> Implement P4 frame failure suppression using `P4-frame-failure-suppression.md` as the handoff. Scope only: add the `recentFrameWriteFailures[windowId] != nil` branch to `AXManager.shouldSuppressFrameChangeRelayout`, and add the two focused `AXManagerTests` proving suppression after failure and bounded clearing after enqueue. Run `swift build`, `swift test --filter AXManagerTests`, and `swift test --filter AXEventHandlerTests` if feasible.

### Worker prompt — P1/P2

Use output: `P1-P2-rescan-refresh.md`.

> Implement P1/P2 using `P1-P2-rescan-refresh.md` as the handoff. Scope P1: full-rescan `removeMissing` requires two consecutive misses and update the two controller tests that assume one-miss eviction. Scope P2: same-kind immediateRelayout/relayout refreshes merge without cancelling active work; add the cancellation-observability tests and keep escalation cancellation tests green. Run the targeted `RefreshRoutingTests`, `OptimizationCompletionTests`, and `WorkspaceManagerTests` listed in the handoff.

### Worker prompt — M1/M2 tests + rejection memo

Use output: `M1-M2-frame-sizing.md`.

> After P4 is merged, implement the M1/M2 characterization from `M1-M2-frame-sizing.md`. Do not port upstream `AXFrameApplicationLedger` or learned size quantum. Add tests for the existing resize-minimum learner and cell-quantization acceptance path; add or update a discovery/noop memo rejecting M2 with evidence. Defer the optional two-stable-observation hardening unless explicitly approved.

### Worker prompt — M4 Stage 1

Use output: `M4-spaces-diagnostics-topology.md`.

> Implement only Stage 1 from `M4-spaces-diagnostics-topology.md`: DisplaySpacesMode detection, mode-aware diagnostics, runtime dump, mouse-warp advisory copy, docs update, tests, and changeset. Do not implement SpaceTopology eviction hardening and do not add a startup requirement.

### Worker prompt — A1 architecture spike

Use output: `A1-A5-pure-engine-worldstore.md`.

> Implement only A1 tasks 1-4 from `A1-A5-pure-engine-worldstore.md`: add pure models, direction, reducer, and invariants under `Sources/Nehir/Core/PureLayout/`, plus pure reducer tests. Do not refactor onboarding yet unless explicitly approved. Keep pure files free of AppKit/AX/SkyLight/WindowToken/NiriNode/ViewportState references.

## Validation strategy by lane

Patch lane:

```bash
swift build
swift test --filter RefreshRoutingTests
swift test --filter AXManagerTests
swift test --filter IPCQueryRouterTests
swift test --filter NiriMonitorTests
swift test --filter WorkspaceManagerTests
```

Spaces lane:

```bash
swift build
swift test --filter DisplayEnvironmentDiagnostics
swift test --filter DisplaySpacesMode
swift test --filter SpaceTopology   # Stage 2 only
```

Architecture lane:

```bash
swift test --filter PureLayoutReducerTests
swift test --filter PureLayoutAgreementTests
rg -n 'import AppKit|import ApplicationServices|AXUIElement|SkyLight|WindowToken|NiriNode|ViewportState' Sources/Nehir/Core/PureLayout
```

## Parent decision points before assigning writers

1. Should P1/P2/P3/P4 be implemented in one patch PR or split?
   - Recommendation: P3 and P4 split; P1/P2 together is acceptable because both touch refresh behavior/tests.
2. Should M1 optional two-stable-observation hardening be approved now?
   - Recommendation: no; first add characterization tests and P4.
3. Should M4 Stage 1 be advisory only, or auto-disable mouse warp when Separate Spaces is ON?
   - Recommendation: advisory only.
4. Should M3 include only cursor-warp origin, or also hiro-317 createdAt/grace window?
   - Recommendation: M3 only; hiro-317 as separate A4/focus-ledger task.
5. Should A1 begin with pure addition only or include onboarding refactor?
   - Recommendation: pure addition + tests first, then onboarding refactor after divergence decision.
